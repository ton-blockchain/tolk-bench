// Jettons discoverable smart contract

tolk 0.99

import "@stdlib/gas-payments"
import "op-codes.tolk"
import "jetton-utils.tolk"
import "messages.tolk"

// 6905(computational_gas_price) * 1000(cur_gas_price) = 6905000
// ceil(6905000) = 10000000 ~= 0.01 TON
const MINIMAL_MESSAGE_VALUE_BOUND = ton("0.01");

fun MinterStorage.load() {
    return MinterStorage.fromCell(contract.getData())
}

fun MinterStorage.save(self) {
    contract.setData(self.toCell())
}

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    if (inMsgBody.isEnd()) { // ignore empty messages
        return;
    }
    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    if (flags & 1) { // ignore all bounced messages
        return;
    }
    var senderAddress = cs.loadAddress();
    cs.loadAddress(); // skip dst
    cs.loadCoins(); // skip value
    cs.skipBits(1); // skip extracurrency collection
    cs.loadCoins(); // skip ihr_fee
    val incomingFwdFee = cs.loadCoins();
    val fwdFee = calculateOriginalMessageFee(BASECHAIN, incomingFwdFee);

    var op: int = inMsgBody.loadUint(32);

    // todo load storage once or in every branch?
    var storage = MinterStorage.load();

    if (op == OP_MINT) {
        assert(senderAddress == storage.adminAddress) throw 73;

        var queryId = inMsgBody.loadUint(64);
        var toAddress = inMsgBody.loadAddress();
        var amount = inMsgBody.loadCoins();
        var masterMsg = inMsgBody.loadRef();

        var masterMsgCs: slice = masterMsg.beginParse();
        masterMsgCs.skipBits(32 + 64); // op + query_id
        var jettonAmount = masterMsgCs.loadCoins();
        storage.totalSupply += jettonAmount;
        storage.save();

        var stateInit: cell = calculateJettonWalletStateInit(toAddress, contract.getAddress(), storage.jettonWalletCode);
        var toWalletAddress = calculateJettonWalletAddress(stateInit);
        var msg = beginCell()
            .storeUint(0x18, 6)
            .storeAddress(toWalletAddress)
            .storeCoins(amount)
            .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
            .storeRef(stateInit)
            .storeRef(masterMsg)
            .endCell();
        sendRawMessage(msg, 1); // pay transfer fees separately, revert on errors
        return;
    }

    if (op == OP_BURN_NOTIFICATION) {
        var queryId = inMsgBody.loadUint(64);
        var jettonAmount = inMsgBody.loadCoins();
        var fromAddress = inMsgBody.loadAddress();
        var responseAddress = inMsgBody.loadAddress();

        assert(senderAddress == calculateUserJettonWalletAddress(fromAddress, contract.getAddress(), storage.jettonWalletCode)) throw 74;

        storage.totalSupply -= jettonAmount;
        storage.save();

        if (responseAddress.isInternal()) {
            var msg = beginCell()
                .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 011000
                .storeAddress(responseAddress)
                .storeCoins(0)
                .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeUint(OP_EXCESSES, 32)
                .storeUint(queryId, 64)
                .endCell();
            sendRawMessage(msg, 2 + 64);
        }
        return;
    }

    if (op == OP_PROVIDE_WALLET_ADDRESS) {
        assert(msgValue > fwdFee + MINIMAL_MESSAGE_VALUE_BOUND) throw 75;

        var queryId = inMsgBody.loadUint(64);
        var ownerAddress = inMsgBody.loadAddress();
        var isIncludeAddress = inMsgBody.loadBool();

        var includedAddress: cell? = isIncludeAddress
            ? beginCell().storeAddress(ownerAddress).endCell()
            : null;

        var msg = beginCell()
            .storeUint(0x18, 6)
            .storeAddress(senderAddress)
            .storeCoins(0)
            .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
            .storeUint(OP_TAKE_WALLET_ADDRESS, 32)
            .storeUint(queryId, 64);

        if (ownerAddress.getWorkchain() == BASECHAIN) {
            msg = msg.storeAddress(calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), storage.jettonWalletCode));
        } else {
            msg = msg.storeUint(0, 2); // addr_none
        }
        sendRawMessage(msg.storeMaybeRef(includedAddress).endCell(), 64);
        return;
    }

    if (op == OP_CHANGE_ADMIN) { // change admin
        assert(senderAddress == storage.adminAddress) throw 73;
        var queryId = inMsgBody.loadUint(64);
        var newAdminAddress = inMsgBody.loadAddress();
        storage.adminAddress = newAdminAddress;
        storage.save();
        return;
    }

    if (op == OP_CHANGE_CONTENT) { // change content, delete this for immutable tokens
        assert(senderAddress == storage.adminAddress) throw 73;
        var queryId = inMsgBody.loadUint(64);
        var newContent = inMsgBody.loadRef();
        storage.content = newContent;
        storage.save();
        return;
    }

    throw 0xffff;
}

get get_jetton_data(): (int, bool, address, cell, cell) {
    val storage = lazy MinterStorage.load();
    return (storage.totalSupply, true, storage.adminAddress, storage.content, storage.jettonWalletCode);
}

get get_wallet_address(ownerAddress: address): address {
    val storage = lazy MinterStorage.load();
    return calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), storage.jettonWalletCode);
}
