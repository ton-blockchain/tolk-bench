// Jetton Wallet Smart Contract

tolk 0.99

import "@stdlib/gas-payments"
import "op-codes.tolk"
import "jetton-utils.tolk"
import "messages.tolk"

const MIN_TONS_FOR_STORAGE = ton("0.01");
// Note that 2 * gas_consumptions is expected to be able to cover fees on both wallets (sender and receiver)
// and also constant fees on inter-wallet interaction, in particular fwd fee on state_init transfer
// that means that you need to reconsider this fee when:
// a) jetton logic become more gas-heavy
// b) jetton-wallet code (sent with inter-wallet message) become larger or smaller
// c) global fee changes / different workchain
const EXPECTED_GAS_UPPER_BOUND = ton("0.015");

fun WalletStorage.load() {
    return WalletStorage.fromCell(contract.getData())
}

fun WalletStorage.save(self) {
    contract.setData(self.toCell())
}

// todo inline or inline_ref?
@inline
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBouncedPrefix();
    var op: int = inMsgBody.loadUint(32);
    assert((op == OP_INTERNAL_TRANSFER) | (op == OP_BURN_NOTIFICATION)) throw 709;
    var queryId: int = inMsgBody.loadUint(64);
    var jettonAmount: int = inMsgBody.loadCoins();
    var storage = lazy WalletStorage.load();
    storage.balance += jettonAmount;
    storage.save();
}

type AllowedWalletMessage =
    AskToTransfer |
    AskToBurn |
    InternalTransfer |
;

fun onInternalMessage(myBalance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    if (inMsgBody.isEnd()) {
        // ignore empty messages
        return;
    }

    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);
    if (flags & 1) {
        onBounce(inMsgBody);
        return;
    }
    var senderAddress = cs.loadAddress();
    cs.loadAddress(); // skip dst
    cs.loadCoins(); // skip value
    cs.skipBits(1); // skip extracurrency collection
    cs.loadCoins(); // skip ihr_fee
    val incomingFwdFee = cs.loadCoins();
    var fwdFee = calculateOriginalMessageFee(BASECHAIN, incomingFwdFee);

    // todo load storage once or in every branch?

    val msg = lazy AllowedWalletMessage.fromSlice(inMsgBody);

    match (msg) {
        InternalTransfer => {
            var storage = lazy WalletStorage.load();
            if (senderAddress != storage.minterAddress) {
                assert(senderAddress.isAddressOfJettonWallet(msg.ownerAddress, storage.minterAddress, contract.getCode())) throw 707;
            }
            storage.balance += msg.jettonAmount;
            storage.save();

            var tonBalanceBeforeMsg: int = myBalance - msgValue;
            var storageFee: int = MIN_TONS_FOR_STORAGE - min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE);
            msgValue -= (storageFee + EXPECTED_GAS_UPPER_BOUND);

            if (msg.forwardTonAmount) {
                msgValue -= (msg.forwardTonAmount + fwdFee);

                val notifyOwnerMsg = createMessage({
                    bounce: false,      // we should not bounce here cause receiver can have uninitialized contract
                    dest: storage.ownerAddress,
                    value: msg.forwardTonAmount,
                    body: TransferNotificationForOwner {
                        queryId: msg.queryId,
                        jettonAmount: msg.jettonAmount,
                        fromAddress: msg.ownerAddress,
                        forwardPayload: msg.forwardPayload
                    }
                });
                notifyOwnerMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            if (msg.sendExcessesTo.isInternal() & (msgValue > 0)) {
                val excessesMsg = createMessage({
                    bounce: false,
                    dest: msg.sendExcessesTo,
                    value: msgValue,
                    body: ReturnExcessesBack {
                        queryId: msg.queryId
                    }
                });
                excessesMsg.send(SEND_MODE_IGNORE_ERRORS);
            }
        }

        AskToTransfer => {
            assert(msg.forwardPayload.remainingBitsCount()) throw 708;
            assert(msg.toOwnerAddress.getWorkchain() == BASECHAIN) throw 333;

            var storage = lazy WalletStorage.load();
            assert(senderAddress == storage.ownerAddress) throw 705;
            assert(storage.balance >= msg.jettonAmount) throw 706;
            storage.balance -= msg.jettonAmount;
            storage.save();

            var forwardedMessagesCount = msg.forwardTonAmount ? 2 : 1;
            assert(msgValue >
                msg.forwardTonAmount +
                // 3 messages: wal1->wal2,  wal2->owner, wal2->response
                // but last one is optional (it is ok if it fails)
                forwardedMessagesCount * fwdFee +
                (2 * EXPECTED_GAS_UPPER_BOUND + MIN_TONS_FOR_STORAGE)
            ) throw 709;

            val deployMsg = createMessage({
                bounce: true,
                dest: {
                    stateInit: {
                        code: contract.getCode(),   // we're deploying the same wallet as current
                        data: WalletStorage.generateEmptyData(msg.toOwnerAddress, storage.minterAddress),
                    }
                },
                value: 0,
                body: InternalTransfer {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    ownerAddress: storage.ownerAddress,
                    sendExcessesTo: msg.sendExcessesTo,
                    forwardTonAmount: msg.forwardTonAmount,
                    forwardPayload: msg.forwardPayload,
                }
            });
            deployMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        AskToBurn => {
            assert(msgValue > fwdFee + 2 * EXPECTED_GAS_UPPER_BOUND) throw 707;

            var storage = lazy WalletStorage.load();
            assert(senderAddress == storage.ownerAddress) throw 705;
            assert(storage.balance >= msg.jettonAmount) throw 706;
            storage.balance -= msg.jettonAmount;
            storage.save();

            val nofityMinterMsg = createMessage({
                bounce: true,
                dest: storage.minterAddress,
                value: 0,
                body: BurnNotificationForMinter {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    fromOwnerAddress: storage.ownerAddress,
                    sendExcessesTo: msg.sendExcessesTo,
                }
            });
            nofityMinterMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        else => throw 0xFFFF
    }
}

get get_wallet_data(): (coins, address, address, cell) {
    val storage = lazy WalletStorage.load();
    return (storage.balance, storage.ownerAddress, storage.minterAddress, contract.getCode())
}
