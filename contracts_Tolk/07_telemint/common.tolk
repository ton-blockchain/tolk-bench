

const one_ton = 1000000000;
const dns_next_resolver_prefix = 0xba93; // dns_next_resolver prefix - https://github.com/ton-blockchain/ton/blob/7e3df93ca2ab336716a230fceb1726d81bac0a06/crypto/block/block.tlb#L819

const OP_FILL_UP = 0x370fec51;
const OP_OUTBID_NOTIFICATION = 0x557cea20;
const OP_CHANGE_DNS_RECORD = 0x4eb1f0f9;
const OP_DNS_BALANCE_RELEASE = 0x4ed14b65;

const OP_TELEMINT_MSG_DEPLOY = 0x4637289a;
const OP_TELEITEM_MSG_DEPLOY = 0x299a3e15;
const OP_TELEITEM_START_AUCTION = 0x487a8e81;
const OP_TELEITEM_CANCEL_AUCTION = 0x371638ae;
const OP_TELEITEM_BID_INFO = 0x38127de1;
const OP_TELEITEM_RETURN_BID = 0xa43227e1;
const OP_TELEITEM_OK = 0xa37a0983;

const OP_NFT_CMD_TRANSFER = 0x5fcc3d14;
const OP_NFT_CMD_GET_STATIC_DATA = 0x2fcb26a2;
const OP_NFT_CMD_EDIT_CONTENT = 0x1a0b9d51;
const OP_NFT_ANSWER_OWNERSHIP_ASSIGNED = 0x05138d91;
const OP_NFT_ANSWER_EXCESSES = 0xd53276db;

const OP_OWNERSHIP_ASSIGNED = 0x05138d91;
const OP_EXCESSES = 0xd53276db;
const OP_GET_STATIC_DATA = 0x2fcb26a2;
const OP_REPORT_STATIC_DATA = 0x8b771735;
const OP_GET_ROYALTY_PARAMS = 0x693d3950;
const OP_REPORT_ROYALTY_PARAMS = 0xa8cb00ad;

const ERR_INVALID_LENGTH = 201;
const ERR_INVALID_SIGNATURE = 202;
const ERR_WRONG_SUBWALLET_ID = 203;
const ERR_NOT_YET_VALID_SIGNATURE = 204;
const ERR_EXPIRED_SIGNATURE = 205;
const ERR_NOT_ENOUGH_FUNDS = 206;
const ERR_WRONG_TOPUP_COMMENT = 207;
const ERR_UNKNOWN_OP = 208;
const ERR_UNINITED = 210;
const ERR_TOO_SMALL_STAKE = 211;
const ERR_EXPECTED_ONCHAIN_CONTENT = 212;
const ERR_FORBIDDEN_NOT_DEPLOY = 213;
const ERR_FORBIDDEN_NOT_STAKE = 214;
const ERR_FORBIDDEN_TOPUP = 215;
const ERR_FORBIDDEN_TRANSFER = 216;
const ERR_FORBIDDEN_CHANGE_DNS = 217;
const ERR_FORBIDDEN_TOUCH = 218;
const ERR_NO_AUCTION = 219;
const ERR_FORBIDDEN_AUCTION = 220;
const ERR_ALREADY_HAS_STAKES = 221;
const ERR_AUCTION_ALREADY_STARTED = 222;
const ERR_INVALID_AUCTION_CONFIG = 223;
const ERR_INCORRECT_WORKCHAIN = 333;
const ERR_NO_FIRST_ZERO_BYTE = 413;
const ERR_BAD_SUBDOMAIN_LENGTH = 70;

const min_tons_for_storage = one_ton;
const workchain = 0;

@pure
fun slice.isSkipFirstZeroByte(mutate self): int
    asm "x{00} SDBEGINSQ";

@inline
fun forceChain(address: address) {
    assert(address.getWorkchain() == workchain) throw ERR_INCORRECT_WORKCHAIN;
}


// "ton\0test\0" -> "ton"
@inline
fun getTopDomainBits(domain: slice): int {
    var i: int = -8;
    var char: int = 1;
    while (char) {
        i += 8;
        char = domain.loadUint(8); // we do not check domain.length because it MUST contains \0 character
    }
    assert(i) throw 201; // should not start with \0
    return i;
}

@inline
fun slice.loadText(mutate self) {
    var len: int = self.loadUint(8);
    var text: slice = self.loadBits(len * 8);
    return text;
}

@inline
fun slice.loadTextRef(mutate self) {
    var textCs: slice = self.loadRef().beginParse();
    var text: slice = textCs.loadText();
    return text;
}

@inline
fun builder.storeText(mutate self, text: slice): self {
    var len: int = text.remainingBitsCount();
    var (bytes: int, rem: int) = divMod(len, 8);
    assert(!(rem)) throw ERR_INVALID_LENGTH;
    return self.storeUint(bytes, 8)
               .storeSlice(text);
}

