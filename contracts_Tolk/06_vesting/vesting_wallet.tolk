tolk 0.13

import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments"
import "@stdlib/lisp-lists"


const OP_ADD_WHITELIST = 0x7258a69b;
const OP_ADD_WHITELIST_RESPONSE = 0xf258a69b;
const OP_SEND = 0xa7733acd;
const OP_SEND_RESPONSE = 0xf7733acd;

// https://github.com/ton-blockchain/ton/blob/master/crypto/smartcont/elector-code.fc
// https://github.com/ton-blockchain/ton/blob/master/crypto/smartcont/config-code.fc
const OP_ELECTOR_NEW_STAKE = 0x4e73744b;
const OP_ELECTOR_RECOVER_STAKE = 0x47657424;
const OP_VOTE_FOR_COMPLAINT = 0x56744370;
const OP_VOTE_FOR_PROPOSAL = 0x566f7465;

// single-nominator-pool: empty message to deposit; 0x1000 to withdraw https://github.com/orbs-network/single-nominator/blob/main/contracts/single-nominator.fc
const OP_SINGLE_NOMINATOR_POOL_WITHDRAW = 0x1000;
const OP_SINGLE_NOMINATOR_POOL_CHANGE_VALIDATOR = 0x1001;

// tonstakers.com: deposit to pool; burn, vote to jetton-wallet - https://ton-ls-protocol.gitbook.io/ton-liquid-staking-protocol/protocol-concept/message-processing
const OP_TON_STAKERS_DEPOSIT = 0x47d54391;
const OP_JETTON_BURN = 0x595f07bc;
const OP_TON_STAKERS_VOTE = 0x69fb306c;

const ERROR_EXPIRED = 36;
const ERROR_INVALID_SEQNO = 33;
const ERROR_INVALID_SUBWALLET_ID = 34;
const ERROR_INVALID_SIGNATURE = 35;

const ERROR_SEND_MODE_NOT_ALLOWED = 100;
const ERROR_NON_BOUNCEABLE_NOT_ALLOWED = 101;
const ERROR_STATE_INIT_NOT_ALLOWED = 102;
const ERROR_COMMENT_NOT_ALLOWED = 103;
const ERROR_SYMBOLS_NOT_ALLOWED = 104;

// https://github.com/ton-blockchain/ton/blob/d2b418bb703ed6ccd89b7d40f9f1e44686012014/crypto/block/block.tlb#L605
const config_id = 0;
const elector_id = 1;

// data

global stored_seqno: int;
global stored_subwallet: int;
global public_key: int;

global whitelist: dict;

global vesting_start_time: int;
global vesting_total_duration: int;
global unlock_period: int;
global cliff_duration: int;
global vesting_total_amount: int;
global vesting_sender_address: address;
global owner_address: address;

// CONDITIONS:
// vesting_total_duration > 0
// vesting_total_duration <= 135 years (2^32 seconds)
// unlock_period > 0
// unlock_period <= vesting_total_duration
// cliff_duration >= 0
// cliff_duration < vesting_total_duration
// vesting_total_duration mod unlock_period == 0
// cliff_duration mod unlock_period == 0

@inline
fun loadVestingParameters(data: cell) {
    var ds: slice = data.beginParse();
    vesting_start_time = ds.loadUint(64);
    vesting_total_duration = ds.loadUint(32);
    unlock_period = ds.loadUint(32);
    cliff_duration = ds.loadUint(32);
    vesting_total_amount = ds.loadCoins();
    vesting_sender_address = ds.loadAddress();
    owner_address = ds.loadAddress();
    ds.assertEnd();
}

@inline
fun packVestingParameters(): cell {
    return beginCell()
            .storeUint(vesting_start_time, 64)
            .storeUint(vesting_total_duration, 32)
            .storeUint(unlock_period, 32)
            .storeUint(cliff_duration, 32)
            .storeCoins(vesting_total_amount) // max 124 bits
            .storeAddress(vesting_sender_address) // 267 bit
            .storeAddress(owner_address) // 267 bit
            .endCell();
}

@inline_ref
fun loadData() {
    var ds: slice = contract.getData().beginParse();
    stored_seqno = ds.loadUint(32);
    stored_subwallet = ds.loadUint(32);
    public_key = ds.loadUint(256);
    whitelist = ds.loadDict();
    loadVestingParameters(ds.loadRef());
    ds.assertEnd();
}

@inline_ref
fun saveData() {
    contract.setData(
            beginCell()
                    .storeUint(stored_seqno, 32)
                    .storeUint(stored_subwallet, 32)
                    .storeUint(public_key, 256)
                    .storeDict(whitelist)
                    .storeRef(packVestingParameters())
                    .endCell()
    );
}

// messages utils


const SEND_MODE_PAY_FEES_SEPARETELY = 1;

