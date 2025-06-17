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
    StateInit
} from '@ton/core';

export type NFTItemConfig = {
    itemIndex: number;
    collectionAddress: Address;
    ownerAddress?: Address;
    content?: Cell;
};

export class NFTItem implements Contract {
    static readonly OPCODES = {
        TRANSFER: 0x5fcc3d14,
        GET_STATIC_DATA: 0x2fcb26a2
    };

    constructor(
        readonly address: Address,
        readonly init?: StateInit
    ) {
    }

    static createFromAddress(address: Address) {
        return new NFTItem(address);
    }

    static createFromConfig(config: NFTItemConfig, code: Cell, workchain = 0) {
        const data = NFTItem.configToCell(config);
        const init = { code, data };
        return new NFTItem(contractAddress(workchain, init), init);
    }

    static configToCell(config: NFTItemConfig): Cell {
        const builder = beginCell().storeUint(config.itemIndex, 64).storeAddress(config.collectionAddress);

        if (config.ownerAddress) {
            builder.storeAddress(config.ownerAddress);
        }
        if (config.content) {
            builder.storeRef(config.content);
        }

        return builder.endCell();
    }

    async sendDeploy(
        provider: ContractProvider,
        via: Sender,
        opts: {
            value: bigint;
            ownerAddress: Address;
            content: Cell;
        }
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell().storeAddress(opts.ownerAddress).storeRef(opts.content).endCell()
        });
    }

    async sendTransferOwnership(
        provider: ContractProvider,
        via: Sender,
        opts: {
            queryId?: number;
            value: bigint;
            to: Address;
            responseTo?: Address;
            forwardAmount?: bigint;
            forwardBody?: Cell | Slice;
        }
    ) {
        const body = beginCell()
            .storeUint(NFTItem.OPCODES.TRANSFER, 32)
            .storeUint(opts.queryId ?? 0, 64)
            .storeAddress(opts.to)
            .storeAddress(opts.responseTo)
            .storeMaybeRef(null)
            .storeCoins(opts.forwardAmount ?? 0);

        if (opts.forwardBody instanceof Cell) {
            body.storeBit(1).storeRef(opts.forwardBody);
        } else {
            body.storeBit(0).storeSlice(opts.forwardBody ?? Cell.EMPTY.beginParse());
        }
        await provider.internal(via, {
            value: opts.value,
            body: body.endCell()
        });
    }

    async sendGetStaticData(provider: ContractProvider, via: Sender, opts: {
        queryId?: number;
        value: bigint;
    }) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell()
                .storeUint(NFTItem.OPCODES.GET_STATIC_DATA, 32)
                .storeUint(opts.queryId ?? 0, 64)
                .endCell()
        });
    }

    async getNftData(provider: ContractProvider): Promise<{
        init: boolean;
        index: number;
        collectionAddress: Address;
        ownerAddress: Address | null;
        individualContent: Cell | null;
    }> {
        const { stack } = await provider.get('get_nft_data', []);

        return {
            init: stack.readBoolean(),
            index: stack.readNumber(),
            collectionAddress: stack.readAddress(),
            ownerAddress: stack.readAddressOpt(),
            individualContent: stack.readCellOpt()
        };
    }
}
