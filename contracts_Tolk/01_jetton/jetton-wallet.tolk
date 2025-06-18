// Jetton Wallet Smart Contract

tolk 0.99

import "@stdlib/gas-payments.tolk"
import "op-codes.tolk"
import "jetton-utils.tolk"

const MIN_TONS_FOR_STORAGE = ton("0.01");
// Note that 2 * gas_consumptions is expected to be able to cover fees on both wallets (sender and receiver)
// and also constant fees on inter-wallet interaction, in particular fwd fee on state_init transfer
// that means that you need to reconsider this fee when:
// a) jetton logic become more gas-heavy
// b) jetton-wallet code (sent with inter-wallet message) become larger or smaller
// c) global fee changes / different workchain
const EXPECTED_GAS_UPPER_BOUND = ton("0.015");

/*
  Storage
  storage#_ balance:Coins owner_address:MsgAddressInt jetton_master_address:MsgAddressInt jetton_wallet_code:^Cell = Storage;
*/

@inline
fun loadData(): (int, address, address, cell) {
    var ds: slice = contract.getData().beginParse();
    return (ds.loadCoins(), ds.loadAddress(), ds.loadAddress(), ds.loadRef());
}

@inline
fun saveData(balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) {
    contract.setData(packJettonWalletData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode));
}

/*
  transfer query_id:uint64 amount:(VarUInteger 16) destination:MsgAddress
           response_destination:MsgAddress custom_payload:(Maybe ^Cell)
           forward_ton_amount:(VarUInteger 16) forward_payload:(Either Cell ^Cell)
           = InternalMsgBody;
  internal_transfer  query_id:uint64 amount:(VarUInteger 16) from:MsgAddress
                     response_address:MsgAddress
                     forward_ton_amount:(VarUInteger 16)
                     forward_payload:(Either Cell ^Cell) 
                     = InternalMsgBody;
*/