@inline
fun returnExcess(toAddress: address, op: int, queryId: int) {
    var msg: builder = beginCell()
            .storeUint(BOUNCEABLE, 6)
            .storeAddress(toAddress)
            .storeCoins(0)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeUint(op, 32)
            .storeUint(queryId, 64);

    sendRawMessage(msg.endCell(), SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

@inline_ref
fun matchAddressFromConfig(address: address, configId: int): bool {
    var (addressWc: int, addressHash: int) = address.getWorkchainAndHash();
    if (addressWc != -1) {
        return false;
    }
    var configCell: cell? = blockchain.configParam(configId);
    if (configCell == null) {
        return false;
    }
    var configSlice: slice = configCell.beginParse();
    if (configSlice.remainingBitsCount() < 256) {
        return false;
    }
    return addressHash == configSlice.preloadUint(256);
}


// address utils

const ADDRESS_SIZE = 264; // 256 + 8

@inline
fun packAddress(address: address): slice {
    var (wc: int, addressHash: int) = address.getWorkchainAndHash();
    return beginCell().storeInt(wc, 8).storeUint(addressHash, 256).endCell().beginParse();
}

@inline
fun unpackAddress(address: slice): (int, int) {
    var wc: int = address.loadInt(8);
    var addressHash: int = address.loadUint(256);
    return (wc, addressHash);
}

@inline
fun isWhitelisted(address: address): bool {
    var (_, found: bool) = whitelist.sDictGet(ADDRESS_SIZE, packAddress(address));
    return found;
}

// locked

@inline_ref
fun getLockedAmount(nowTime: int): int {
    if (nowTime > vesting_start_time + vesting_total_duration) {
        return 0;
    }

    if (nowTime < vesting_start_time + cliff_duration) {
        return vesting_total_amount;
    }

    return vesting_total_amount - mulDivFloor(vesting_total_amount,
            (nowTime - vesting_start_time) / unlock_period,
            vesting_total_duration / unlock_period);
}

@inline_ref
fun mySendMessage(inMsgBody: slice) {
    var sendMode: int = inMsgBody.loadUint(8);
    var msg: cell = inMsgBody.loadRef();
    inMsgBody.assertEnd(); // only 1 ref allowed

    var lockedAmount: int = getLockedAmount(blockchain.now());

    if (lockedAmount > 0) { // if the vesting has expired, you can send any messages

        assert(sendMode == SEND_MODE_IGNORE_ERRORS + SEND_MODE_PAY_FEES_SEPARETELY) throw ERROR_SEND_MODE_NOT_ALLOWED;

        var msgCs: slice = msg.beginParse();
        var flags: int = msgCs.loadUint(4);
        var senderAddress = msgCs.loadAddress(); // skip
        var destinationAddress = msgCs.loadAddress();

        if (destinationAddress != vesting_sender_address) { // can send to vesting_sender_address any message

            if (isWhitelisted(destinationAddress)) {
                var isBounceable = (flags & 2) == 2;
                assert(isBounceable) throw ERROR_NON_BOUNCEABLE_NOT_ALLOWED;

                msgCs.loadCoins(); // skip value
                msgCs.skipBits(1); // skip extracurrency collection
                msgCs.loadCoins(); // skip ihr_fee
                msgCs.loadCoins(); // skip fwd_fee
                msgCs.loadUint(64); // skip createdLt
                msgCs.loadUint(32); // skip createdAt
                var maybeStateInit: int = msgCs.loadUint(1);
                assert(maybeStateInit == 0) throw ERROR_STATE_INIT_NOT_ALLOWED;

                var maybeBody: int = msgCs.loadUint(1);
                var body: slice = maybeBody ? msgCs.loadRef().beginParse() : msgCs;

                if (matchAddressFromConfig(destinationAddress, elector_id)) { // elector - direct validation

                    var op: int = body.loadUint(32);
                    assert((op == OP_ELECTOR_NEW_STAKE) | (op == OP_ELECTOR_RECOVER_STAKE) | (op == OP_VOTE_FOR_COMPLAINT) | (op == OP_VOTE_FOR_PROPOSAL)) throw ERROR_COMMENT_NOT_ALLOWED;

                } else if (matchAddressFromConfig(destinationAddress, config_id)) { // conifg - direct validation

                    var op: int = body.loadUint(32);
                    assert((op == OP_VOTE_FOR_PROPOSAL)) throw ERROR_COMMENT_NOT_ALLOWED;

                } else if (body.remainingBitsCount() > 0) { // empty message allowed for other destination (not elector)

                    var op: int = body.loadUint(32);
                    assert((op == 0) | // text comment
                                    (op == OP_SINGLE_NOMINATOR_POOL_WITHDRAW) | (op == OP_SINGLE_NOMINATOR_POOL_CHANGE_VALIDATOR) | // single-nominator
                                    (op == OP_TON_STAKERS_DEPOSIT) | (op == OP_JETTON_BURN) | (op == OP_TON_STAKERS_VOTE) | // tonstakers.com
                                    (op == OP_VOTE_FOR_PROPOSAL) | (op == OP_VOTE_FOR_COMPLAINT)) throw ERROR_COMMENT_NOT_ALLOWED;

                    if ((op == 0) & (body.remainingBitsCount() > 0)) { // empty text comment allowed
                        var action: int = body.loadUint(8);
                        assert((action ==stringToBase256("d") ) | (action ==stringToBase256("w") ) | // nominator-pool - https://github.com/ton-blockchain/nominator-pool
                                        (action ==stringToBase256("D") ) | (action ==stringToBase256("W") )) throw ERROR_SYMBOLS_NOT_ALLOWED;
                    }
                }

                lockedAmount = 0;
            }

            if (lockedAmount > 0) {
                reserveToncoinsOnBalance(lockedAmount, 2); // mode 2 - at most `amount` nanotons. Bit +2 in y means that the external action does not fail if the specified amount cannot be reserved; instead, all remaining balance is reserved
            }
        }
    }

    sendRawMessage(msg, sendMode);
}

// receive

fun onInternalMessage(myBalance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    if (inMsgBody.remainingBitsCount() < 32 + 64) { // ignore simple transfers
        return;
    }

    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);
    if (flags & 1) { // ignore all bounced messages
        return;
    }
    var senderAddress = cs.loadAddress();

    loadData();

    var op: int = inMsgBody.loadUint(32);
    var queryId: int = inMsgBody.loadUint(64);

    if ((senderAddress == owner_address) & (op == OP_SEND)) {

        mySendMessage(inMsgBody);

        returnExcess(senderAddress, OP_SEND_RESPONSE, queryId);

    } else if ((senderAddress == vesting_sender_address) & (op == OP_ADD_WHITELIST)) {

        var refCs: slice = inMsgBody;
        var hasRefs = false;
        do {
            var whitelistAddress = refCs.loadAddress();
            whitelist.sDictSetBuilder(ADDRESS_SIZE, packAddress(whitelistAddress), beginCell().storeInt(-1, 1));

            hasRefs = refCs.remainingRefsCount() > 0;
            if (hasRefs) {
                var ref: cell = refCs.loadRef();
                refCs = ref.beginParse();
            }
        } while (hasRefs);

        returnExcess(senderAddress, OP_ADD_WHITELIST_RESPONSE, queryId);

        saveData();

    }

    // else just accept coins from anyone
}

// same with wallet-v3 https://github.com/ton-blockchain/ton/blob/master/crypto/smartcont/wallet3-code.fc#L15
fun onExternalMessage(inMsg: slice) {
    var signature: slice = inMsg.loadBits(512);
    var cs: slice = inMsg;
    var (msgSubwalletId: int, validUntil: int, msgSeqno: int) = (cs.loadUint(32), cs.loadUint(32), cs.loadUint(32));
    assert(!(validUntil <= blockchain.now())) throw ERROR_EXPIRED;
    var ds: slice = contract.getData().beginParse();
    var (mySeqno: int, mySubwalletId: int, myPublicKey: int) = (ds.loadUint(32), ds.loadUint(32), ds.loadUint(256));
    assert(msgSeqno == mySeqno) throw ERROR_INVALID_SEQNO;
    assert(msgSubwalletId == mySubwalletId) throw ERROR_INVALID_SUBWALLET_ID;
    assert(isSignatureValid(inMsg.hash(), signature, myPublicKey)) throw ERROR_INVALID_SIGNATURE;

    acceptExternalMessage();

    loadData();

    if (cs.remainingRefsCount() == 1) {
        try {
            mySendMessage(cs);
        } catch (y, x) {
        }
    }

    stored_seqno += 1;
    saveData();
}

// get-methods

// same with wallet-v3 and wallet-v4
get seqno(): int {
    return contract.getData().beginParse().preloadUint(32);
}

// same with wallet-v4 https://github.com/ton-blockchain/wallet-contract/blob/main/func/wallet-v4-code.fc
get get_subwallet_id(): int {
    return contract.getData().beginParse().skipBits(32).preloadUint(32);
}

// same with wallet-v3 and wallet-v4
get get_public_key(): int {
    return contract.getData().beginParse().skipBits(64).preloadUint(256);
}

get get_vesting_data(): (int, int, int, int, int, address, address, dict) {
    loadData();

    return (vesting_start_time, vesting_total_duration, unlock_period, cliff_duration, vesting_total_amount,
            vesting_sender_address, owner_address, whitelist);
}

// same with wallet-v4
get is_whitelisted(address: address): bool {
    loadData();

    return isWhitelisted(address);
}

// same with wallet-v4
get get_whitelist(): tuple {
    loadData();

    var list: tuple? = null;

    var d: dict = whitelist;
    do {
        var (key: slice?, value: slice?, found: bool) = d.sDictDeleteFirstAndGet(ADDRESS_SIZE);
        if (found) {
            var (wc: int, addressHash: int) = unpackAddress(key!);
            list = listPrepend([wc, addressHash], list);
        }
    } while (found);

    return list!;
}

get get_locked_amount(atTime: int): int {
    loadData();

    return getLockedAmount(atTime);
}
