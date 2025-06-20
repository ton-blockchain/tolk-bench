import "@stdlib/tvm-dicts"

import "op-codes.tolk"
import "storage.tolk"
import "messages.tolk"

// NFT collection smart contract

fun NftCollectionStorage.load() {
    return NftCollectionStorage.fromCell(contract.getData())
}

fun NftCollectionStorage.save(self) {
    contract.setData(self.toCell())
}

fun calculateNftItemStateInit(itemIndex: int, nftItemCode: cell): cell {
    var nftItemUninitedState: NftItemStorageUninitialized = {
        index: itemIndex,
        collectionAddress: contract.getAddress(),
    };
    var data: cell = nftItemUninitedState.toCell();
    return beginCell().storeUint(0, 2).storeDict(nftItemCode).storeDict(data).storeUint(0, 1).endCell();
}

fun calculateNftItemAddress(wc: int, stateInit: cell): address {
    return beginCell().storeUint(4, 3)
        .storeInt(wc, 8)
        .storeUint(stateInit.hash(), 256)
        .endCell()
        .beginParse() as address;
}

fun deployNftItem(itemIndex: int, nftItemCode: cell, amount: coins, initParams: Cell<NftItemInitAtDeployment>) {
    var stateInit = calculateNftItemStateInit(itemIndex, nftItemCode);
    var nftAddress = calculateNftItemAddress(BASECHAIN, stateInit);
    var msg = beginCell()
        .storeUint(0x18, 6)
        .storeAddress(nftAddress)
        .storeCoins(amount)
        .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
        .storeRef(stateInit)
        .storeRef(initParams);
    sendRawMessage(msg.endCell(), 1); // pay transfer fees separately, revert on errors
}

@inline
fun sendRoyaltyParams(toAddress: address, queryId: int, data: slice) {
    var msg = beginCell()
        .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 011000
        .storeAddress(toAddress)
        .storeCoins(0)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeUint(OP_REPORT_ROYALTY_PARAMS, 32)
        .storeUint(queryId, 64)
        .storeSlice(data);
    sendRawMessage(msg.endCell(), 64); // carry all the remaining value of the inbound message
}

type AllowedMessageToCollection =
    RequestRoyaltyParams |
    DeployNft |
    BatchDeployNfts |
    ChangeNftOwner |
;

fun onInternalMessage(inMsgFull: cell, inMsgBody: slice) {
    if (inMsgBody.isEnd()) {
        // ignore empty messages
        return;
    }
    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    if (flags & 1) {
        // ignore all bounced messages
        return;
    }
    var senderAddress = cs.loadAddress();

    // todo load once or lazily in every branch?
    var storage = NftCollectionStorage.load();

    val msg = lazy AllowedMessageToCollection.fromSlice(inMsgBody);

    match (msg) {
        DeployNft => {
            assert(senderAddress == storage.ownerAddress) throw 401;
            assert(msg.itemIndex <= storage.nextItemIndex) throw 402;

            var isLast = msg.itemIndex == storage.nextItemIndex;
            deployNftItem(msg.itemIndex, storage.nftItemCode, msg.amount, msg.initParams);
            if (isLast) {
                storage.nextItemIndex += 1;
                storage.save();
            }
        }

        RequestRoyaltyParams => {
            sendRoyaltyParams(senderAddress, msg.queryId, storage.royaltyParams.beginParse());
        }

        BatchDeployNfts => {
            assert(senderAddress == storage.ownerAddress) throw 401;

            var counter = 0;
            var deployList = msg.deployList;
            while (true) {
                var (itemIndex, valueSlice, found) = deployList.uDictDeleteFirstAndGet(64);
                if (!found) {
                    storage.save();
                    return;
                }
                itemIndex = itemIndex!;     // tell the compiler that it's not-null (because found)

                counter += 1;
                assert (counter < 250) throw 399;   // due to limits of action list size

                assert(itemIndex <= storage.nextItemIndex) throw 403 + counter;
                val dictItem = BatchDeployDictItem.fromSlice(valueSlice!);
                deployNftItem(itemIndex, storage.nftItemCode, dictItem.amount, dictItem.initParams);
                if (itemIndex == storage.nextItemIndex) {
                    storage.nextItemIndex += 1;
                }
            }
        }

        ChangeNftOwner => {
            assert(senderAddress == storage.ownerAddress) throw 401;
            storage.ownerAddress = msg.newOwnerAddress;
            storage.save();
        }

        else => throw 0xFFFF
    }
}

// Get methods

get get_collection_data(): (int, cell, address) {
    val storage = lazy NftCollectionStorage.load();
    var cs: slice = storage.content.beginParse();    // todo what is this ref?
    return (storage.nextItemIndex, cs.loadRef(), storage.ownerAddress);
}

get get_nft_address_by_index(index: int): address {
    val storage = lazy NftCollectionStorage.load();
    var stateInit: cell = calculateNftItemStateInit(index, storage.nftItemCode);
    return calculateNftItemAddress(BASECHAIN, stateInit);
}

get royalty_params(): RoyaltyParams {
    val storage = lazy NftCollectionStorage.load();
    return storage.royaltyParams.load();
}

get get_nft_content(index: int, individualNftContent: cell): cell {
    val storage = lazy NftCollectionStorage.load();
    var cs: slice = storage.content.beginParse();       // todo what's the format?
    cs.loadRef();
    var commonContent: slice = cs.loadRef().beginParse();
    return (beginCell()
        .storeUint(1, 8) // offchain tag
        .storeSlice(commonContent)
        .storeRef(individualNftContent)
        .endCell());
}
