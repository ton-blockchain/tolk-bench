import {
    Address,
    beginCell,
    Builder,
    Cell,
    Contract,
    contractAddress,
    ContractProvider,
    Dictionary,
    DictionaryValue,
    Sender,
    SendMode,
    Slice,
    StateInit,
    toNano,
    TupleBuilder,
} from '@ton/core';

export type RoyaltyParams = { numerator: number; denominator: number; royaltyAddress: Address };

export type NftCollectionConfig = {
    ownerAddress: Address;
    nextItemIndex?: number;
    content?: Cell;
    nftItemCode: Cell;
    royaltyParams?: Cell | RoyaltyParams;
};

export class NFTCollection implements Contract {
    static readonly OPCODES = {
        GET_ROYALTY_PARAMS: 0x693d3950,
        DEPLOY_NFT: 1,
        BATCH_DEPLOY_NFT: 2,
        CHANGE_OWNER: 3,
    };

    static configToCell(config: NftCollectionConfig): Cell {
        const royalty = config.royaltyParams ?? Cell.EMPTY;
        const royaltyCell = royalty instanceof Cell ? royalty : NFTCollection.buildRoyaltyParams(royalty);
        return beginCell()
            .storeAddress(config.ownerAddress)
            .storeUint(config.nextItemIndex ?? 0, 64)
            .storeRef(config.content ?? beginCell().storeRef(Cell.EMPTY))
            .storeRef(config.nftItemCode)
            .storeRef(royaltyCell)
            .endCell();
    }

    static createFromAddress(address: Address) {
        return new NFTCollection(address);
    }

    static buildRoyaltyParams(opts: RoyaltyParams) {
        return beginCell()
            .storeUint(opts.numerator, 16)
            .storeUint(opts.denominator, 16)
            .storeAddress(opts.royaltyAddress)
            .endCell();
    }

    static createFromConfig(config: NftCollectionConfig, code: Cell, workchain = 0) {
        const data = NFTCollection.configToCell(config);
        const init = { code, data };
        return new NFTCollection(contractAddress(workchain, init), init);
    }

    constructor(
        readonly address: Address,
        readonly init?: StateInit,
    ) {}

    async sendDeploy(provider: ContractProvider, via: Sender, value: bigint) {
        await provider.internal(via, {
            value: value,
            body: beginCell().endCell(),
        });
    }

    async sendDeployNft(
        provider: ContractProvider,
        via: Sender,
        opts: {
            to: Address;
            queryId?: number;
            index: number;
            value: bigint;
            itemValue?: bigint;
            content?: Cell;
        },
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell()
                .storeUint(NFTCollection.OPCODES.DEPLOY_NFT, 32)
                .storeUint(opts.queryId ?? 0, 64)
                .storeUint(opts.index, 64)
                .storeCoins(opts.itemValue ?? toNano('0.02'))
                .storeRef(
                    beginCell()
                        .storeAddress(opts.to)
                        .storeRef(opts.content ?? Cell.EMPTY),
                )
                .endCell(),
        });
    }

    async sendBatchDeployNFT(
        provider: ContractProvider,
        via: Sender,
        opts: {
            value: bigint;
            queryId?: number;
            items: {
                to: Address;
                index: number;
                itemValue?: bigint;
                content?: Cell;
            }[];
        },
    ) {
        const sliceValue: DictionaryValue<Slice> = {
            serialize(src, builder) {
                return builder.storeSlice(src);
            },
            parse(src: Slice): Slice {
                return src;
            },
        };

        const deployList = Dictionary.empty(Dictionary.Keys.Uint(64), sliceValue);
        for (const item of opts.items) {
            deployList.set(
                item.index,
                beginCell()
                    .storeCoins(10000000n)
                    .storeRef(
                        beginCell()
                            .storeAddress(item.to)
                            .storeRef(item.content ?? Cell.EMPTY),
                    )
                    .endCell()
                    .beginParse(),
            );
        }

        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell()
                .storeUint(NFTCollection.OPCODES.BATCH_DEPLOY_NFT, 32)
                .storeUint(opts.queryId ?? 0, 64)
                .storeDict(deployList)
                .endCell(),
        });
    }

    async sendGetRoyaltyParams(
        provider: ContractProvider,
        via: Sender,
        opts: {
            queryId?: number;
            value: bigint;
        },
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell()
                .storeUint(NFTCollection.OPCODES.GET_ROYALTY_PARAMS, 32)
                .storeUint(opts.queryId ?? 0, 64)
                .endCell(),
        });
    }

    async sendChangeOwner(
        provider: ContractProvider,
        via: Sender,
        opts: {
            queryId?: number;
            value: bigint;
            newOwner: Address;
        },
    ) {
        await provider.internal(via, {
            value: opts.value,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            body: beginCell()
                .storeUint(NFTCollection.OPCODES.CHANGE_OWNER, 32)
                .storeUint(opts.queryId ?? 0, 64)
                .storeAddress(opts.newOwner)
                .endCell(),
        });
    }

    async getRoyaltyParams(provider: ContractProvider): Promise<RoyaltyParams> {
        const { stack } = await provider.get('royalty_params', []);

        return {
            numerator: stack.readNumber(),
            denominator: stack.readNumber(),
            royaltyAddress: stack.readAddress(),
        };
    }

    async getNftAddressByIndex(provider: ContractProvider, index: number): Promise<Address> {
        const builder = new TupleBuilder();
        builder.writeNumber(index);

        const { stack } = await provider.get('get_nft_address_by_index', builder.build());

        return stack.readAddress();
    }

    async getCollectionData(provider: ContractProvider): Promise<{
        nextItemIndex: number;
        collectionContent: Cell;
        ownerAddress: Address;
    }> {
        const { stack } = await provider.get('get_collection_data', []);
        return {
            nextItemIndex: stack.readNumber(),
            collectionContent: stack.readCell(),
            ownerAddress: stack.readAddress(),
        };
    }
}
