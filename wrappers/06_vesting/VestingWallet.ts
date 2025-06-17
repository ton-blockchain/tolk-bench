import {
    Address,
    beginCell,
    Cell,
    Contract,
    contractAddress,
    ContractProvider,
    MessageRelaxed,
    Sender,
    SendMode
} from '@ton/core';
import {createWalletTransferV3} from "@ton/ton/dist/wallets/signing/createWalletTransfer";

export type VestingWalletConfig = {
    subWalletId: number,
    publicKeyHex: string;

    vestingStartTime: number;
    vestingTotalDuration: number;
    unlockPeriod: number;
    cliffDuration: number;
    vestingTotalAmount: bigint;

    vestingSenderAddress: Address;
    ownerAddress: Address;
};

export function vestingWalletConfigToCell(config: VestingWalletConfig): Cell {
    return beginCell()
        .storeUint(0, 32) // seqno
        .storeUint(config.subWalletId, 32) // subwallet
        .storeBuffer(Buffer.from(config.publicKeyHex, 'hex')) // public_key
        .storeUint(0, 1) // empty whitelist
        .storeRef(
            beginCell()
                .storeUint(config.vestingStartTime, 64)
                .storeUint(config.vestingTotalDuration, 32)
                .storeUint(config.unlockPeriod, 32)
                .storeUint(config.cliffDuration, 32)
                .storeCoins(config.vestingTotalAmount)
                .storeAddress(config.vestingSenderAddress)
                .storeAddress(config.ownerAddress)
                .endCell()
        )
        .endCell();
}

export const Opcodes = {
    add_whitelist: 0x7258a69b,
    add_whitelist_response: 0xf258a69b,
    send: 0xa7733acd,
    send_response: 0xf7733acd,

    elector_new_stake: 0x4e73744b,
    elector_recover_stake: 0x47657424,
    vote_for_complaint: 0x56744370,
    vote_for_proposal: 0x566f7465,

    single_nominator_pool_withdraw: 0x1000,
    single_nominator_pool_change_validator: 0x1001,

    ton_stakers_deposit: 0x47d54391,
    jetton_burn: 0x595f07bc,
    ton_stakers_vote: 0x69fb306c,
};

export const ErrorCodes = {
    expired: 36,
    invalid_seqno: 33,
    invalid_subwallet_id: 34,
    invalid_signature: 35,

    send_mode_not_allowed: 100,
    non_bounceable_not_allowed: 101,
    state_init_not_allowed: 102,
    comment_not_allowed: 103,
    symbols_not_allowed: 104,
};

export class VestingWallet implements Contract {
    constructor(readonly address: Address, readonly init?: { code: Cell; data: Cell }) {
    }

    static createFromAddress(address: Address) {
        return new VestingWallet(address);
    }

    static createFromConfig(config: VestingWalletConfig, code: Cell, workchain = 0) {
        const data = vestingWalletConfigToCell(config);
        const init = {code, data};
        return new VestingWallet(contractAddress(workchain, init), init);
    }