// todo inline or inline_ref?
@inline
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBits(32); // 0xFFFFFFFF
    var (balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) = loadData();
    var op: int = inMsgBody.loadUint(32);
    assert((op == OP_INTERNAL_TRANSFER) | (op == OP_BURN_NOTIFICATION)) throw 709;
    var queryId: int = inMsgBody.loadUint(64);
    var jettonAmount: int = inMsgBody.loadCoins();
    balance += jettonAmount;
    saveData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode);
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

    var op: int = inMsgBody.loadUint(32);

    if (op == OP_TRANSFER) {
        var queryId = inMsgBody.loadUint(64);
        var jettonAmount = inMsgBody.loadCoins();
        var toOwnerAddress = inMsgBody.loadAddress();
        var responseAddress = inMsgBody.loadAddress();
        var customPayload = inMsgBody.loadDict();
        var forwardTonAmount = inMsgBody.loadCoins();
        var eitherForwardPayload = inMsgBody;

        assert(eitherForwardPayload.remainingBitsCount()) throw 708;
        assert(toOwnerAddress.getWorkchain() == BASECHAIN) throw 333;

        var (balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) = loadData();
        assert(senderAddress == ownerAddress) throw 705;
        assert(balance >= jettonAmount) throw 706;
        balance -= jettonAmount;
        saveData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode);

        var forwardedMessagesCount = forwardTonAmount ? 2 : 1;
        assert(msgValue >
            forwardTonAmount +
            // 3 messages: wal1->wal2,  wal2->owner, wal2->response
            // but last one is optional (it is ok if it fails)
            forwardedMessagesCount * fwdFee +
            (2 * EXPECTED_GAS_UPPER_BOUND + MIN_TONS_FOR_STORAGE)
        ) throw 709;

        var msgBody = beginCell()
            .storeUint(OP_INTERNAL_TRANSFER, 32)
            .storeUint(queryId, 64)
            .storeCoins(jettonAmount)
            .storeAddress(ownerAddress)
            .storeAddress(responseAddress)
            .storeCoins(forwardTonAmount)
            .storeSlice(eitherForwardPayload)
            .endCell();

        var stateInit: cell = calculateJettonWalletStateInit(toOwnerAddress, jettonMasterAddress, jettonWalletCode);
        var toWalletAddress = calculateJettonWalletAddress(stateInit);
        var msg = beginCell()
            .storeUint(0x18, 6)
            .storeAddress(toWalletAddress)
            .storeCoins(0)
            .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
            .storeRef(stateInit)
            .storeRef(msgBody)
            .endCell();

        sendRawMessage(msg, 64); // revert on errors
        return;
    }

    if (op == OP_INTERNAL_TRANSFER) {
        // NOTE we can not allow fails in action phase since in that case there will be
        // no bounce. Thus check and throw in computation phase.
        var queryId = inMsgBody.loadUint(64);
        var jettonAmount = inMsgBody.loadCoins();
        var fromAddress = inMsgBody.loadAddress();
        var responseAddress = inMsgBody.loadAddress();
        var forwardTonAmount = inMsgBody.loadCoins();
        var eitherForwardPayload = inMsgBody;

        var (balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) = loadData();
        if (senderAddress != jettonMasterAddress) {
            assert(senderAddress == calculateUserJettonWalletAddress(fromAddress, jettonMasterAddress, jettonWalletCode)) throw 707;
        }
        balance += jettonAmount;
        saveData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode);

        var tonBalanceBeforeMsg: int = myBalance - msgValue;
        var storageFee: int = MIN_TONS_FOR_STORAGE - min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE);
        msgValue -= (storageFee + EXPECTED_GAS_UPPER_BOUND);

        if (forwardTonAmount) {
            msgValue -= (forwardTonAmount + fwdFee);

            var msgBody = beginCell()
                .storeUint(OP_TRANSFER_NOTIFICATION, 32)
                .storeUint(queryId, 64)
                .storeCoins(jettonAmount)
                .storeAddress(fromAddress)
                .storeSlice(eitherForwardPayload)
                .endCell();

            var msg = beginCell()
                .storeUint(0x10, 6) // we should not bounce here cause receiver can have uninitialized contract
                .storeAddress(ownerAddress)
                .storeCoins(forwardTonAmount)
                .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeRef(msgBody)
                .endCell();

            sendRawMessage(msg, 1);
        }

        if (responseAddress.isInternal() & (msgValue > 0)) {
            var msg = beginCell()
                .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 010000
                .storeAddress(responseAddress)
                .storeCoins(msgValue)
                .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeUint(OP_EXCESSES, 32)
                .storeUint(queryId, 64)
                .endCell();
            sendRawMessage(msg, 2);
        }

        return;
    }

    if (op == OP_BURN) {
        assert(msgValue > fwdFee + 2 * EXPECTED_GAS_UPPER_BOUND) throw 707;

        // NOTE we can not allow fails in action phase since in that case there will be
        // no bounce. Thus check and throw in computation phase.
        var queryId = inMsgBody.loadUint(64);
        var jettonAmount = inMsgBody.loadCoins();
        var responseAddress = inMsgBody.loadAddress();
        var customPayload = inMsgBody.loadDict();

        var (balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) = loadData();
        assert(senderAddress == ownerAddress) throw 705;
        assert(balance >= jettonAmount) throw 706;
        balance -= jettonAmount;
        saveData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode);

        var msgBody = beginCell()
            .storeUint(OP_BURN_NOTIFICATION, 32)
            .storeUint(queryId, 64)
            .storeCoins(jettonAmount)
            .storeAddress(ownerAddress)
            .storeAddress(responseAddress)
            .endCell();

        var msg = beginCell()
            .storeUint(0x18, 6)
            .storeAddress(jettonMasterAddress)
            .storeCoins(0)
            .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeRef(msgBody)
            .endCell();

        sendRawMessage(msg, 64);
        return;
    }

    throw 0xffff;
}

get get_wallet_data(): (int, address, address, cell) {
    return loadData();
}