@inline
fun unpackTokenInfo(c: cell): (slice, slice) {
    var cs: slice = c.beginParse();
    var res = (
            cs.loadText(),
            cs.loadText()
    );
    cs.assertEnd();
    return res;
}

fun packTokenInfo(name: slice, domain: slice): cell {
    return beginCell()
            .storeText(name)
            .storeText(domain)
            .endCell();
}

@inline
fun packStateInit(code: cell, data: cell): cell {
    return beginCell()
            .storeUint(0, 2)
            .storeMaybeRef(code)
            .storeMaybeRef(data)
            .storeUint(0, 1)
            .endCell();
}

@inline
fun packInitIntMessage(dest: address, stateInit: cell, body: cell): cell {
    return beginCell()
            .storeUint(0x18, 6) // 011000 tag=0, ihr_disabled=1, allow_bounces=1, bounced=0, add_none
            .storeAddress(dest)
            .storeCoins(0) // grams
            .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
            .storeRef(stateInit)
            .storeRef(body)
            .endCell();
}

@inline
fun sendMsg(toAddress: address, amount: int, op: int, queryId: int, payload: builder?, mode: int) {
    var msg = beginCell()
            .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 010000
            .storeAddress(toAddress)
            .storeCoins(amount)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeUint(op, 32)
            .storeUint(queryId, 64);

    if (!(payload == null)) {
        msg = msg.storeBuilder(payload);
    }

    sendRawMessage(msg.endCell(), mode);
}

@inline
fun calculateAddress(wc: int, stateInit: cell): address {
    var res: slice = beginCell()
            .storeUint(4, 3)
            .storeInt(wc, 8)
            .storeUint(stateInit.hash(), 256)
            .endCell()
            .beginParse();
    return res as address;
}

@inline
fun unpackItemConfig(c: cell): (int, address) {
    var cs: slice = c.beginParse();
    var res = (
            cs.loadUint(256),
            cs.loadAddress()
    );
    cs.assertEnd();
    return res;
}

@inline
fun packItemConfig(itemIndex: int, collectionAddress: address): cell {
    return beginCell()
            .storeUint(itemIndex, 256)
            .storeAddress(collectionAddress)
            .endCell();
}

@inline
fun unpackItemData(): (cell, cell?) {
    var cs = contract.getData().beginParse();
    var res = (cs.loadRef(), cs.loadMaybeRef());
    cs.assertEnd();
    return res;
}

@inline
fun packNftRoyaltyParams(numerator: int, denominator: int, destination: slice): cell {
    return beginCell()
            .storeUint(numerator, 16)
            .storeUint(denominator, 16)
            .storeSlice(destination)
            .endCell();
}

@inline
fun unpackNftRoyaltyParams(c: cell): (int, int, address) {
    var cs = c.beginParse();
    var res = (
            cs.loadUint(16),
            cs.loadUint(16),
            cs.loadAddress()
    );
    cs.assertEnd();
    return res;
}

@inline
fun packItemData(config: cell, state: cell?): cell {
    return beginCell()
            .storeRef(config)
            .storeMaybeRef(state)
            .endCell();
}

@inline
fun packItemContent(nftContent: cell, dns: cell?, tokenInfo: cell): cell {
    return beginCell()
            .storeRef(nftContent)
            .storeDict(dns)
            .storeRef(tokenInfo)
            .endCell();
}

@inline
fun unpackItemContent(c: cell): (cell, dict, cell) {
    var cs = c.beginParse();
    var res = (
            cs.loadRef(),
            cs.loadDict(),
            cs.loadRef()
    );
    cs.assertEnd();
    return res;
}

@inline
fun unpackItemState(c: cell): (address, cell, cell?, cell) {
    var cs = c.beginParse();
    var res = (
            cs.loadAddress(),
            cs.loadRef(),
            cs.loadMaybeRef(),
            cs.loadRef()
    );
    cs.assertEnd();
    return res;
}

@inline
fun packItemState(ownerAddress: address, content: cell, auction: cell?, royaltyParams: cell): cell {
    return beginCell()
            .storeAddress(ownerAddress)
            .storeRef(content)
            .storeMaybeRef(auction)
            .storeRef(royaltyParams)
            .endCell();
}

@inline
fun saveItemData(config: cell, state: cell) {
    contract.setData(packItemData(config, state));
}

@inline
fun packItemStateInit(itemIndex: int, itemCode: cell): cell {
    var itemConfig = packItemConfig(itemIndex, contract.getAddress());
    var itemData = packItemData(itemConfig, null);
    return packStateInit(itemCode, itemData);
}