    async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
        await provider.internal(via, {
            value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().endCell(),
        });
    }

    async sendSimple(
        provider: ContractProvider,
        via: Sender,
        opts: {
            value: bigint;
            comment?: string;
        }
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: opts.comment ? beginCell().storeUint(0, 32).storeStringTail(opts.comment).endCell() : undefined
        });
    }

    async sendOp(
        provider: ContractProvider,
        via: Sender,
        opts: {
            value: bigint;
            op: number;
        }
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().storeUint(opts.op, 32).endCell()
        });
    }

    async sendInternalTransfer(
        provider: ContractProvider,
        via: Sender,
        opts: {
            value: bigint;
            sendMode: number;
            msg: Cell,
            queryId?: number;
        }
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell()
                .storeUint(Opcodes.send, 32)
                .storeUint(opts.queryId || 0, 64)
                .storeUint(opts.sendMode, 8)
                .storeRef(opts.msg)
                .endCell()
        });
    }

    /**
     * Create transfer
     */
    createTransfer(args: { seqno: number, sendMode: SendMode, secretKey: Buffer, messages: MessageRelaxed[], timeout?: number | null, subWalletId: number }) {
        return createWalletTransferV3({
            seqno: args.seqno,
            sendMode: args.sendMode,
            secretKey: args.secretKey,
            messages: args.messages,
            timeout: args.timeout,
            walletId: args.subWalletId
        });
    }

    /**
     * Sign and send external transfer
     */
    async sendExternalTransfer(provider: ContractProvider, args: {
        seqno: number,
        secretKey: Buffer,
        messages: MessageRelaxed[],
        sendMode: SendMode,
        timeout: number,
        subWalletId: number
    }) {
        let transfer = this.createTransfer(args);
        await provider.external(transfer)
    }

    static createAddWhitelistBody(addresses: Address[], queryId?: number): Cell {
        const root = beginCell()
            .storeUint(Opcodes.add_whitelist, 32) // op
            .storeUint(queryId || 0, 64) // query_id;
            .storeAddress(addresses[0]);

        let cell: Cell | null = null;

        for (let i = addresses.length - 1; i >= 1; i--) {
            const newCell = beginCell().storeAddress(addresses[i]);

            if (cell) {
                newCell.storeRef(cell);
            }

            cell = newCell.endCell();
        }

        if (cell) {
            root.storeRef(cell);
        }

        return root.endCell();
    }

    async sendAddWhitelist(
        provider: ContractProvider,
        via: Sender,
        opts: {
            value: bigint;
            queryId?: number;
            addresses: Address[];
        }
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: VestingWallet.createAddWhitelistBody(opts.addresses, opts.queryId)
        });
    }

    async getSeqno(provider: ContractProvider): Promise<number> {
        const result = await provider.get('seqno', []);
        return result.stack.readNumber();
    }

    async getSubWalletId(provider: ContractProvider): Promise<number> {
        const result = await provider.get('get_subwallet_id', []);
        return result.stack.readNumber();
    }

    async getPublicKeyHex(provider: ContractProvider): Promise<string> {
        const result = await provider.get('get_public_key', []);
        return result.stack.readBigNumber().toString(16);
    }

    async getVestingData(provider: ContractProvider) {
        const result = await provider.get('get_vesting_data', []);
        return {
            vestingStartTime: result.stack.readNumber(),
            vestingTotalDuration: result.stack.readNumber(),
            unlockPeriod: result.stack.readNumber(),
            cliffDuration: result.stack.readNumber(),
            vestingTotalAmount: result.stack.readBigNumber(),
            vestingSenderAddress: result.stack.readAddress(),
            ownerAddress: result.stack.readAddress(),
            whitelistCell: result.stack.readCellOpt()
        };
    }

    async getWhitelist(provider: ContractProvider): Promise<Address[]> {
        const result = await provider.get('get_whitelist', []);
        let addresses = [];
        let list = result.stack.readTupleOpt();
        while (list) {
            const tuple = list.readTuple();
            const wc = tuple.readNumber();
            const hash = tuple.readBigNumber();
            addresses.push(Address.parse(wc + ':' + hash.toString(16).padStart(64, '0')));
            if (list.remaining > 0) {
                list = list.readTupleOpt();
            }
        }
        return addresses;
    }

    async getIsWhitelisted(provider: ContractProvider, address: Address): Promise<boolean> {
        const result = await provider.get('is_whitelisted', [{
            type: 'slice',
            cell: beginCell().storeAddress(address).endCell()
        }]);
        return result.stack.readBoolean();
    }

    async getLockedAmount(provider: ContractProvider, time: number): Promise<bigint> {
        const result = await provider.get('get_locked_amount', [{
            type: 'int',
            value: BigInt(time)
        }]);
        return result.stack.readBigNumber();
    }
}
