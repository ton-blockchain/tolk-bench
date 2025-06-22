tolk 0.99

import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments"
import "@stdlib/lisp-lists"
import "storage.tolk"
import "message-validation.tolk"
import "errors.tolk"
import "messages.tolk"


fun Storage.load() {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
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

type AllowedMessageForVestingWallet = RequestAddToWhitelist | AskToSendMessage;

fun onInternalMessage(myBalance: int, msgValue: int, msgCell: cell, msgBody: slice) {
    var cs: slice = msgCell.beginParse();
    var flags: int = cs.loadUint(4);
    if (flags & 1) { // ignore all bounced messages
        return;
    }
    var senderAddress = cs.loadAddress();

    // todo load storage once or lazily in every branch?
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
                body: SendExcesses {
                    queryId: msg.queryId
                }
            });
            excessesMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        RequestAddToWhitelist => {
            assert(senderAddress == vesting.senderAddress, 0);
            var addrToWhitelist = msg.addrToWhitelist;
            var nextRef = msg.restRefs;
            do {
                storage.whitelist.addWhitelisted(addrToWhitelist);

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
                body: ResponseAddedToWhitelist {
                    queryId: msg.queryId
                }
            });
            excessesMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        else => {
            // on unknown opcode, just accept coins from anyone, do not throw
        }
    }
}

fun onExternalMessage(extBody: slice) {
    // extBody is: signature + signed data
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
            // if the vesting is in progress, validate a message before sending it
            attachedMsg.validateIfLockedAmount(storage.whitelist, lockedAmount, vesting.senderAddress);
        } else {
            // if not (the vesting has expired), you can send any messages
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
