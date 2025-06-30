// Jetton Wallet Smart Contract

tolk 0.99

import "@stdlib/gas-payments"

import "errors"
import "jetton-utils.tolk"
import "gas.tolk"
import "messages.tolk"

fun WalletStorage.load() {
    return WalletStorage.fromCell(contract.getData())
}

fun WalletStorage.save(self) {
    contract.setData(self.toCell())
}

@inline
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBouncedPrefix();
    var op: int = inMsgBody.loadMessageOp();
    assert((op == InternalTransfer.getDeclaredPackPrefix()) | (op == BurnNotificationForMinter.getDeclaredPackPrefix())) throw ERROR_WRONG_OP;
    inMsgBody.skipMessageQueryId();
    var jettonAmount: int = inMsgBody.loadCoins();
    var storage = lazy WalletStorage.load();
    storage.balance += jettonAmount;
    storage.save();
}

type AllowedWalletMessage =
    AskToTransfer |
    AskToBurn |
    InternalTransfer |
    TopUpTons |
;

fun onInternalMessage(myTonBalance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var inMsgFullSlice: slice = inMsgFull.beginParse();
    var msgFlags: int = inMsgFullSlice.loadMessageFlags();
    if (msgFlags & 1) {
        onBounce(inMsgBody);
        return;
    }
    var senderAddress = inMsgFullSlice.loadAddress();
    var fwdFeeFromInMsg = inMsgFullSlice.retrieveFwdFee();
    var fwdFee: int = calculateOriginalMessageFee(MY_WORKCHAIN, fwdFeeFromInMsg); // we use message fwd_fee for estimation of forward_payload costs

    val msg = lazy AllowedWalletMessage.fromSlice(inMsgBody);

    // todo load storage once or lazily in each branch?

    match (msg) {
        InternalTransfer => {
            var storage = lazy WalletStorage.load();
            if (senderAddress != storage.minterAddress) {
                assert(senderAddress.isAddressOfJettonWallet(msg.ownerAddress, storage.minterAddress, contract.getCode())) throw ERROR_NOT_VALID_WALLET;
            }
            storage.balance += msg.jettonAmount;
            storage.save();

            if (msg.forwardTonAmount) {
                val notifyOwnerMsg = createMessage({
                    bounce: false,
                    dest: storage.ownerAddress,
                    value: msg.forwardTonAmount,
                    body: TransferNotificationForOwner {
                        queryId: msg.queryId,
                        jettonAmount: msg.jettonAmount,
                        fromAddress: msg.ownerAddress,
                        forwardPayload: msg.forwardPayload,
                    }
                });
                notifyOwnerMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            }

            if (msg.sendExcessesTo.isInternal()) {
                var toLeaveOnBalance = myTonBalance - msgValue + contract.getStorageDuePayment();
                reserveToncoinsOnBalance(max(toLeaveOnBalance, calculateJettonWalletMinStorageFee()), RESERVE_MODE_AT_MOST);

                val excessesMsg = createMessage({
                    bounce: false,
                    dest: msg.sendExcessesTo,
                    value: 0,
                    body: ReturnExcessesBack {
                        queryId: msg.queryId
                    }
                });
                excessesMsg.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
            }
        }

        AskToTransfer => {
            msg.forwardPayload.checkIsCorrectTLBEither();
            assert(msg.toOwnerAddress.getWorkchain() == MY_WORKCHAIN) throw ERROR_WRONG_WORKCHAIN;
            checkAmountIsEnoughToTransfer(msgValue, msg.forwardTonAmount, fwdFee);

            var storage = lazy WalletStorage.load();
            assert(senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            assert(storage.balance >= msg.jettonAmount) throw ERROR_BALANCE_ERROR;
            storage.balance -= msg.jettonAmount;
            storage.save();

            val deployMsg = createMessage({
                bounce: true,
                dest: calcDeployedJettonWallet(msg.toOwnerAddress, storage.minterAddress, contract.getCode()),
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
            deployMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        AskToBurn => {
            checkAmountIsEnoughToBurn(msgValue);

            var storage = lazy WalletStorage.load();
            assert(senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            assert(storage.balance >= msg.jettonAmount) throw ERROR_BALANCE_ERROR;
            storage.balance -= msg.jettonAmount;
            storage.save();

            val notifyMinterMsg = createMessage({
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
            notifyMinterMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        TopUpTons => {
            // just accept tons
        }

        else => throw 0xFFFF
    }
}

get get_wallet_data(): (int, address, address, cell) {
    var storage = lazy WalletStorage.load();
    return (storage.balance, storage.ownerAddress, storage.minterAddress, contract.getCode());
}

get get_status(): int {
    var storage = lazy WalletStorage.load();
    return storage.status;
}
