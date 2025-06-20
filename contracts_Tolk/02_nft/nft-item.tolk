import "@stdlib/gas-payments.tolk"
import "op-codes.tolk"
import "storage.tolk"
import "messages.tolk"

//
//  TON NFT Item Smart Contract
//

const MIN_TONS_FOR_STORAGE = ton("0.05");

// actual storage of NFT item is tricky: it's either inited or not;
// after NFT has been inited, it's represented as `NftItemStorage`;
// before initialization, it has only index and collectionAddress: `NftItemStorageUninitialized`;
// hence, we start parsing it, that then we detect, whether it's inited or not
struct NftItemStorageEitherInitedOrNot {
    contractData: slice;
}

// how do we detect whether it's inited or not?
// the answer: when "inited", we store `content` (cell),
// so, we have a ref, and for uninited, we don't have a ref
fun NftItemStorageEitherInitedOrNot.isInited(self) {
    val hasContent = self.contractData.remainingRefsCount();
    return hasContent
}

fun NftItemStorageEitherInitedOrNot.parseAsUninited(self) {
    return NftItemStorageUninitialized.fromSlice(self.contractData)
}

fun NftItemStorageEitherInitedOrNot.parseAsInited(self) {
    return NftItemStorage.fromSlice(self.contractData)
}

fun startLoadingNftItemStorage(): NftItemStorageEitherInitedOrNot {
    return {
        contractData: contract.getData().beginParse()
    }
}

fun NftItemStorage.save(self) {
    contract.setData(self.toCell())
}

@inline
fun sendMsg(toAddress: address, amount: int, op: int, queryId: int, payload: builder?, sendMode: int) {
    var msg = beginCell()
        .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 010000
        .storeAddress(toAddress)
        .storeCoins(amount)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeUint(op, 32)
        .storeUint(queryId, 64);

    if (payload != null) {
        msg = msg.storeBuilder(payload);
    }

    sendRawMessage(msg.endCell(), sendMode);
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
    if (!loadingStorage.isInited()) {
        val uninitedSt = loadingStorage.parseAsUninited();
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
    var storage = loadingStorage.parseAsInited();

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
                sendMsg(msg.newOwnerAddress, msg.forwardTonAmount, OP_OWNERSHIP_ASSIGNED, msg.queryId,
                    beginCell().storeAddress(storage.ownerAddress).storeSlice(msg.forwardPayload), 1);  // paying fees, revert on errors
            }
            if (needResponse) {
                sendMsg(msg.sendExcessesTo, restAmount, OP_EXCESSES, msg.queryId, null, 1); // paying fees, revert on errors
            }

            storage.ownerAddress = msg.newOwnerAddress;
            storage.save();
        }
        RequestStaticData => {
            sendMsg(senderAddress, 0, OP_REPORT_STATIC_DATA, msg.queryId,
                beginCell().storeUint(storage.index, 256).storeAddress(storage.collectionAddress), 64);  // carry all the remaining value of the inbound message
        }

        else => throw 0xFFFF
    }
}

//
//  GET Methods
//

get get_nft_data(): (bool, int, address, address?, cell?) {
    var loadingStorage = startLoadingNftItemStorage();
    if (!loadingStorage.isInited()) {
        val uninitedSt = loadingStorage.parseAsUninited();
        return (false, uninitedSt.index, uninitedSt.collectionAddress, null, null);
    } else {
        val storage = loadingStorage.parseAsInited();
        return (true, storage.index, storage.collectionAddress, storage.ownerAddress, storage.content);
    }
}
