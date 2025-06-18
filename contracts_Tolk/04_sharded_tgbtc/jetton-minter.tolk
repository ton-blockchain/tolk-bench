// Jetton minter smart contract

tolk 0.13

import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"


import "op-codes.tolk"
import "workchain.tolk"
import "jetton-utils.tolk"
import "gas.tolk"

// storage#_ total_supply:Coins admin_address:MsgAddress next_admin_address:MsgAddress jetton_wallet_code:^Cell metadata_uri:^Cell = Storage;
@inline
fun loadData(): (int, address, address, cell, cell) {
    var ds: slice = contract.getData().beginParse();
    var data = (
        ds.loadCoins(), // total_supply
        ds.loadAddress(), // admin_address
        ds.loadAddress(), // next_admin_address
        ds.loadRef(),  // jetton_wallet_code
        ds.loadRef()  // metadata url (contains snake slice without 0x0 prefix)
    );
    ds.assertEnd();
    return data;
}

@inline
fun saveData(totalSupply: int, adminAddress: address, nextAdminAddress: address, jettonWalletCode: cell, metadataUri: cell) {
    contract.setData(
        beginCell()
            .storeCoins(totalSupply)
            .storeAddress(adminAddress)
            .storeAddress(nextAdminAddress)
            .storeRef(jettonWalletCode)
            .storeRef(metadataUri)
            .endCell()
    );
}

