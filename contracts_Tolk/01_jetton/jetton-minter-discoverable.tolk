// Jettons discoverable smart contract

tolk 0.99

import "op-codes.tolk"
import "jetton-utils.tolk"

// 6905(computational_gas_price) * 1000(cur_gas_price) = 6905000
// ceil(6905000) = 10000000 ~= 0.01 TON
const MINIMAL_MESSAGE_VALUE_BOUND = ton("0.01");

// storage scheme
// storage#_ total_supply:Coins admin_address:MsgAddress content:^Cell jetton_wallet_code:^Cell = Storage;

@inline
fun loadData(): (int, address, cell, cell) {
    var ds: slice = contract.getData().beginParse();
    return (
        ds.loadCoins(), // total_supply
        ds.loadAddress(), // admin_address
        ds.loadRef(), // content
        ds.loadRef() // jetton_wallet_code
    );
}

@inline
fun saveData(totalSupply: int, adminAddress: address, content: cell, jettonWalletCode: cell) {
    contract.setData(beginCell()
        .storeCoins(totalSupply)
        .storeAddress(adminAddress)
        .storeRef(content)
        .storeRef(jettonWalletCode)
        .endCell()
    );
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
    var fwdFee: int = mulDivFloor(cs.loadCoins(), 3, 2); // we use message fwd_fee for estimation of forward_payload costs

    var op: int = inMsgBody.loadUint(32);
    var queryId: int = inMsgBody.loadUint(64);

    var (totalSupply: int, adminAddress: address, content: cell, jettonWalletCode: cell) = loadData();

    if (op == OP_MINT) {
        assert(senderAddress == adminAddress) throw 73;
        var toAddress = inMsgBody.loadAddress();
        var amount: int = inMsgBody.loadCoins();
        var masterMsg: cell = inMsgBody.loadRef();
        var masterMsgCs: slice = masterMsg.beginParse();
        masterMsgCs.skipBits(32 + 64); // op + query_id
        var jettonAmount: int = masterMsgCs.loadCoins();
        var stateInit: cell = calculateJettonWalletStateInit(toAddress, contract.getAddress(), jettonWalletCode);
        var toWalletAddress = calculateJettonWalletAddress(stateInit);
        var msg = beginCell()
            .storeUint(0x18, 6)
            .storeAddress(toWalletAddress)
            .storeCoins(amount)
            .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
            .storeRef(stateInit)
            .storeRef(masterMsg);
        sendRawMessage(msg.endCell(), 1); // pay transfer fees separately, revert on errors
        saveData(totalSupply + jettonAmount, adminAddress, content, jettonWalletCode);
        return;
    }

    if (op == OP_BURN_NOTIFICATION) {
        var jettonAmount = inMsgBody.loadCoins();
        var fromAddress = inMsgBody.loadAddress();
        assert(calculateUserJettonWalletAddress(fromAddress, contract.getAddress(), jettonWalletCode) == senderAddress) throw 74;
        saveData(totalSupply - jettonAmount, adminAddress, content, jettonWalletCode);
        var responseAddress = inMsgBody.loadAddress();
        if (responseAddress.isInternal()) {
            var msg = beginCell()
                .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 011000
                .storeAddress(responseAddress)
                .storeCoins(0)
                .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeUint(OP_EXCESSES, 32)
                .storeUint(queryId, 64);
            sendRawMessage(msg.endCell(), 2 + 64);
        }
        return;
    }

    if (op == OP_PROVIDE_WALLET_ADDRESS) {
        assert(msgValue > fwdFee + MINIMAL_MESSAGE_VALUE_BOUND) throw 75;

        var ownerAddress = inMsgBody.loadAddress();
        var isIncludeAddress: int = inMsgBody.loadUint(1);

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
            msg = msg.storeAddress(calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), jettonWalletCode));
        } else {
            msg = msg.storeUint(0, 2); // addr_none
        }
        sendRawMessage(msg.storeMaybeRef(includedAddress).endCell(), 64);
        return;
    }

    if (op == OP_CHANGE_ADMIN) { // change admin
        assert(senderAddress == adminAddress) throw 73;
        var newAdminAddress = inMsgBody.loadAddress();
        saveData(totalSupply, newAdminAddress, content, jettonWalletCode);
        return;
    }

    if (op == OP_CHANGE_CONTENT) { // change content, delete this for immutable tokens
        assert(senderAddress == adminAddress) throw 73;
        saveData(totalSupply, adminAddress, inMsgBody.loadRef(), jettonWalletCode);
        return;
    }

    throw 0xffff;
}

get get_jetton_data(): (int, int, address, cell, cell) {
    var (totalSupply: int, adminAddress: address, content: cell, jettonWalletCode: cell) = loadData();
    return (totalSupply, -1, adminAddress, content, jettonWalletCode);
}

get get_wallet_address(ownerAddress: address): address {
    var (totalSupply: int, adminAddress: address, content: cell, jettonWalletCode: cell) = loadData();
    return calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), jettonWalletCode);
}
