// Jetton Wallet Smart Contract

tolk 0.99

import "@stdlib/gas-payments"

import "op-codes.tolk"
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
    assert((op == OP_INTERNAL_TRANSFER) | (op == OP_BURN_NOTIFICATION)) throw ERROR_WRONG_OP;
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
        AskToTransfer => {
            checkEitherForwardPayload(msg.forwardPayload);
            assert(msg.toOwnerAddress.getWorkchain() == MY_WORKCHAIN) throw ERROR_WRONG_WORKCHAIN;
            checkAmountIsEnoughToTransfer(msgValue, msg.forwardTonAmount, fwdFee);

            var storage = lazy WalletStorage.load();
            assert(senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            assert(storage.balance >= msg.jettonAmount) throw ERROR_BALANCE_ERROR;
            storage.balance -= msg.jettonAmount;
            storage.save();

            var stateInit = calculateJettonWalletStateInit(msg.toOwnerAddress, storage.minterAddress, contract.getCode());
            var toWalletAddress = calculateJettonWalletAddress(stateInit);

            // see internal TL-B layout in jetton.tlb
            var msgBody: cell = beginCell()
                .storeMessageOp(OP_INTERNAL_TRANSFER)
                .storeMessageQueryId(msg.queryId)
                .storeCoins(msg.jettonAmount)
                .storeAddress(storage.ownerAddress)
                .storeAddress(msg.sendExcessesTo)
                .storeCoins(msg.forwardTonAmount)
                .storeSlice(msg.forwardPayload)
                .endCell();

            // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
            var deployMsg: cell = beginCell()
                .storeMsgFlagsAndAddressNone(0x18)
                .storeAddress(toWalletAddress)
                .storeCoins(0)
                .storeStatinitRefAndBodyRef(stateInit, msgBody)
                .endCell();

            sendRawMessage(deployMsg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        InternalTransfer => {
            var storage = lazy WalletStorage.load();
            if (senderAddress != storage.minterAddress) {
                assert (senderAddress == calculateUserJettonWalletAddress(msg.ownerAddress, storage.minterAddress, contract.getCode())) throw ERROR_NOT_VALID_WALLET;
            }
            storage.balance += msg.jettonAmount;
            storage.save();

            if (msg.forwardTonAmount) {
                // see transfer_notification TL-B layout in jetton.tlb
                var msgBody: cell = beginCell()
                    .storeMessageOp(OP_TRANSFER_NOTIFICATION)
                    .storeMessageQueryId(msg.queryId)
                    .storeCoins(msg.jettonAmount)
                    .storeAddress(msg.ownerAddress)
                    .storeSlice(msg.forwardPayload)
                    .endCell();

                // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
                var notifyOwnerMsg: cell = beginCell()
                    .storeMsgFlagsAndAddressNone(0x10)
                    .storeAddress(storage.ownerAddress)
                    .storeCoins(msg.forwardTonAmount)
                    .storeOnlyBodyRef(msgBody)
                    .endCell();

                sendRawMessage(notifyOwnerMsg, SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
            }

            if (msg.sendExcessesTo.isInternal()) {
                var toLeaveOnBalance: int = myTonBalance - msgValue + contract.getStorageDuePayment();
                reserveToncoinsOnBalance(max(toLeaveOnBalance, calculateJettonWalletMinStorageFee()), RESERVE_MODE_AT_MOST);

                // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
                var excessesMsg = beginCell()
                    .storeMsgFlagsAndAddressNone(0x10)
                    .storeAddress(msg.sendExcessesTo)
                    .storeCoins(0)
                    .storePrefixOnlyBody()
                    .storeMessageOp(OP_EXCESSES)
                    .storeMessageQueryId(msg.queryId)
                    .endCell();
                sendRawMessage(excessesMsg, SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
            }
        }

        AskToBurn => {
            checkAmountIsEnoughToBurn(msgValue);

            var storage = lazy WalletStorage.load();
            assert(senderAddress == storage.ownerAddress) throw ERROR_NOT_OWNER;
            assert(storage.balance >= msg.jettonAmount) throw ERROR_BALANCE_ERROR;
            storage.balance -= msg.jettonAmount;
            storage.save();

            // see burn_notification TL-B layout in jetton.tlb
            var msgBody: cell = beginCell()
                .storeMessageOp(OP_BURN_NOTIFICATION)
                .storeMessageQueryId(msg.queryId)
                .storeCoins(msg.jettonAmount)
                .storeAddress(storage.ownerAddress)
                .storeAddress(msg.sendExcessesTo)
                .endCell();

            // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
            var notifyMinterMsg = beginCell()
                .storeMsgFlagsAndAddressNone(0x18)
                .storeAddress(storage.minterAddress)
                .storeCoins(0)
                .storeOnlyBodyRef(msgBody)
                .endCell();

            sendRawMessage(notifyMinterMsg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
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
