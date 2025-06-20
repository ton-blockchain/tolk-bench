import "@stdlib/tvm-dicts"

import "storage.tolk"
import "messages.tolk"

// NFT collection smart contract

fun NftCollectionStorage.load() {
    return NftCollectionStorage.fromCell(contract.getData())
}

fun NftCollectionStorage.save(self) {
    contract.setData(self.toCell())
}

fun buildAddressOfNftItem(itemIndex: int, collectionAddress: address, nftItemCode: cell): builder {
    val stateInitHash = StateInit.calcHashCodeData(
        nftItemCode,
        NftItemStorageUninitialized.generateEmptyData(itemIndex, collectionAddress)
    );
    // todo manual work, how to better avoid it? (it's important to leave builder here)
    return beginCell()
        .storeUint(0b100, 3)
        .storeUint(BASECHAIN, 8)
        .storeUint(stateInitHash, 256)
}

@inline
fun deployNftItem(itemIndex: int, nftItemCode: cell, tonAmount: coins, initParams: Cell<NftItemInitAtDeployment>) {
    val deployMsg = createMessage({
        bounce: true,
        dest: {
            stateInit: {
                code: nftItemCode,
                data: NftItemStorageUninitialized.generateEmptyData(itemIndex, contract.getAddress())
            }
        },
        value: tonAmount,
        body: initParams,
    });
    deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
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
            val respondMsg = createMessage({
                bounce: false,
                dest: senderAddress,
                value: 0,
                body: ResponseRoyaltyParams {
                    queryId: msg.queryId,
                    royaltyParams: storage.royaltyParams.load(),
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
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

get get_nft_address_by_index(itemIndex: int): address {
    val storage = lazy NftCollectionStorage.load();
    val addrBuilt = buildAddressOfNftItem(itemIndex, contract.getAddress(), storage.nftItemCode);
    return address.fromValidBuilder(addrBuilt);
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
