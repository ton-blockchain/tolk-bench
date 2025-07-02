import "@stdlib/gas-payments"
import "errors"
import "jetton-utils"
import "messages"
import "fees-management"
import "storage"

type AllowedMessageToWallet =
    AskToTransfer |
    AskToBurn |
    InternalTransferStep |
;

// todo inline or inline_ref?
@inline
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBouncedPrefix();
    var op: int = inMsgBody.loadUint(32);
    assert ((op == InternalTransferStep.getDeclaredPackPrefix()) | (op == BurnNotificationForMinter.getDeclaredPackPrefix())) throw ERR_INVALID_OP;
    var queryId: int = inMsgBody.loadUint(64);
    var jettonAmount: int = inMsgBody.loadCoins();
    var storage = lazy WalletStorage.load();
    storage.jettonBalance += jettonAmount;
    storage.save();
}

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

    val msg = lazy AllowedMessageToWallet.fromSlice(inMsgBody);

    match (msg) {
        InternalTransferStep => {
            var storage = lazy WalletStorage.load();
            if (senderAddress != storage.minterAddress) {
                assert (senderAddress.isAddressOfJettonWallet(msg.transferInitiator, storage.minterAddress, contract.getCode())) throw ERR_INVALID_WALLET;
            }
            storage.jettonBalance += msg.jettonAmount;
            storage.save();

            var tonBalanceBeforeMsg: int = myBalance - msgValue;
            var storageFee: int = MIN_TONS_FOR_STORAGE - min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE);
            msgValue -= (storageFee + JETTON_WALLET_GAS_CONSUMPTION);

            if (msg.forwardTonAmount) {
                msgValue -= (msg.forwardTonAmount + fwdFee);

                val notifyOwnerMsg = createMessage({
                    bounce: false,      // we should not bounce here cause receiver can have uninitialized contract
                    dest: storage.ownerAddress,
                    value: msg.forwardTonAmount,
                    body: TransferNotificationForRecipient {
                        queryId: msg.queryId,
                        jettonAmount: msg.jettonAmount,
                        transferInitiator: msg.transferInitiator,
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
            assert (msg.forwardPayload.remainingBitsCount()) throw ERR_INVALID_PAYLOAD;
            assert (msg.transferRecipient.getWorkchain() == BASECHAIN) throw ERR_WRONG_WORKCHAIN;

            var storage = lazy WalletStorage.load();
            assert (senderAddress == storage.ownerAddress) throw ERR_NOT_FROM_OWNER;
            assert (storage.jettonBalance >= msg.jettonAmount) throw ERR_NOT_ENOUGH_BALANCE;
            storage.jettonBalance -= msg.jettonAmount;
            storage.save();

            var forwardedMessagesCount = msg.forwardTonAmount ? 2 : 1;
            assert (msgValue >
                msg.forwardTonAmount +
                // 3 messages: wal1->wal2,  wal2->owner, wal2->response
                // but last one is optional (it is ok if it fails)
                forwardedMessagesCount * fwdFee +
                (2 * JETTON_WALLET_GAS_CONSUMPTION + MIN_TONS_FOR_STORAGE)
            ) throw ERR_NOT_ENOUGH_TON;

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
            deployMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        AskToBurn => {
            assert (msgValue > fwdFee + 2 * JETTON_WALLET_GAS_CONSUMPTION) throw ERR_NOT_ENOUGH_GAS;

            var storage = lazy WalletStorage.load();
            assert (senderAddress == storage.ownerAddress) throw ERR_NOT_FROM_OWNER;
            assert (storage.jettonBalance >= msg.jettonAmount) throw ERR_NOT_ENOUGH_BALANCE;
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
            notifyMinterMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
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
