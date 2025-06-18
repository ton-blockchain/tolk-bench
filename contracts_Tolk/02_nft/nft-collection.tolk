import "@stdlib/tvm-dicts"

import "params.tolk"
import "op-codes.tolk"

// NFT collection smart contract

// storage scheme
// default#_ royalty_factor:uint16 royalty_base:uint16 royalty_address:MsgAddress = RoyaltyParams;
// storage#_ owner_address:MsgAddress next_item_index:uint64
//           ^[collection_content:^Cell common_content:^Cell]
//           nft_item_code:^Cell
//           royalty_params:^RoyaltyParams
//           = Storage;

@inline
fun loadData(): (address, int, cell, cell, cell) {
    var ds = contract.getData().beginParse();
    return (
        ds.loadAddress(), // owner_address
        ds.loadUint(64), // next_item_index
        ds.loadRef(), // content
        ds.loadRef(), // nft_item_code
        ds.loadRef()  // royalty_params
    );
}

@inline
fun saveData(ownerAddress: address, nextItemIndex: int, content: cell, nftItemCode: cell, royaltyParams: cell) {
    contract.setData(beginCell()
        .storeAddress(ownerAddress)
        .storeUint(nextItemIndex, 64)
        .storeRef(content)
        .storeRef(nftItemCode)
        .storeRef(royaltyParams)
        .endCell());
}

fun calculateNftItemStateInit(itemIndex: int, nftItemCode: cell): cell {
    var data: cell = beginCell().storeUint(itemIndex, 64).storeAddress(contract.getAddress()).endCell();
    return beginCell().storeUint(0, 2).storeDict(nftItemCode).storeDict(data).storeUint(0, 1).endCell();
}

fun calculateNftItemAddress(wc: int, stateInit: cell): address {
    return beginCell().storeUint(4, 3)
        .storeInt(wc, 8)
        .storeUint(stateInit.hash(), 256)
        .endCell()
        .beginParse() as address;
}

fun deployNftItem(itemIndex: int, nftItemCode: cell, amount: int, nftContent: cell) {
    var stateInit = calculateNftItemStateInit(itemIndex, nftItemCode);
    var nftAddress = calculateNftItemAddress(workchain(), stateInit);
    var msg = beginCell()
        .storeUint(0x18, 6)
        .storeAddress(nftAddress)
        .storeCoins(amount)
        .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
        .storeRef(stateInit)
        .storeRef(nftContent);
    sendRawMessage(msg.endCell(), 1); // pay transfer fees separately, revert on errors
}

@inline
fun sendRoyaltyParams(toAddress: address, queryId: int, data: slice) {
    var msg = beginCell()
        .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 011000
        .storeAddress(toAddress)
        .storeCoins(0)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeUint(OP_REPORT_ROYALTY_PARAMS(), 32)
        .storeUint(queryId, 64)
        .storeSlice(data);
    sendRawMessage(msg.endCell(), 64); // carry all the remaining value of the inbound message
}

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

    var op: int = inMsgBody.loadUint(32);
    var queryId: int = inMsgBody.loadUint(64);

    var (ownerAddress, nextItemIndex, content, nftItemCode, royaltyParams) = loadData();

    if (op == OP_GET_ROYALTY_PARAMS()) {
        sendRoyaltyParams(senderAddress, queryId, royaltyParams.beginParse());
        return;
    }

    assert(senderAddress == ownerAddress) throw 401;


    if (op == 1) {
        // deploy new nft
        var itemIndex: int = inMsgBody.loadUint(64);
        assert(itemIndex <= nextItemIndex) throw 402;
        var isLast = itemIndex == nextItemIndex;
        deployNftItem(itemIndex, nftItemCode, inMsgBody.loadCoins(), inMsgBody.loadRef());
        if (isLast) {
            nextItemIndex += 1;
            saveData(ownerAddress, nextItemIndex, content, nftItemCode, royaltyParams);
        }
        return;
    }
    if (op == 2) {
        // batch deploy of new nfts
        var counter: int = 0;
        var deployList: dict = inMsgBody.loadRef();
        do {
            var (itemIndex, item, isF) = deployList.uDictDeleteFirstAndGet(64);
            if (isF) {
                counter += 1;
                if (counter >= 250) {
                    // Limit due to limits of action list size
                    throw 399;
                }

                assert(itemIndex! <= nextItemIndex) throw 403 + counter;
                deployNftItem(itemIndex!, nftItemCode, item!.loadCoins(), item!.loadRef());
                if (itemIndex! == nextItemIndex) {
                    nextItemIndex += 1;
                }
            }
        } while (isF);
        saveData(ownerAddress, nextItemIndex, content, nftItemCode, royaltyParams);
        return;
    }
    if (op == 3) {
        // change owner
        var newOwnerAddress = inMsgBody.loadAddress();
        saveData(newOwnerAddress, nextItemIndex, content, nftItemCode, royaltyParams);
        return;
    }
    throw 0xffff;
}

// Get methods

get get_collection_data(): (int, cell, address) {
    var (ownerAddress, nextItemIndex, content, _, _) = loadData();
    var cs: slice = content.beginParse();
    return (nextItemIndex, cs.loadRef(), ownerAddress);
}

get get_nft_address_by_index(index: int): address {
    var (_, _, _, nftItemCode, _) = loadData();
    var stateInit: cell = calculateNftItemStateInit(index, nftItemCode);
    return calculateNftItemAddress(workchain(), stateInit);
}

get royalty_params(): (int, int, address) {
    var (_, _, _, _, royalty) = loadData();
    var rs: slice = royalty.beginParse();
    return (rs.loadUint(16), rs.loadUint(16), rs.loadAddress());
}

get get_nft_content(index: int, individualNftContent: cell): cell {
    var (_, _, content, _, _) = loadData();
    var cs: slice = content.beginParse();
    cs.loadRef();
    var commonContent: slice = cs.loadRef().beginParse();
    return (beginCell()
        .storeUint(1, 8) // offchain tag
        .storeSlice(commonContent)
        .storeRef(individualNftContent)
        .endCell());
}
