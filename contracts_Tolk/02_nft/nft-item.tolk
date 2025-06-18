import "params.tolk"
import "op-codes.tolk"

//
//  TON NFT Item Smart Contract
//

/*

    NOTE that this tokens can be transferred within the same workchain.

    This is suitable for most tokens, if you need tokens transferable between workchains there are two solutions:

    1) use more expensive but universal function to calculate message forward fee for arbitrary destination (see `misc/forward-fee-calc.cs`)

    2) use token holder proxies in target workchain (that way even 'non-universal' token can be used from any workchain)

*/

@pure
fun minTonsForStorage(): int
    asm "50000000 PUSHINT"; // 0.05 TON

//
//  Storage
//
//  uint64 index
//  MsgAddressInt collection_address
//  MsgAddressInt owner_address
//  cell content
//

fun loadData(): (bool, int, address, address?, cell?) {
    var ds: slice = contract.getData().beginParse();
    var (index, collectionAddress) = (ds.loadUint(64), ds.loadAddress());
    if (ds.remainingBitsCount() > 0) {
        return (true, index, collectionAddress, ds.loadAddress(), ds.loadRef());
    } else {
        return (false, index, collectionAddress, null, null); // nft not initialized yet
    }
}

fun storeData(index: int, collectionAddress: address, ownerAddress: address, content: cell) {
    contract.setData(
        beginCell()
            .storeUint(index, 64)
            .storeAddress(collectionAddress)
            .storeAddress(ownerAddress)
            .storeRef(content)
            .endCell()
    );
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

@inline
fun transferOwnership(myBalance: int, index: int, collectionAddress: address, ownerAddress: address, content: cell, senderAddress: address, queryId: int, inMsgBody: slice, fwdFees: int) {
    assert(senderAddress == ownerAddress) throw 401;

    var newOwnerAddress = inMsgBody.loadAddress();
    forceChain(newOwnerAddress);
    var responseDestination = inMsgBody.loadAddress();
    inMsgBody.loadInt(1); // this nft don't use custom_payload
    var forwardAmount: int = inMsgBody.loadCoins();
    assert(inMsgBody.remainingBitsCount() >= 1) throw 708;

    var restAmount = myBalance - minTonsForStorage();
    if (forwardAmount) {
        restAmount -= (forwardAmount + fwdFees);
    }
    var needResponse = responseDestination.isInternal();
    if (needResponse) {
        restAmount -= fwdFees;
    }

    assert(restAmount >= 0) throw 402; // base nft spends fixed amount of gas, will not check for response

    if (forwardAmount) {
        sendMsg(newOwnerAddress, forwardAmount, OP_OWNERSHIP_ASSIGNED(), queryId, beginCell().storeAddress(ownerAddress).storeSlice(inMsgBody), 1);  // paying fees, revert on errors
    }
    if (needResponse) {
        forceChain(responseDestination);
        sendMsg(responseDestination, restAmount, OP_EXCESSES(), queryId, null, 1); // paying fees, revert on errors
    }

    storeData(index, collectionAddress, newOwnerAddress, content);
}

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

    cs.loadAddress(); // skip dst
    cs.loadCoins(); // skip value
    cs.skipBits(1); // skip extracurrency collection
    cs.loadCoins(); // skip ihr_fee
    var fwdFee: int = mulDivFloor(cs.loadCoins(), 3, 2); // we use message fwd_fee for estimation of forward_payload costs


    var (isInit: bool, index: int, collectionAddress: address, ownerAddress: address?, content: cell?) = loadData();
    if (!isInit) {
        assert(collectionAddress == senderAddress) throw 405;
        storeData(index, collectionAddress, inMsgBody.loadAddress(), inMsgBody.loadRef());
        return;
    }
    ownerAddress = ownerAddress!;
    content = content!;

    var op: int = inMsgBody.loadUint(32);
    var queryId: int = inMsgBody.loadUint(64);

    if (op == OP_TRANSFER()) {
        transferOwnership(myBalance, index, collectionAddress, ownerAddress, content, senderAddress, queryId, inMsgBody, fwdFee);
        return;
    }
    if (op == OP_GET_STATIC_DATA()) {
        sendMsg(senderAddress, 0, OP_REPORT_STATIC_DATA(), queryId, beginCell().storeUint(index, 256).storeAddress(collectionAddress), 64);  // carry all the remaining value of the inbound message
        return;
    }
    throw 0xffff;
}

//
//  GET Methods
//

get get_nft_data(): (bool, int, address, address?, cell?) {
    var (isInit: bool, index: int, collectionAddress: address, ownerAddress: address?, content: cell?) = loadData();
    return (isInit, index, collectionAddress, ownerAddress, content);
}
