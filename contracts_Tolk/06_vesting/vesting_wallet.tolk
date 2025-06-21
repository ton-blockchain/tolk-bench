tolk 0.99

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

type WhitelistDict = dict;

struct Storage {
    seqno: uint32;
    subwalletId: uint32;
    publicKey: uint256;
    whitelist: WhitelistDict;
    vestingParameters: Cell<VestingParameters>;
}

struct VestingParameters {
    startTime: uint64;
    totalDuration: uint32;     // > 0 and <= 135 years (2^32 seconds) ; mod unlockPeriod == 0
    unlockPeriod: uint32;      // > 0 and <= totalDuration
    cliffDuration: uint32;     // >= 0 and < totalDuration ; mod unlockPeriod == 0
    totalAmount: coins;
    senderAddress: address;
    ownerAddress: address;
}

fun Storage.load() {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

@inline_ref
fun matchAddressFromConfig(address: address, configId: int): bool {
    var (addressWc, addressHash) = address.getWorkchainAndHash();
    if (addressWc != MASTERCHAIN) {
        return false;
    }
    var configCell = blockchain.configParam(configId);
    if (configCell == null) {
        return false;
    }
    var configSlice = configCell.beginParse();
    if (configSlice.remainingBitsCount() < 256) {
        return false;
    }
    return addressHash == configSlice.preloadUint(256);
}


const ADDRESS_SIZE = 267; // '100' (std addr no anycast) + workchain 8 + hash 256

fun WhitelistDict.isWhitelisted(self, address: address): bool {
    var (_, found: bool) = self.sDictGet(ADDRESS_SIZE, address as slice);
    return found;
}

// todo inline?
@inline_ref
fun VestingParameters.getLockedAmount(self, nowTime: int): coins {
    if (nowTime > self.startTime + self.totalDuration) {
        return 0;
    }

    if (nowTime < self.startTime + self.cliffDuration) {
        return self.totalAmount;
    }

    return self.totalAmount -
        mulDivFloor(
            self.totalAmount,
            (nowTime - self.startTime) / self.unlockPeriod,
            self.totalDuration / self.unlockPeriod
        );
}

struct AttachedMessage {
    sendMode: uint8;
    msgCell: cell;
}

@inline
fun AttachedMessage.validateIfLockedAmount(self, whitelist: WhitelistDict, lockedAmount: coins, vestingSenderAddress: address) {
    assert(self.sendMode == SEND_MODE_IGNORE_ERRORS + SEND_MODE_PAY_FEES_SEPARATELY) throw ERROR_SEND_MODE_NOT_ALLOWED;

    var msgCs = self.msgCell.beginParse();
    var flags = msgCs.loadMessageFlags();
    var senderAddress = msgCs.loadAddress(); // skip
    var destinationAddress = msgCs.loadAddress();

    if (destinationAddress != vestingSenderAddress) {
        // can send to vesting_sender_address any message

        if (whitelist.isWhitelisted(destinationAddress)) {
            var isBounceable = (flags & 2) == 2;
            assert(isBounceable) throw ERROR_NON_BOUNCEABLE_NOT_ALLOWED;

            msgCs.loadCoins(); // skip value
            msgCs.skipBits(1); // skip extracurrency collection
            msgCs.loadCoins(); // skip ihr_fee
            msgCs.loadCoins(); // skip fwd_fee
            msgCs.loadUint(64); // skip createdLt
            msgCs.loadUint(32); // skip createdAt
            var maybeStateInit = msgCs.loadBool();
            assert(!maybeStateInit) throw ERROR_STATE_INIT_NOT_ALLOWED;

            var maybeBody = msgCs.loadBool();
            var body: slice = maybeBody ? msgCs.loadRef().beginParse() : msgCs;

            if (matchAddressFromConfig(destinationAddress, elector_id)) {
                // elector - direct validation

                var op = body.loadUint(32);
                assert(
                    (op == OP_ELECTOR_NEW_STAKE) |
                    (op == OP_ELECTOR_RECOVER_STAKE) |
                    (op == OP_VOTE_FOR_COMPLAINT) |
                    (op == OP_VOTE_FOR_PROPOSAL)
                ) throw ERROR_COMMENT_NOT_ALLOWED;

            } else if (matchAddressFromConfig(destinationAddress, config_id)) {
                // config - direct validation

                var op = body.loadUint(32);
                assert(op == OP_VOTE_FOR_PROPOSAL) throw ERROR_COMMENT_NOT_ALLOWED;

            } else if (body.remainingBitsCount()) {
                // empty message allowed for other destination (not elector)

                var op = body.loadUint(32);
                assert(
                    (op == 0) | // text comment
                    (op == OP_SINGLE_NOMINATOR_POOL_WITHDRAW) |
                    (op == OP_SINGLE_NOMINATOR_POOL_CHANGE_VALIDATOR) | // single-nominator
                    (op == OP_TON_STAKERS_DEPOSIT) |
                    (op == OP_JETTON_BURN) |
                    (op == OP_TON_STAKERS_VOTE) | // tonstakers.com
                    (op == OP_VOTE_FOR_PROPOSAL) |
                    (op == OP_VOTE_FOR_COMPLAINT)
                ) throw ERROR_COMMENT_NOT_ALLOWED;

                if ((op == 0) & (body.remainingBitsCount() > 0)) {
                    // empty text comment allowed
                    var action = body.loadUint(8);
                    assert((action == stringToBase256("d")) | (action == stringToBase256("w")) | // nominator-pool - https://github.com/ton-blockchain/nominator-pool
                           (action == stringToBase256("D")) | (action == stringToBase256("W"))
                    ) throw ERROR_SYMBOLS_NOT_ALLOWED;
                }
            }
        } else {
            reserveToncoinsOnBalance(lockedAmount, RESERVE_MODE_AT_MOST);
        }
    }
}

struct (0x7258a69b) AskToWhitelistAdd {
    queryId: uint64;
    addrToWhitelist: address;
    restRefs: RemainingBitsAndRefs;
}

struct (0xa7733acd) AskToSendMessage {
    queryId: uint64;
    attachedMsg: AttachedMessage;
}

type AllowedMessageForVestingWallet = AskToWhitelistAdd | AskToSendMessage;

fun onInternalMessage(myBalance: int, msgValue: int, msgCell: cell, msgBody: slice) {
    var cs: slice = msgCell.beginParse();
    var flags: int = cs.loadUint(4);
    if (flags & 1) { // ignore all bounced messages
        return;
    }
    var senderAddress = cs.loadAddress();

    var storage = Storage.load();
    val vesting = storage.vestingParameters.load();

    val msg = lazy AllowedMessageForVestingWallet.fromSlice(msgBody);

    match (msg) {
        AskToSendMessage => {
            assert(senderAddress == vesting.ownerAddress, 0);
            val attachedMsg = msg.attachedMsg;
            var lockedAmount = vesting.getLockedAmount(blockchain.now());
            if (lockedAmount > 0) {
                // if the vesting has expired, you can send any messages
                attachedMsg.validateIfLockedAmount(storage.whitelist, lockedAmount, vesting.senderAddress);
            }
            sendRawMessage(attachedMsg.msgCell, attachedMsg.sendMode);

            val excessesMsg = createMessage({
                bounce: true,
                dest: senderAddress,
                value: 0,
                body: (OP_SEND_RESPONSE as uint32, msg.queryId)
            });
            excessesMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        AskToWhitelistAdd => {
            assert(senderAddress == vesting.senderAddress, 0);
            var addrToWhitelist = msg.addrToWhitelist;
            var nextRef = msg.restRefs;
            do {
                storage.whitelist.sDictSetBuilder(ADDRESS_SIZE, addrToWhitelist as slice, beginCell());

                var moreRefs = nextRef.remainingRefsCount();
                if (moreRefs) {
                    nextRef = nextRef.loadRef().beginParse();
                    addrToWhitelist = nextRef.loadAddress();
                }
            } while (moreRefs);
            storage.save();

            val excessesMsg = createMessage({
                bounce: true,
                dest: senderAddress,
                value: 0,
                body: (OP_ADD_WHITELIST_RESPONSE as uint32, msg.queryId)
            });
            excessesMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        else => {
            // on unknown opcode, just accept coins from anyone, do not throw
        }
    }
}

struct ExternalMsgAfterSignature {
    subwalletId: uint32;
    validUntil: uint32;
    seqno: uint32;
    rest: RemainingBitsAndRefs;
}

fun onExternalMessage(extBody: slice) {
    var signature = extBody.loadBits(512);
    val hashOfAllAfter = extBody.hash();
    val msg = ExternalMsgAfterSignature.fromSlice(extBody);
    assert(msg.validUntil > blockchain.now()) throw ERROR_EXPIRED;

    var storage = lazy Storage.load();
    assert(msg.seqno == storage.seqno) throw ERROR_INVALID_SEQNO;
    assert(msg.subwalletId == storage.subwalletId) throw ERROR_INVALID_SUBWALLET_ID;
    assert(isSignatureValid(hashOfAllAfter, signature, storage.publicKey)) throw ERROR_INVALID_SIGNATURE;

    acceptExternalMessage();

    try {
        val attachedMsg = AttachedMessage.fromSlice(msg.rest);
        val vesting = storage.vestingParameters.load();
        var lockedAmount = vesting.getLockedAmount(blockchain.now());
        if (lockedAmount > 0) {
            // if not (the vesting has expired), you can send any messages
            attachedMsg.validateIfLockedAmount(storage.whitelist, lockedAmount, vesting.senderAddress);
        }
        sendRawMessage(attachedMsg.msgCell, attachedMsg.sendMode);
    } catch {
    }

    storage.seqno += 1;
    storage.save();
}

// GET methods

get seqno(): int {
    val storage = lazy Storage.load();
    return storage.seqno;
}

get get_subwallet_id(): int {
    val storage = lazy Storage.load();
    return storage.subwalletId;
}

get get_public_key(): int {
    val storage = lazy Storage.load();
    return storage.publicKey;
}

get get_vesting_data(): (VestingParameters, dict) {
    val storage = lazy Storage.load();
    val v = storage.vestingParameters.load();

    return (v, storage.whitelist);
}

get is_whitelisted(address: address): bool {
    val storage = lazy Storage.load();
    return storage.whitelist.isWhitelisted(address);
}

get get_whitelist(): tuple {
    val storage = lazy Storage.load();

    var list: tuple? = null;

    var d: dict = storage.whitelist;
    do {
        var (key: slice?, value: slice?, found: bool) = d.sDictDeleteFirstAndGet(ADDRESS_SIZE);
        if (found) {
            var (wc, addressHash) = (key! as address).getWorkchainAndHash();
            list = listPrepend([wc, addressHash], list);
        }
    } while (found);

    return list!;
}

get get_locked_amount(atTime: int): int {
    val storage = lazy Storage.load();
    return storage.vestingParameters.load().getLockedAmount(atTime);
}
