import {
    Address,
    beginCell,
    Cell,
    Contract,
    contractAddress,
    ContractProvider,
    Sender,
    SendMode,
    Slice,
    toNano,
} from '@ton/core';
import { Op } from './JettonConstants';

export type JettonMinterContent = {
    uri: string;
};
export type JettonMinterConfig = {
    admin: Address | null;
    nextAdmin?: Address | null;
    wallet_code: Cell;
    jetton_content: Cell | JettonMinterContent;
};
export type JettonMinterConfigFull = {
    supply: bigint;
    admin: Address | null;
    //Makes no sense to update transfer admin. ...Or is it?
    transfer_admin: Address | null;
    wallet_code: Cell;
    jetton_content: Cell | JettonMinterContent;
};

export function endParse(slice: Slice) {
    if (slice.remainingBits > 0 || slice.remainingRefs > 0) {
        throw new Error('remaining bits in data');
    }
}

export function jettonMinterConfigCellToConfig(config: Cell): JettonMinterConfigFull {
    const sc = config.beginParse();
    const parsed: JettonMinterConfigFull = {
        supply: sc.loadCoins(),
        admin: sc.loadMaybeAddress(),
        transfer_admin: sc.loadMaybeAddress(),
        wallet_code: sc.loadRef(),
        jetton_content: sc.loadRef(),
    };
    endParse(sc);
    return parsed;
}

export function parseJettonMinterData(data: Cell): JettonMinterConfigFull {
    return jettonMinterConfigCellToConfig(data);
}

export function jettonMinterConfigFullToCell(config: JettonMinterConfigFull): Cell {
    const content =
        config.jetton_content instanceof Cell ? config.jetton_content : jettonContentToCell(config.jetton_content);
    return beginCell()
        .storeCoins(config.supply)
        .storeAddress(config.admin)
        .storeAddress(config.transfer_admin)
        .storeRef(config.wallet_code)
        .storeRef(content)
        .endCell();
}

export function jettonMinterConfigToCell(config: JettonMinterConfig): Cell {
    const content =
        config.jetton_content instanceof Cell ? config.jetton_content : jettonContentToCell(config.jetton_content);
    return beginCell()
        .storeCoins(0)
        .storeAddress(config.admin)
        .storeAddress(config.nextAdmin)
        .storeRef(config.wallet_code)
        .storeRef(content)
        .endCell();
}

export function jettonContentToCell(content: JettonMinterContent) {
    return beginCell()
        .storeStringRefTail(content.uri) //Snake logic under the hood
        .endCell();
}

export class JettonMinter implements Contract {
    constructor(
        readonly address: Address,
        readonly init?: { code: Cell; data: Cell },
    ) {}

    static createFromAddress(address: Address) {
        return new JettonMinter(address);
    }

    static createFromConfig(config: JettonMinterConfig, code: Cell, workchain = 0) {
        const data = jettonMinterConfigToCell(config);
        const init = { code, data };
        return new JettonMinter(contractAddress(workchain, init), init);
    }