@inline
fun packTeleitemMsgDeploy(senderAddress: address, bid: int, info: cell, content: cell, auctionConfig: cell, royaltyParams: cell): cell {
    return beginCell()
            .storeUint(OP_TELEITEM_MSG_DEPLOY, 32)
            .storeAddress(senderAddress)
            .storeCoins(bid)
            .storeRef(info)
            .storeRef(content)
            .storeRef(auctionConfig)
            .storeRef(royaltyParams)
            .endCell();
}

@inline
fun unpackTeleitemMsgDeploy(cs: slice): (address, int, cell, cell, cell, cell) {
    return (cs.loadAddress(),
            cs.loadCoins(),
            cs.loadRef(),
            cs.loadRef(),
            cs.loadRef(),
            cs.loadRef());
}

@inline
fun unpackCollectionData(): (bool, int, int, cell, cell, slice, cell) {
    var cs = contract.getData().beginParse();
    var res = (
            cs.loadBool(), // touched
            cs.loadUint(32), // subwallet_id
            cs.loadUint(256), // owner_key
            cs.loadRef(), // content
            cs.loadRef(), // item_code
            cs.loadTextRef(), // full_domain
            cs.loadRef() // royalty_params
    );
    cs.assertEnd();
    return res;
}

@inline
fun saveCollectionData(touched: bool, subwalletId: int, ownerKey: int, content: cell, itemCode: cell, fullDomain: slice, royaltyParams: cell) {
    var data: cell = beginCell()
            .storeBool(touched)
            .storeUint(subwalletId, 32)
            .storeUint(ownerKey, 256)
            .storeRef(content)
            .storeRef(itemCode)
            .storeRef(beginCell().storeText(fullDomain).endCell())
            .storeRef(royaltyParams)
            .endCell();
    contract.setData(data);
}

@inline
fun unpackSignedCmd(cs: slice) {
    return (
            cs.loadBits(512), // signature
            cs.hash(), // hash
            cs.loadUint(32), // subwallet_id
            cs.loadUint(32), // valid_since
            cs.loadUint(32), // valid_till
            cs // cmd
    );
}

@inline
fun unpackDeployMsg(cs: slice) {
    var res = (
            cs.loadText(), // token_name
            cs.loadRef(), // content
            cs.loadRef(), // auction_config
            cs.loadMaybeRef() // royalty
    );
    cs.assertEnd();
    return res;
}

//teleitem_last_bid bidder_address:MsgAddressInt bid:Grams bid_ts:uint32 = TeleitemLastBid;
@inline
fun unpackLastBid(c: cell): (address, int, int) {
    var cs: slice = c.beginParse();
    var res = (
            cs.loadAddress(), // bidder_address
            cs.loadCoins(), // bid
            cs.loadUint(32) // bid_ts
    );
    cs.assertEnd();
    return res;
}
@inline
fun packLastBid(bidderAddress: address, bid: int, bidTs: int): cell {
    return beginCell()
            .storeAddress(bidderAddress)
            .storeCoins(bid)
            .storeUint(bidTs, 32)
            .endCell();
}

//teleitem_auction_state$_ last_bid:(Maybe ^TeleitemLastBid) min_bid:Grams end_time:uint32 = TeleitemAuctionState;
@inline
fun unpackAuctionState(c: cell): (cell?, int, int) {
    var cs: slice = c.beginParse();
    var res = (
            cs.loadMaybeRef(), // maybe last_bid
            cs.loadCoins(), // min_bid
            cs.loadUint(32) // end_time
    );
    cs.assertEnd();
    return res;
}
@inline
fun packAuctionState(lastBid: cell?, minBid: int, endTime: int): cell {
    return beginCell()
            .storeMaybeRef(lastBid)
            .storeCoins(minBid)
            .storeUint(endTime, 32)
            .endCell();
}

@inline
fun unpackAuctionConfig(c: cell): (address, int, int, int, int, int) {
    var cs: slice = c.beginParse();
    var res = (
            cs.loadAddress(), // beneficiary address
            cs.loadCoins(), // initial_min_bid
            cs.loadCoins(), // max_bid
            cs.loadUint(8), // min_bid_step
            cs.loadUint(32), // min_extend_time
            cs.loadUint(32) // duration
    );
    cs.assertEnd();
    return res;
}

//teleitem_auction$_ state:^TeleitemAuctionState config:^TeleitemConfig = TeleitemAuction;
@inline
fun unpackAuction(c: cell): (cell, cell) {
    var cs: slice = c.beginParse();
    var res = (
            cs.loadRef(),
            cs.loadRef()
    );
    cs.assertEnd();
    return res;
}

@inline
fun packAuction(state: cell, config: cell): cell {
    return beginCell()
            .storeRef(state)
            .storeRef(config)
            .endCell();
}

@inline
fun unpackNftCmdTransfer(cs: slice): (int, address, address, cell?, int, slice) {
    return (
            cs.loadUint(64),
            cs.loadAddress(),
            cs.loadAddress(),
            cs.loadMaybeRef(),
            cs.loadCoins(),
            cs
    );
}
