// Jetton Wallet Smart Contract

tolk 0.99

import "@stdlib/gas-payments"

import "op-codes.tolk"
import "jetton-utils.tolk"
import "gas.tolk"

/*
  Storage

  storage#_ status:uint4
            balance:Coins owner_address:MsgAddressInt
            jetton_master_address:MsgAddressInt = Storage;
*/

@inline
fun loadData(): (int, int, address, address) {
    var ds: slice = contract.getData().beginParse();
    var data = (
        ds.loadUint(STATUS_SIZE), // status
        ds.loadCoins(), // balance
        ds.loadAddress(), // owner_address
        ds.loadAddress() // jetton_master_address
    );
    ds.assertEnd();
    return data;
}

@inline
fun saveData(status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) {
    var dataBuilder: builder = packJettonWalletDataBuilder(status, balance, ownerAddress, jettonMasterAddress);
    contract.setData(dataBuilder.endCell());
}

@inline
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBouncedPrefix();
    var op: int = inMsgBody.loadMessageOp();
    assert((op == OP_INTERNAL_TRANSFER) | (op == OP_BURN_NOTIFICATION)) throw ERROR_WRONG_OP;
    inMsgBody.skipMessageQueryId();
    var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
    var jettonAmount: int = inMsgBody.loadCoins();
    saveData(status, balance + jettonAmount, ownerAddress, jettonMasterAddress);
}

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

    var op: int = inMsgBody.loadMessageOp();

    // outgoing transfer
    if (op == OP_TRANSFER) {
        // see transfer TL-B layout in jetton.tlb
        var queryId = inMsgBody.loadMessageQueryId();
        var jettonAmount = inMsgBody.loadCoins();
        var toOwnerAddress = inMsgBody.loadAddress();
        var responseAddress = inMsgBody.loadAddress();
        inMsgBody.skipMaybeRef(); // custom_payload
        var forwardTonAmount: int = inMsgBody.loadCoins();
        var eitherForwardPayload: slice = inMsgBody;
        checkEitherForwardPayload(eitherForwardPayload);

        assert(toOwnerAddress.getWorkchain() == MY_WORKCHAIN) throw ERROR_WRONG_WORKCHAIN;
        var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
        assert(senderAddress == ownerAddress) throw ERROR_NOT_OWNER;
        assert(balance >= jettonAmount) throw ERROR_BALANCE_ERROR;
        balance -= jettonAmount;
        saveData(status, balance, ownerAddress, jettonMasterAddress);

        var stateInit = calculateJettonWalletStateInit(toOwnerAddress, jettonMasterAddress, contract.getCode());
        var toWalletAddress = calculateJettonWalletAddress(stateInit);

        // see internal TL-B layout in jetton.tlb
        var msgBody: cell = beginCell()
            .storeMessageOp(OP_INTERNAL_TRANSFER)
            .storeMessageQueryId(queryId)
            .storeCoins(jettonAmount)
            .storeAddress(ownerAddress)
            .storeAddress(responseAddress)
            .storeCoins(forwardTonAmount)
            .storeSlice(eitherForwardPayload)
            .endCell();

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var deployMsg: cell = beginCell()
            .storeMsgFlagsAndAddressNone(0x18)
            .storeAddress(toWalletAddress)
            .storeCoins(0)
            .storeStatinitRefAndBodyRef(stateInit, msgBody)
            .endCell();

        checkAmountIsEnoughToTransfer(msgValue, forwardTonAmount, fwdFee);  // todo move upper

        sendRawMessage(deployMsg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        return;
    }

    // incoming transfer
    if (op == OP_INTERNAL_TRANSFER) {
        // int incoming_transfers_locked = ((status & 2) == 2);
        // throw_if(error::contract_locked, incoming_transfers_locked);
        // see internal TL-B layout in jetton.tlb
        var queryId: int = inMsgBody.loadMessageQueryId();
        var jettonAmount = inMsgBody.loadCoins();
        var fromAddress = inMsgBody.loadAddress();
        var responseAddress = inMsgBody.loadAddress();
        var forwardTonAmount: int = inMsgBody.loadCoins();
        var eitherForwardPayload: slice = inMsgBody;

        var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
        assert((senderAddress == jettonMasterAddress)
            |
            (senderAddress == calculateUserJettonWalletAddress(fromAddress, jettonMasterAddress, contract.getCode()))) throw ERROR_NOT_VALID_WALLET;
        balance += jettonAmount;
        saveData(status, balance, ownerAddress, jettonMasterAddress);

        if (forwardTonAmount) {

            // see transfer_notification TL-B layout in jetton.tlb
            var msgBody: cell = beginCell()
                .storeMessageOp(OP_TRANSFER_NOTIFICATION)
                .storeMessageQueryId(queryId)
                .storeCoins(jettonAmount)
                .storeAddress(fromAddress)
                .storeSlice(eitherForwardPayload)
                .endCell();

            // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
            var notifyOwnerMsg: cell = beginCell()
                .storeMsgFlagsAndAddressNone(0x10)
                .storeAddress(ownerAddress)
                .storeCoins(forwardTonAmount)
                .storeOnlyBodyRef(msgBody)
                .endCell();

            sendRawMessage(notifyOwnerMsg, SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        if (responseAddress.isInternal()) {
            var toLeaveOnBalance: int = myTonBalance - msgValue + contract.getStorageDuePayment();
            reserveToncoinsOnBalance(max(toLeaveOnBalance, calculateJettonWalletMinStorageFee()), RESERVE_MODE_AT_MOST);

            // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
            var excessesMsg = beginCell()
                .storeMsgFlagsAndAddressNone(0x10)
                .storeAddress(responseAddress)
                .storeCoins(0)
                .storePrefixOnlyBody()
                .storeMessageOp(OP_EXCESSES)
                .storeMessageQueryId(queryId)
                .endCell();
            sendRawMessage(excessesMsg, SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }

        return;
    }

    // burn
    if (op == OP_BURN) {
        var queryId = inMsgBody.loadMessageQueryId();
        var jettonAmount = inMsgBody.loadCoins();
        var responseAddress = inMsgBody.loadAddress();
        inMsgBody.skipMaybeRef(); // custom_payload
        inMsgBody.assertEnd();

        var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
        assert(senderAddress == ownerAddress) throw ERROR_NOT_OWNER;
        assert(balance >= jettonAmount) throw ERROR_BALANCE_ERROR;
        balance -= jettonAmount;
        saveData(status, balance, ownerAddress, jettonMasterAddress);

        // see burn_notification TL-B layout in jetton.tlb
        var msgBody: cell = beginCell()
            .storeMessageOp(OP_BURN_NOTIFICATION)
            .storeMessageQueryId(queryId)
            .storeCoins(jettonAmount)
            .storeAddress(ownerAddress)
            .storeAddress(responseAddress)
            .endCell();

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var notifyMinterMsg = beginCell()
            .storeMsgFlagsAndAddressNone(0x18)
            .storeAddress(jettonMasterAddress)
            .storeCoins(0)
            .storeOnlyBodyRef(msgBody)
            .endCell();

        checkAmountIsEnoughToBurn(msgValue);        // todo move upper

        sendRawMessage(notifyMinterMsg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        return;
    }

    if (op == OP_TOP_UP) {
        return; // just accept tons
    }

    throw ERROR_WRONG_OP;
}

get get_wallet_data(): (int, address, address, cell) {
    var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
    return (balance, ownerAddress, jettonMasterAddress, contract.getCode());
}

get get_status(): int {
    var (status: int, _, _, _) = loadData();
    return status;
}