    async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().storeUint(Op.top_up, 32).storeUint(0, 64).endCell(),
        });
    }

    static mintMessage(
        to: Address,
        jetton_amount: bigint,
        from?: Address | null,
        response?: Address | null,
        customPayload?: Cell | null,
        forward_ton_amount: bigint = 0n,
        total_ton_amount: bigint = 0n,
    ) {
        const mintMsg = beginCell()
            .storeUint(Op.internal_transfer, 32)
            .storeUint(0, 64)
            .storeCoins(jetton_amount)
            .storeAddress(from)
            .storeAddress(response)
            .storeCoins(forward_ton_amount)
            .storeMaybeRef(customPayload)
            .endCell();
        return beginCell()
            .storeUint(Op.mint, 32)
            .storeUint(0, 64) // op, queryId
            .storeAddress(to)
            .storeCoins(total_ton_amount)
            .storeRef(mintMsg)
            .endCell();
    }

    static parseMintInternalMessage(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.internal_transfer) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        const jettonAmount = slice.loadCoins();
        const fromAddress = slice.loadAddress();
        const responseAddress = slice.loadAddress();
        const forwardTonAmount = slice.loadCoins();
        const customPayload = slice.loadMaybeRef();
        endParse(slice);
        return {
            queryId,
            jettonAmount,
            fromAddress,
            responseAddress,
            forwardTonAmount,
            customPayload,
        };
    }

    static parseMintMessage(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.mint) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        const toAddress = slice.loadAddress();
        const tonAmount = slice.loadCoins();
        const mintMsg = slice.loadRef();
        endParse(slice);
        return {
            queryId,
            toAddress,
            tonAmount,
            internalMessage: this.parseMintInternalMessage(mintMsg.beginParse()),
        };
    }

    async sendMint(
        provider: ContractProvider,
        via: Sender,
        to: Address,
        jetton_amount: bigint,
        from?: Address | null,
        response_addr?: Address | null,
        customPayload?: Cell | null,
        forward_ton_amount: bigint = toNano('0.05'),
        total_ton_amount: bigint = toNano('0.1'),
    ) {
        await provider.internal(via, {
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: JettonMinter.mintMessage(
                to,
                jetton_amount,
                from,
                response_addr,
                customPayload,
                forward_ton_amount,
                total_ton_amount,
            ),
            value: total_ton_amount + toNano('0.05'),
        });
    }

    /* provide_wallet_address#2c76b973 query_id:uint64 owner_address:MsgAddress include_address:Bool = InternalMsgBody;
     */
    static discoveryMessage(owner: Address, include_address: boolean) {
        return beginCell()
            .storeUint(Op.provide_wallet_address, 32)
            .storeUint(0, 64) // op, queryId
            .storeAddress(owner)
            .storeBit(include_address)
            .endCell();
    }

    async sendDiscovery(
        provider: ContractProvider,
        via: Sender,
        owner: Address,
        include_address: boolean,
        value: bigint = toNano('0.1'),
    ) {
        await provider.internal(via, {
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: JettonMinter.discoveryMessage(owner, include_address),
            value: value,
        });
    }

    static topUpMessage() {
        return beginCell()
            .storeUint(Op.top_up, 32)
            .storeUint(0, 64) // op, queryId
            .endCell();
    }

    static parseTopUp(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.top_up) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        endParse(slice);
        return {
            queryId,
        };
    }

    async sendTopUp(provider: ContractProvider, via: Sender, value: bigint = toNano('0.1')) {
        await provider.internal(via, {
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: JettonMinter.topUpMessage(),
            value: value,
        });
    }

    static changeAdminMessage(newOwner: Address) {
        return beginCell()
            .storeUint(Op.change_admin, 32)
            .storeUint(0, 64) // op, queryId
            .storeAddress(newOwner)
            .endCell();
    }

    static parseChangeAdmin(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.change_admin) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        const newAdminAddress = slice.loadAddress();
        endParse(slice);
        return {
            queryId,
            newAdminAddress,
        };
    }

    async sendChangeAdmin(provider: ContractProvider, via: Sender, newOwner: Address) {
        await provider.internal(via, {
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: JettonMinter.changeAdminMessage(newOwner),
            value: toNano('0.1'),
        });
    }

    static claimAdminMessage(query_id: bigint = 0n) {
        return beginCell().storeUint(Op.claim_admin, 32).storeUint(query_id, 64).endCell();
    }

    static parseClaimAdmin(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.claim_admin) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        endParse(slice);
        return {
            queryId,
        };
    }

    async sendClaimAdmin(provider: ContractProvider, via: Sender, query_id: bigint = 0n) {
        await provider.internal(via, {
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: JettonMinter.claimAdminMessage(query_id),
            value: toNano('0.1'),
        });
    }

    static dropAdminMessage(query_id: number | bigint) {
        return beginCell().storeUint(Op.drop_admin, 32).storeUint(query_id, 64).endCell();
    }

    static parseDropAdmin(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.drop_admin) {
            throw new Error('Invalid op');
        }
        const queryId = slice.loadUint(64);
        endParse(slice);
        return {
            queryId,
        };
    }

    async sendDropAdmin(
        provider: ContractProvider,
        via: Sender,
        value: bigint = toNano('0.05'),
        query_id: number | bigint = 0,
    ) {
        await provider.internal(via, {
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: JettonMinter.dropAdminMessage(query_id),
            value,
        });
    }

    static changeContentMessage(content: Cell | JettonMinterContent) {
        const builder = beginCell().storeUint(Op.change_metadata_url, 32).storeUint(0, 64); // op, queryId

        if (content instanceof Cell) {
            builder.storeRef(content);
        } else {
            builder.storeStringTail(content.uri);
        }
        return builder.endCell();
    }

    static parseChangeContent(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.change_metadata_url) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        const newMetadataUrl = slice.loadStringTail();
        endParse(slice);
        return {
            queryId,
            newMetadataUrl,
        };
    }

    async sendChangeContent(provider: ContractProvider, via: Sender, content: Cell | JettonMinterContent) {
        await provider.internal(via, {
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: JettonMinter.changeContentMessage(content),
            value: toNano('0.1'),
        });
    }

    static parseTransfer(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.transfer) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        const jettonAmount = slice.loadCoins();
        const toAddress = slice.loadAddress();
        const responseAddress = slice.loadAddress();
        const customPayload = slice.loadMaybeRef();
        const forwardTonAmount = slice.loadCoins();
        const inRef = slice.loadBit();
        const forwardPayload = inRef ? slice.loadRef().beginParse() : slice;
        return {
            queryId,
            jettonAmount,
            toAddress,
            responseAddress,
            customPayload,
            forwardTonAmount,
            forwardPayload,
        };
    }

    static parseBurn(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.burn) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        const jettonAmount = slice.loadCoins();
        const responseAddress = slice.loadAddress();
        const customPayload = slice.loadMaybeRef();
        endParse(slice);
        return {
            queryId,
            jettonAmount,
            responseAddress,
            customPayload,
        };
    }

    static upgradeMessage(new_code: Cell, new_data: Cell, query_id: bigint | number = 0) {
        return beginCell()
            .storeUint(Op.upgrade, 32)
            .storeUint(query_id, 64)
            .storeRef(new_data)
            .storeRef(new_code)
            .endCell();
    }

    static parseUpgrade(slice: Slice) {
        const op = slice.loadUint(32);
        if (op !== Op.upgrade) throw new Error('Invalid op');
        const queryId = slice.loadUint(64);
        const newData = slice.loadRef();
        const newCode = slice.loadRef();
        endParse(slice);
        return {
            queryId,
            newData,
            newCode,
        };
    }

    async sendUpgrade(
        provider: ContractProvider,
        via: Sender,
        new_code: Cell,
        new_data: Cell,
        value: bigint = toNano('0.1'),
        query_id: bigint | number = 0,
    ) {
        await provider.internal(via, {
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: JettonMinter.upgradeMessage(new_code, new_data, query_id),
            value,
        });
    }

    async getWalletAddress(provider: ContractProvider, owner: Address): Promise<Address> {
        const res = await provider.get('get_wallet_address', [
            {
                type: 'slice',
                cell: beginCell().storeAddress(owner).endCell(),
            },
        ]);
        return res.stack.readAddress();
    }

    async getJettonData(provider: ContractProvider) {
        let res = await provider.get('get_jetton_data', []);
        let totalSupply = res.stack.readBigNumber();
        let mintable = res.stack.readBoolean();
        let adminAddress = res.stack.readAddressOpt();
        let content = res.stack.readCell();
        let walletCode = res.stack.readCell();
        return {
            totalSupply,
            mintable,
            adminAddress,
            content,
            walletCode,
        };
    }

    async getTotalSupply(provider: ContractProvider) {
        let res = await this.getJettonData(provider);
        return res.totalSupply;
    }

    async getAdminAddress(provider: ContractProvider) {
        let res = await this.getJettonData(provider);
        return res.adminAddress;
    }

    async getContent(provider: ContractProvider) {
        let res = await this.getJettonData(provider);
        return res.content;
    }

    async getNextAdminAddress(provider: ContractProvider) {
        const res = await provider.get('get_next_admin_address', []);
        return res.stack.readAddressOpt();
    }
}
