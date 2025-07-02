import "@stdlib/gas-payments"
import "errors"
import "sharding"
import "jetton-utils"
import "fees-management"
import "storage"
import "messages"

type AllowedMessageToWallet =
    AskToTransfer |
    AskToBurn |
    InternalTransferStep |
    TopUpTons |
;

@inline
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBouncedPrefix();
    var op: int = inMsgBody.loadMessageOp();
    assert ((op == InternalTransferStep.getDeclaredPackPrefix()) | (op == BurnNotificationForMinter.getDeclaredPackPrefix())) throw ERROR_WRONG_OP;
    inMsgBody.skipMessageQueryId();
    var jettonAmount: int = inMsgBody.loadCoins();
    var storage = lazy WalletStorage.load();
    storage.jettonBalance += jettonAmount;
    storage.save();
}

fun onInternalMessage(myTonBalance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var inMsgFullSlice: slice = inMsgFull.beginParse();
    var msgFlags: int = inMsgFullSlice.loadMessageFlags();
    if (msgFlags & 1) { // is bounced
        onBounce(inMsgBody);
        return;
    }
    var senderAddress = inMsgFullSlice.loadAddress();
    var fwdFeeFromInMsg: int = inMsgFullSlice.retrieveFwdFee();
    var fwdFee = calculateOriginalMessageFee(MY_WORKCHAIN, fwdFeeFromInMsg); // we use message fwd_fee for estimation of forward_payload costs

    val msg = lazy AllowedMessageToWallet.fromSlice(inMsgBody);

    // todo load storage once or lazily in each branch?

    match (msg) {
        InternalTransferStep => {
            var storage = lazy WalletStorage.load();
            if (senderAddress != storage.minterAddress) {
                assert (senderAddress.isAddressOfJettonWallet(msg.transferInitiator, storage.minterAddress, contract.getCode())) throw ERROR_NOT_VALID_WALLET;
            }
            storage.jettonBalance += msg.jettonAmount;
            storage.save();

            if (msg.forwardTonAmount) {
                val notifyOwnerMsg = createMessage({
                    bounce: false,
                    dest: storage.ownerAddress,
                    value: msg.forwardTonAmount,
                    body: TransferNotificationForRecipient {
                        queryId: msg.queryId,
                        jettonAmount: msg.jettonAmount,
                        transferInitiator: msg.transferInitiator,
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
            assert (msg.transferRecipient.getWorkchain() == MY_WORKCHAIN) throw ERROR_WRONG_WORKCHAIN;
            checkAmountIsEnoughToTransfer(msgValue, msg.forwardTonAmount, fwdFee);

            var storage = lazy WalletStorage.load();
            assert (senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            assert (storage.jettonBalance >= msg.jettonAmount) throw ERROR_BALANCE_ERROR;
            storage.jettonBalance -= msg.jettonAmount;
            storage.save();

            val deployMsg = createMessage({
                bounce: true,
                dest: calcDeployedJettonWallet(msg.transferRecipient, storage.minterAddress, contract.getCode()),
                value: 0,
                body: InternalTransferStep {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    transferInitiator: storage.ownerAddress,
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
            assert (senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            assert (storage.jettonBalance >= msg.jettonAmount) throw ERROR_BALANCE_ERROR;
            storage.jettonBalance -= msg.jettonAmount;
            storage.save();

            val notifyMinterMsg = createMessage({
                bounce: true,
                dest: storage.minterAddress,
                value: 0,
                body: BurnNotificationForMinter {
                    queryId: msg.queryId,
                    jettonAmount: msg.jettonAmount,
                    burnInitiator: storage.ownerAddress,
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



struct JettonWalletDataReply {
    jettonBalance: coins;
    ownerAddress: address;
    minterAddress: address;
    jettonWalletCode: cell;
}

get get_wallet_data(): JettonWalletDataReply {
    val storage = lazy WalletStorage.load();

    return {
        jettonBalance: storage.jettonBalance,
        ownerAddress: storage.ownerAddress,
        minterAddress: storage.minterAddress,
        jettonWalletCode: contract.getCode(),
    }
}