@inline
fun sendToJettonWallet(toAddress: address, jettonWalletCode: cell, tonAmount: int, masterMsg: cell, needStateInit: bool) {
    reserveToncoinsOnBalance(ton("0.01"), RESERVE_MODE_EXACT_AMOUNT); // reserve for storage fees

    var shardPrefix: int = getAddressShardPrefix(toAddress);
    var stateInit: cell = calculateJettonWalletStateInit(toAddress, contract.getAddress(), jettonWalletCode);
    var toWalletAddress: address = calculateJettonWalletAddress(shardPrefix, stateInit);

    // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
    var msg = beginCell()
        .storeMsgFlagsAndAddressNone(BOUNCEABLE)
        .storeAddress(toWalletAddress) // dest
        .storeCoins(tonAmount);

    if (needStateInit) {
        msg = msg.storeStatinitRefAndBodyRef(stateInit, masterMsg);
    } else {
        msg = msg.storeOnlyBodyRef(masterMsg);
    }

    sendRawMessage(msg.endCell(), SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
}

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var inMsgFullSlice: slice = inMsgFull.beginParse();
    var msgFlags: int = inMsgFullSlice.loadMessageFlags();

    if (msgFlags & 1) { // is bounced
        inMsgBody.skipBouncedPrefix();
        // process only mint bounces
        if (!(inMsgBody.loadMessageOp() == OP_INTERNAL_TRANSFER)) {
            return;
        }
        inMsgBody.skipMessageQueryId();
        var jettonAmount: int = inMsgBody.loadCoins();
        var (totalSupply: int, adminAddress: address, nextAdminAddress: address, jettonWalletCode: cell, metadataUri: cell) = loadData();
        saveData(totalSupply - jettonAmount, adminAddress, nextAdminAddress, jettonWalletCode, metadataUri);
        return;
    }
    var senderAddress = inMsgFullSlice.loadAddress();
    var fwdFeeFromInMsg = inMsgFullSlice.retrieveFwdFee();
    var fwdFee: int = calculateOriginalMessageFee(MY_WORKCHAIN, fwdFeeFromInMsg); // we use message fwd_fee for estimation of forward_payload costs

    val op = inMsgBody.loadMessageOp();
    val queryId = inMsgBody.loadMessageQueryId();

    var (totalSupply: int, adminAddress: address, nextAdminAddress: address, jettonWalletCode: cell, metadataUri: cell) = loadData();

    if (op == OP_MINT) {
        assert(senderAddress.bitsEqual(adminAddress)) throw ERROR_NOT_OWNER;
        var toAddress = inMsgBody.loadAddress();
        checkSameWorkchain(toAddress);
        var tonAmount = inMsgBody.loadCoins();
        var masterMsg = inMsgBody.loadRef();
        inMsgBody.assertEnd();

        // see internal_transfer TL-B layout in jetton.tlb
        var masterMsgSlice: slice = masterMsg.beginParse();
        assert(masterMsgSlice.loadMessageOp() == OP_INTERNAL_TRANSFER) throw ERROR_INVALID_OP;
        masterMsgSlice.skipMessageQueryId();
        var jettonAmount: int = masterMsgSlice.loadCoins();
        masterMsgSlice.loadAddress(); // from_address
        masterMsgSlice.loadAddress(); // response_address
        var forwardTonAmount: int = masterMsgSlice.loadCoins(); // forward_ton_amount
        checkEitherForwardPayload(masterMsgSlice); // either_forward_payload

        // a little more than needed, it’s ok since it’s sent by the admin and excesses will return back
        checkAmountIsEnoughToTransfer(tonAmount, forwardTonAmount, fwdFee);

        sendToJettonWallet(toAddress, jettonWalletCode, tonAmount, masterMsg, true);
        saveData(totalSupply + jettonAmount, adminAddress, nextAdminAddress, jettonWalletCode, metadataUri);
        return;
    }

    if (op == OP_BURN_NOTIFICATION) {
        // see burn_notification TL-B layout in jetton.tlb
        var jettonAmount = inMsgBody.loadCoins();
        var fromAddress = inMsgBody.loadAddress();
        assert(calculateUserJettonWalletAddress(fromAddress, contract.getAddress(), jettonWalletCode).bitsEqual(senderAddress)) throw ERROR_NOT_VALID_WALLET;
        saveData(totalSupply - jettonAmount, adminAddress, nextAdminAddress, jettonWalletCode, metadataUri);
        var responseAddress = inMsgBody.loadAddress();
        inMsgBody.assertEnd();

        if (responseAddress.isInternal()) {
            // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
            var msg = beginCell()
                .storeMsgFlagsAndAddressNone(NON_BOUNCEABLE)
                .storeAddress(responseAddress) // dest
                .storeCoins(0)
                .storePrefixOnlyBody()
                .storeMessageOp(OP_EXCESSES)
                .storeMessageQueryId(queryId);
            sendRawMessage(msg.endCell(), SEND_MODE_IGNORE_ERRORS | SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        return;
    }

    if (op == OP_PROVIDE_WALLET_ADDRESS) {
        // see provide_wallet_address TL-B layout in jetton.tlb
        var ownerAddress = inMsgBody.loadAddress();
        var isIncludeAddress = inMsgBody.loadBool();
        inMsgBody.assertEnd();

        var includedAddress: cell? = isIncludeAddress
            ? beginCell().storeAddress(ownerAddress).endCell()
            : null;

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var msg = beginCell()
            .storeMsgFlagsAndAddressNone(NON_BOUNCEABLE)
            .storeAddress(senderAddress)
            .storeCoins(0)
            .storePrefixOnlyBody()
            .storeMessageOp(OP_TAKE_WALLET_ADDRESS)
            .storeMessageQueryId(queryId);

        if (isSameWorkchain(ownerAddress)) {
            msg = msg.storeAddress(calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), jettonWalletCode));
        } else {
            msg = msg.storeAddressNone();
        }

        var msgCell: cell = msg.storeMaybeRef(includedAddress).endCell();

        sendRawMessage(msgCell, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        return;
    }

    if (op == OP_CHANGE_ADMIN) {
        assert(senderAddress.bitsEqual(adminAddress)) throw ERROR_NOT_OWNER;
        nextAdminAddress = inMsgBody.loadAddress();
        inMsgBody.assertEnd();
        saveData(totalSupply, adminAddress, nextAdminAddress, jettonWalletCode, metadataUri);
        return;
    }

    if (op == OP_CLAIM_ADMIN) {
        inMsgBody.assertEnd();
        assert(senderAddress.bitsEqual(nextAdminAddress)) throw ERROR_NOT_OWNER;
        saveData(totalSupply, nextAdminAddress, createAddressNone(), jettonWalletCode, metadataUri);
        return;
    }

    if (op == OP_DROP_ADMIN) {
        assert(senderAddress.bitsEqual(adminAddress)) throw ERROR_NOT_OWNER;
        inMsgBody.assertEnd();
        saveData(totalSupply, createAddressNone(), createAddressNone(), jettonWalletCode, metadataUri);
        return;
    }

    if (op == OP_CHANGE_METADATA_URI) {
        assert(senderAddress.bitsEqual(adminAddress)) throw ERROR_NOT_OWNER;
        saveData(totalSupply, adminAddress, nextAdminAddress, jettonWalletCode, beginCell().storeSlice(inMsgBody).endCell());
        return;
    }

    if (op == OP_UPGRADE) {
        assert(senderAddress.bitsEqual(adminAddress)) throw ERROR_NOT_OWNER;
        var (newData: cell, newCode: cell) = (inMsgBody.loadRef(), inMsgBody.loadRef());
        inMsgBody.assertEnd();
        contract.setData(newData);
        contract.setCodePostponed(newCode);
        return;
    }

    if (op == OP_TOP_UP) {
        return; // just accept tons
    }

    throw ERROR_WRONG_OP;
}

// Key is sha256 hash of string. Value is data encoded as described in "Data serialization" paragraph.
// Snake format - must be prefixed with 0x00 byte
fun dict.setTokenSnakeMetadataEntry(mutate self, keySha256: int, value: slice) {
    self.uDictSetRef(256, keySha256, beginCell().storeUint(0, 8).storeSlice(value).endCell());
}

// On-chain content layout The first byte is 0x00 and the rest is key/value dictionary.
@inline
fun createTokenOnchainMetadata(contentDict: dict): cell {
    return beginCell().storeUint(0, 8).storeDict(contentDict).endCell();
}

@inline
fun buildContentCell(metadataUri: slice): cell {
    var contentDict = createEmptyDict();
    contentDict.setTokenSnakeMetadataEntry(stringSha256("uri"), metadataUri);
    contentDict.setTokenSnakeMetadataEntry(stringSha256("decimals"), "9");
    return createTokenOnchainMetadata(contentDict);
}

get get_jetton_data(): (int, bool, address, cell, cell) {
    var (totalSupply: int, adminAddress: address, nextAdminAddress: address, jettonWalletCode: cell, metadataUri: cell) = loadData();
    return (totalSupply, true, adminAddress, buildContentCell(metadataUri.beginParse()), jettonWalletCode);
}

get get_wallet_address(ownerAddress: address): address {
    var (totalSupply: int, adminAddress: address, nextAdminAddress: address, jettonWalletCode: cell, metadataUri: cell) = loadData();
    return calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), jettonWalletCode);
}

get get_next_admin_address(): address {
    var (totalSupply: int, adminAddress: address, nextAdminAddress: address, jettonWalletCode: cell, metadataUri: cell) = loadData();
    return nextAdminAddress;
}
