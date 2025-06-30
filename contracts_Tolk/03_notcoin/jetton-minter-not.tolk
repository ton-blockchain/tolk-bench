// Jetton minter smart contract

tolk 0.99

import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"

import "errors"
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
    if (inMsgBody.loadMessageOp() == InternalTransfer.getDeclaredPackPrefix()) {
        inMsgBody.skipMessageQueryId();
        var jettonAmount: int = inMsgBody.loadCoins();
        var storage = lazy MinterStorage.load();
        storage.totalSupply -= jettonAmount;
        storage.save();
    }
}


type AllowedMinterMessage =
    MintNewJettons |
    BurnNotificationForMinter |
    RequestWalletAddress |
    ChangeMinterAdmin |
    ClaimMinterAdmin |
    DropMinterAdmin |
    ChangeMinterMetadataUri |
    UpgradeMinterCode |
    TopUpTons |
;

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

    // todo load storage once or lazily in each branch?
    var storage = MinterStorage.load();

    val msg = lazy AllowedMinterMessage.fromSlice(inMsgBody);

    match (msg) {
        BurnNotificationForMinter => {
            assert(senderAddress.isAddressOfJettonWallet(msg.fromOwnerAddress, contract.getAddress(), storage.jettonWalletCode)) throw ERROR_NOT_VALID_WALLET;
            storage.totalSupply -= msg.jettonAmount;
            storage.save();

            if (!msg.sendExcessesTo.isInternal()) {
                return;
            }

            val excessesMsg = createMessage({
                bounce: false,
                dest: msg.sendExcessesTo,
                value: 0,
                body: ReturnExcessesBack {
                    queryId: msg.queryId
                }
            });
            excessesMsg.send(SEND_MODE_IGNORE_ERRORS | SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        RequestWalletAddress => {
            var includedAddress: Cell<address>? = msg.isIncludeAddress
                ? msg.ownerAddress.toCell()
                : null;

            var walletAddress: builder;
            if (msg.ownerAddress.getWorkchain() == MY_WORKCHAIN) {
                walletAddress = buildAddressOfJettonWallet(msg.ownerAddress, contract.getAddress(), storage.jettonWalletCode);
            } else {
                walletAddress = beginCell().storeAddressNone();
            }

            val respondMsg = createMessage({
                bounce: false,
                dest: senderAddress,
                value: 0,
                body: UnsafeBodyNoRef {     // tell the compiler that `builder` (walletAddress) is small and safe to inline
                    forceInline: ResponseWalletAddress {
                        queryId: msg.queryId,
                        walletAddress,
                        includedAddress,
                    }
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        MintNewJettons => {
            assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            assert(msg.toOwnerAddress.getWorkchain() == MY_WORKCHAIN) throw ERROR_WRONG_WORKCHAIN;

            val internalTransferMsg = lazy msg.internalTransferMsg.load({
                throwIfOpcodeDoesNotMatch: ERROR_INVALID_OP
            });
            var forwardTonAmount = internalTransferMsg.forwardTonAmount;
            internalTransferMsg.forwardPayload.checkIsCorrectTLBEither();

            // a little more than needed, it’s ok since it’s sent by the admin and excesses will return back
            checkAmountIsEnoughToTransfer(msg.tonAmount, forwardTonAmount, fwdFee);

            storage.totalSupply += internalTransferMsg.jettonAmount;
            storage.save();

            reserveToncoinsOnBalance(ton("0.01"), RESERVE_MODE_EXACT_AMOUNT); // reserve for storage fees

            val deployMsg = createMessage({
                bounce: true,
                dest: calcDeployedJettonWallet(msg.toOwnerAddress, contract.getAddress(), storage.jettonWalletCode),
                value: msg.tonAmount,
                body: msg.internalTransferMsg,
            });
            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        ChangeMinterAdmin => {
            assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            storage.nextAdminAddress = msg.newAdminAddress;
            storage.save();
        }

        ClaimMinterAdmin => {
            assert(senderAddress == storage.nextAdminAddress) throw ERROR_NOT_OWNER;
            storage.adminAddress = storage.nextAdminAddress;
            storage.nextAdminAddress = createAddressNone();
            storage.save();
        }

        DropMinterAdmin => {
            assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            storage.adminAddress = createAddressNone();
            storage.nextAdminAddress = createAddressNone();
            storage.save();
        }

        ChangeMinterMetadataUri => {
            assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            storage.metadataUrl = beginCell().storeSlice(msg.newMetadataUrl).endCell();
            storage.save();
        }

        UpgradeMinterCode => {
            assert(senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            contract.setData(msg.newData);
            contract.setCodePostponed(msg.newCode);
        }

        TopUpTons => {
            // just accept tons
        }

        else => throw 0xFFFF
    }
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
    // todo here, in get method, gas comsumption is not important; if to construct StateInit, it will take less bytecode
    val addrBuilt = buildAddressOfJettonWallet(ownerAddress, contract.getAddress(), storage.jettonWalletCode);
    return address.fromValidBuilder(addrBuilt);
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
