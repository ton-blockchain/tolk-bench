import "@stdlib/gas-payments"
import "storage"
import "messages"


const MIN_TONS_FOR_STORAGE = ton("0.05");

// actual storage of an NFT item is tricky: it's either initialized or not;
// after NFT has been inited, it's represented as `NftItemStorage`;
// before initialization, it has only index and collectionAddress: `NftItemStorageNotInitialized`;
// hence, we start parsing it, that then we detect, whether it's inited or not
struct NftItemStorageMaybeNotInitialized {
    contractData: slice;
}

// how do we detect whether it's initialized or not?
// the answer: when "inited", we store `content` (cell),
// so, we have a ref, and for uninited, we don't have a ref
fun NftItemStorageMaybeNotInitialized.isInitialized(self) {
    val hasContent = self.contractData.remainingRefsCount();
    return hasContent
}

fun NftItemStorageMaybeNotInitialized.parseNotInitialized(self) {
    return NftItemStorageNotInitialized.fromSlice(self.contractData)
}

fun NftItemStorageMaybeNotInitialized.parseInitialized(self) {
    return NftItemStorage.fromSlice(self.contractData)
}

fun startLoadingNftItemStorage(): NftItemStorageMaybeNotInitialized {
    return {
        contractData: contract.getData().beginParse()
    }
}

fun NftItemStorage.save(self) {
    contract.setData(self.toCell())
}

type AllowedMessageToNftItem =
    AskToTransfer |
    RequestStaticData |
;

fun onInternalMessage(myBalance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {
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

    var loadingStorage = startLoadingNftItemStorage();
    if (!loadingStorage.isInitialized()) {
        val uninitedSt = loadingStorage.parseNotInitialized();
        assert(uninitedSt.collectionAddress == senderAddress) throw 405;

        // using a message from collection, convert "uninitialized" to "initialized" state
        val initParams = NftItemInitAtDeployment.fromSlice(inMsgBody);
        val storage: NftItemStorage = {
            index: uninitedSt.index,
            collectionAddress: uninitedSt.collectionAddress,
            ownerAddress: initParams.ownerAddress,
            content: initParams.content,
        };
        storage.save();
        return;
    }

    // todo load once or lazily in every branch?
    var storage = loadingStorage.parseInitialized();

    cs.loadAddress(); // skip dst
    cs.loadCoins(); // skip value
    cs.skipBits(1); // skip extracurrency collection
    cs.loadCoins(); // skip ihr_fee
    val incomingFwdFee = cs.loadCoins();
    var fwdFee = calculateOriginalMessageFee(BASECHAIN, incomingFwdFee);

    val msg = lazy AllowedMessageToNftItem.fromSlice(inMsgBody);

    match (msg) {
        AskToTransfer => {
            assert(senderAddress == storage.ownerAddress) throw 401;

            assert(msg.forwardPayload.remainingBitsCount()) throw 708;
            assert(msg.newOwnerAddress.getWorkchain() == BASECHAIN) throw 333;

            var restAmount = myBalance - MIN_TONS_FOR_STORAGE;
            if (msg.forwardTonAmount) {
                restAmount -= (msg.forwardTonAmount + fwdFee);
            }
            var needResponse = msg.sendExcessesTo.isInternal();
            if (needResponse) {
                assert(msg.sendExcessesTo.getWorkchain() == BASECHAIN) throw 333;
                restAmount -= fwdFee;
            }

            assert(restAmount >= 0) throw 402; // base nft spends fixed amount of gas, will not check for response

            if (msg.forwardTonAmount) {
                val ownershipMsg = createMessage({
                    bounce: false,
                    dest: msg.newOwnerAddress,
                    value: msg.forwardTonAmount,
                    body: NotificationOwnershipAssigned {
                        queryId: msg.queryId,
                        ownerAddress: storage.ownerAddress,
                        payload: msg.forwardPayload,
                    }
                });
                ownershipMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            if (needResponse) {
                val excessesMsg = createMessage({
                    bounce: false,
                    dest: msg.sendExcessesTo,
                    value: restAmount,
                    body: ReturnExcessesBack {
                        queryId: msg.queryId,
                    }
                });
                excessesMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            storage.ownerAddress = msg.newOwnerAddress;
            storage.save();
        }

        RequestStaticData => {
            val respondMsg = createMessage({
                bounce: false,
                dest: senderAddress,
                value: 0,
                // why ever, in FunC implementation, item index was encoded as 256-bit (not 64-bit),
                // do the same here to pass FunC tests;
                // but since a response becomes too long (64 + 256 + address), the compiler will create a ref;
                // force the compiler not to create a ref, because it's guaranteed that with
                // value (coins) = 0 it will nevertheless fit into a message cell directly
                body: UnsafeBodyNoRef {
                    forceInline: ResponseStaticData {
                        queryId: msg.queryId,
                        index: storage.index as uint256,
                        collectionAddress: storage.collectionAddress,
                    }
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        else => throw 0xFFFF
    }
}



struct NftDataReply {
    isInitialized: bool;
    itemIndex: int;
    collectionAddress: address;
    ownerAddress: address? = null;
    content: Cell<SnakeString>? = null;
}

get get_nft_data(): NftDataReply {
    var loadingStorage = startLoadingNftItemStorage();
    if (!loadingStorage.isInitialized()) {
        val uninitedSt = loadingStorage.parseNotInitialized();
        return {
            isInitialized: false,
            itemIndex: uninitedSt.index,
            collectionAddress: uninitedSt.collectionAddress,
        }
    }

    val storage = loadingStorage.parseInitialized();
    return {
        isInitialized: true,
        itemIndex: storage.index,
        collectionAddress: storage.collectionAddress,
        ownerAddress: storage.ownerAddress,
        content: storage.content,
    }
}
