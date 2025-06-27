// Jetton minter smart contract

tolk 0.99

import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"

import "op-codes.tolk"
import "jetton-utils.tolk"
import "gas.tolk"
import "messages.tolk"

fun MinterStorage.load() {
    return MinterStorage.fromCell(contract.getData())
}

fun MinterStorage.save(self) {
    contract.setData(self.toCell())
}

// todo inline or inline_ref?
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBouncedPrefix();
    // process only mint bounces
    if (inMsgBody.loadMessageOp() == OP_INTERNAL_TRANSFER) {
        inMsgBody.skipMessageQueryId();
        var jettonAmount: int = inMsgBody.loadCoins();
        var storage = lazy MinterStorage.load();
        storage.totalSupply -= jettonAmount;
        storage.save();
    }
}

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var inMsgFullSlice: slice = inMsgFull.beginParse();
    var msgFlags: int = inMsgFullSlice.loadMessageFlags();

    if (msgFlags & 1) {
        onBounce(inMsgBody);
        return;
    }
    var senderAddress = inMsgFullSlice.loadAddress();
    var fwdFeeFromInMsg: int = inMsgFullSlice.retrieveFwdFee();
    var fwdFee: int = calculateOriginalMessageFee(MY_WORKCHAIN, fwdFeeFromInMsg); // we use message fwd_fee for estimation of forward_payload costs

    var op = inMsgBody.loadMessageOp();

    // todo load storage once or lazily in each branch?
    var storage = MinterStorage.load();

    if (op == OP_MINT) {
        assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
        var queryId = inMsgBody.loadMessageQueryId();
        var toAddress = inMsgBody.loadAddress();
        var tonAmount: int = inMsgBody.loadCoins();
        var masterMsg: cell = inMsgBody.loadRef();
        inMsgBody.assertEnd();

        assert(toAddress.getWorkchain() == MY_WORKCHAIN) throw ERROR_WRONG_WORKCHAIN;

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

        storage.totalSupply += jettonAmount;
        storage.save();

        reserveToncoinsOnBalance(ton("0.01"), RESERVE_MODE_EXACT_AMOUNT); // reserve for storage fees

        var stateInit = calculateJettonWalletStateInit(toAddress, contract.getAddress(), storage.jettonWalletCode);
        var toWalletAddress = calculateJettonWalletAddress(stateInit);

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var deployMsg = beginCell()
            .storeMsgFlagsAndAddressNone(0x18)
            .storeAddress(toWalletAddress) // dest
            .storeCoins(tonAmount)
            .storeStatinitRefAndBodyRef(stateInit, masterMsg)
            .endCell();

        sendRawMessage(deployMsg, SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        return;
    }

    if (op == OP_BURN_NOTIFICATION) {
        // see burn_notification TL-B layout in jetton.tlb
        var queryId = inMsgBody.loadMessageQueryId();
        var jettonAmount = inMsgBody.loadCoins();
        var fromAddress = inMsgBody.loadAddress();
        var responseAddress = inMsgBody.loadAddress();
        inMsgBody.assertEnd();

        assert(senderAddress == calculateUserJettonWalletAddress(fromAddress, contract.getAddress(), storage.jettonWalletCode)) throw ERROR_NOT_VALID_WALLET;

        storage.totalSupply -= jettonAmount;
        storage.save();

        if (responseAddress.isInternal()) {
            // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
            var excessesMsg = beginCell()
                .storeMsgFlagsAndAddressNone(0x10)
                .storeAddress(responseAddress) // dest
                .storeCoins(0)
                .storePrefixOnlyBody()
                .storeMessageOp(OP_EXCESSES)
                .storeMessageQueryId(queryId)
                .endCell();
            sendRawMessage(excessesMsg, SEND_MODE_IGNORE_ERRORS | SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        return;
    }

    if (op == OP_PROVIDE_WALLET_ADDRESS) {
        // see provide_wallet_address TL-B layout in jetton.tlb
        var queryId = inMsgBody.loadMessageQueryId();
        var ownerAddress = inMsgBody.loadAddress();
        var isIncludeAddress = inMsgBody.loadBool();
        inMsgBody.assertEnd();

        var includedAddress: cell? = isIncludeAddress
            ? beginCell().storeAddress(ownerAddress).endCell()
            : null;

        // build MessageRelaxed, see TL-B layout in stdlib.fc#L733
        var msg = beginCell()
            .storeMsgFlagsAndAddressNone(0x10)
            .storeAddress(senderAddress)
            .storeCoins(0)
            .storePrefixOnlyBody()
            .storeMessageOp(OP_TAKE_WALLET_ADDRESS)
            .storeMessageQueryId(queryId);

        if (ownerAddress.getWorkchain() == MY_WORKCHAIN) {
            msg = msg.storeAddress(calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), storage.jettonWalletCode));
        } else {
            msg = msg.storeAddressNone();
        }

        var respondMsg = msg.storeMaybeRef(includedAddress).endCell();
        sendRawMessage(respondMsg, SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        return;
    }

    if (op == OP_CHANGE_ADMIN) {
        assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
        var queryId = inMsgBody.loadMessageQueryId();
        val nextAdminAddress = inMsgBody.loadAddress();
        inMsgBody.assertEnd();
        storage.nextAdminAddress = nextAdminAddress;
        storage.save();
        return;
    }

    if (op == OP_CLAIM_ADMIN) {
        var queryId = inMsgBody.loadMessageQueryId();
        inMsgBody.assertEnd();
        assert(senderAddress == storage.nextAdminAddress) throw ERROR_NOT_OWNER;
        storage.adminAddress = storage.nextAdminAddress;
        storage.nextAdminAddress = createAddressNone();
        storage.save();
        return;
    }

    if (op == OP_DROP_ADMIN) {
        assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
        var queryId = inMsgBody.loadMessageQueryId();
        inMsgBody.assertEnd();
        storage.adminAddress = createAddressNone();
        storage.nextAdminAddress = createAddressNone();
        storage.save();
        return;
    }

    if (op == OP_CHANGE_METADATA_URI) {
        assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
        var queryId = inMsgBody.loadMessageQueryId();
        val metadataUri = inMsgBody;
        storage.metadataUrl = beginCell().storeSlice(metadataUri).endCell();
        storage.save();
        return;
    }

    if (op == OP_UPGRADE) {
        assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
        var queryId = inMsgBody.loadMessageQueryId();
        var newData = inMsgBody.loadRef();
        var newCode = inMsgBody.loadRef();
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

@inline
fun buildContentCell(metadataUri: slice): cell {
    var contentDict: dict = createEmptyDict();
    contentDict.setTokenSnakeMetadataEntry(stringSha256("uri"), metadataUri);
    contentDict.setTokenSnakeMetadataEntry(stringSha256("decimals"), "9");
    return createTokenOnchainMetadata(contentDict);
}

get get_jetton_data(): (int, bool, address, cell, cell) {
    val storage = lazy MinterStorage.load();
    return (storage.totalSupply, true, storage.adminAddress, buildContentCell(storage.metadataUrl.beginParse()), storage.jettonWalletCode);
}

get get_wallet_address(ownerAddress: address): address {
    val storage = lazy MinterStorage.load();
    return calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), storage.jettonWalletCode);
}

get get_next_admin_address(): address {
    val storage = lazy MinterStorage.load();
    return storage.nextAdminAddress;
}


// Key is sha256 hash of string. Value is data encoded as described in "Data serialization" paragraph.
// Snake format - must be prefixed with 0x00 byte
fun dict.setTokenSnakeMetadataEntry(mutate self, key: int, value: slice): void {
    self.uDictSetRef(256, key, beginCell().storeUint(0, 8).storeSlice(value).endCell());
    return;
}

// On-chain content layout The first byte is 0x00 and the rest is key/value dictionary.
@inline
fun createTokenOnchainMetadata(contentDict: dict): cell {
    return beginCell().storeUint(0, 8).storeDict(contentDict).endCell();
}
