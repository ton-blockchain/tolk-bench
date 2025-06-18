// Jetton Wallet Smart Contract

tolk 0.99

import "@stdlib/gas-payments"

import "op-codes.tolk"
import "workchain.tolk"
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


@inline_ref
fun sendJettons(inMsgBody: slice, senderAddress: address, msgValue: int, fwdFee: int) {
    // see transfer TL-B layout in jetton.tlb
    var queryId = inMsgBody.loadMessageQueryId();
    var jettonAmount = inMsgBody.loadCoins();
    var toOwnerAddress = inMsgBody.loadAddress();
    checkSameWorkchain(toOwnerAddress);
    var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
    // int outgoing_transfers_unlocked = ((status & 1) == 0);
    //throw_unless(error::contract_locked, outgoing_transfers_unlocked);
    assert(ownerAddress == senderAddress) throw ERROR_NOT_OWNER;

    balance -= jettonAmount;
    assert(balance >= 0) throw ERROR_BALANCE_ERROR;

    var stateInit = calculateJettonWalletStateInit(toOwnerAddress, jettonMasterAddress, contract.getCode());
    var toWalletAddress = calculateJettonWalletAddress(stateInit);
    var responseAddress = inMsgBody.loadAddress();
    inMsgBody.skipMaybeRef(); // custom_payload
    var forwardTonAmount: int = inMsgBody.loadCoins();
    checkEitherForwardPayload(inMsgBody);
    var eitherForwardPayload: slice = inMsgBody;

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
    var msg: cell = beginCell()
    .storeMsgFlagsAndAddressNone(0x18)
    .storeAddress(toWalletAddress)
    .storeCoins(0)
    .storeStatinitRefAndBodyRef(stateInit, msgBody)
    .endCell();

    checkAmountIsEnoughToTransfer(msgValue, forwardTonAmount, fwdFee);

    sendRawMessage(msg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    saveData(status, balance, ownerAddress, jettonMasterAddress);
}

@inline_ref
fun receiveJettons(inMsgBody: slice, senderAddress: address, myTonBalance: int, msgValue: int) {
    var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
    // int incoming_transfers_locked = ((status & 2) == 2);
    // throw_if(error::contract_locked, incoming_transfers_locked);
    // see internal TL-B layout in jetton.tlb
    var queryId: int = inMsgBody.loadMessageQueryId();
    var jettonAmount = inMsgBody.loadCoins();
    var fromAddress = inMsgBody.loadAddress();
    var responseAddress = inMsgBody.loadAddress();
    assert((jettonMasterAddress == senderAddress)
        |
        (calculateUserJettonWalletAddress(fromAddress, jettonMasterAddress, contract.getCode()) == senderAddress)) throw ERROR_NOT_VALID_WALLET;
    balance += jettonAmount;

    var forwardTonAmount: int = inMsgBody.loadCoins();

    if (forwardTonAmount) {
        var eitherForwardPayload: slice = inMsgBody;

        // see transfer_notification TL-B layout in jetton.tlb
        var msgBody: cell = beginCell()
        .storeMessageOp(OP_TRANSFER_NOTIFICATION)
        .storeMessageQueryId(queryId)
        .storeCoins(jettonAmount)
        .storeAddress(fromAddress)
        .storeSlice(eitherForwardPayload)
        .endCell();

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var msg: cell = beginCell()
        .storeMsgFlagsAndAddressNone(0x10)
        .storeAddress(ownerAddress)
        .storeCoins(forwardTonAmount)
        .storeOnlyBodyRef(msgBody)
        .endCell();

        sendRawMessage(msg, SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
    }

    if (responseAddress.isInternal()) {
        var toLeaveOnBalance: int = myTonBalance - msgValue + contract.getStorageDuePayment();
        reserveToncoinsOnBalance(max(toLeaveOnBalance, calculateJettonWalletMinStorageFee()), RESERVE_MODE_AT_MOST);

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var msg: cell = beginCell()
        .storeMsgFlagsAndAddressNone(0x10)
        .storeAddress(responseAddress)
        .storeCoins(0)
        .storePrefixOnlyBody()
        .storeMessageOp(OP_EXCESSES)
        .storeMessageQueryId(queryId)
        .endCell();
        sendRawMessage(msg, SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
    }

    saveData(status, balance, ownerAddress, jettonMasterAddress);
}

@inline_ref
fun burnJettons(inMsgBody: slice, senderAddress: address, msgValue: int) {
    var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
    var queryId = inMsgBody.loadMessageQueryId();
    var jettonAmount = inMsgBody.loadCoins();
    var responseAddress = inMsgBody.loadAddress();
    inMsgBody.skipMaybeRef(); // custom_payload
    inMsgBody.assertEnd();

    balance -= jettonAmount;
    assert(ownerAddress == senderAddress) throw ERROR_NOT_OWNER;
    assert(balance >= 0) throw ERROR_BALANCE_ERROR;

    // see burn_notification TL-B layout in jetton.tlb
    var msgBody: cell = beginCell()
    .storeMessageOp(OP_BURN_NOTIFICATION)
    .storeMessageQueryId(queryId)
    .storeCoins(jettonAmount)
    .storeAddress(ownerAddress)
    .storeAddress(responseAddress)
    .endCell();

    // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
    var msg: cell = beginCell()
    .storeMsgFlagsAndAddressNone(0x18)
    .storeAddress(jettonMasterAddress)
    .storeCoins(0)
    .storeOnlyBodyRef(msgBody)
    .endCell();

    checkAmountIsEnoughToBurn(msgValue);

    sendRawMessage(msg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    saveData(status, balance, ownerAddress, jettonMasterAddress);
}

@inline
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBouncedPrefix();
    var (status: int, balance: int, ownerAddress: address, jettonMasterAddress: address) = loadData();
    var op: int = inMsgBody.loadMessageOp();
    assert((op == OP_INTERNAL_TRANSFER) | (op == OP_BURN_NOTIFICATION)) throw ERROR_WRONG_OP;
    inMsgBody.skipMessageQueryId();
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
        sendJettons(inMsgBody, senderAddress, msgValue, fwdFee);
        return;
    }

    // incoming transfer
    if (op == OP_INTERNAL_TRANSFER) {
        receiveJettons(inMsgBody, senderAddress, myTonBalance, msgValue);
        return;
    }

    // burn
    if (op == OP_BURN) {
        burnJettons(inMsgBody, senderAddress, msgValue);
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
