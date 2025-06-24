import "storage.tolk"

const cheap_min_tons_for_storage = ton("0.03");
const cheap_minting_price = ton("0.03");

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

const MY_WORKCHAIN = 0;

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
fun packItemStateInit(itemIndex: int, itemCode: cell): cell {
    val initialItemData: ItemStorage = {
        config: ItemConfig {
            index: itemIndex,
            collectionAddress: contract.getAddress()
        }.toCell(),
        state: null,
    };
    return packStateInit(itemCode, initialItemData.toCell());
}

fun AuctionConfig.isInvalid(self) {
    return
        (self.minBid < cheap_min_tons_for_storage + cheap_minting_price) |
        ((self.maxBid != 0) & (self.maxBid < self.minBid)) |
        (self.minBidStep <= 0) |
        (self.minExtendTime > 60 * 60 * 24 * 7) |
        (self.duration > 60 * 60 * 24 * 365);
}
