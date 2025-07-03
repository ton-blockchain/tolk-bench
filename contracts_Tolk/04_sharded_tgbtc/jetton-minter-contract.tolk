import "@stdlib/gas-payments"
import "@stdlib/tvm-dicts"
import "errors"
import "sharding"
import "jetton-utils"
import "fees-management"
import "storage"
import "messages"

type AllowedMessageToMinter =
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

fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
    // process only mint bounces; on other messages, an exception will be thrown, it's okay
    val msg = lazy InternalTransferStep.fromSlice(in.bouncedBody);

    var storage = lazy MinterStorage.load();
    storage.totalSupply -= msg.jettonAmount;
    storage.save();
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedMessageToMinter.fromSlice(in.body);

    // todo load storage once or lazily in each branch?
    var storage = MinterStorage.load();

    match (msg) {
        BurnNotificationForMinter => {
            assert (in.senderAddress.isAddressOfJettonWallet(msg.burnInitiator, contract.getAddress(), storage.jettonWalletCode)) throw ERROR_NOT_VALID_WALLET;
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
            // todo in previous jetton version, here was assert; we don't need it here? do we actually need it there?

            var ownerAddress: Cell<address>? = msg.includeOwnerAddress
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
                dest: in.senderAddress,
                value: 0,
                body: UnsafeBodyNoRef {     // tell the compiler that `builder` (walletAddress) is small and safe to inline
                    forceInline: ResponseWalletAddress {
                        queryId: msg.queryId,
                        jettonWalletAddress: walletAddress,
                        ownerAddress: ownerAddress,
                    }
                }
            });
            // todo in previous jetton version, SEND_MODE_BOUNCE_ON_ACTION_FAIL not used, why?
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        MintNewJettons => {
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            assert (msg.mintRecipient.getWorkchain() == MY_WORKCHAIN) throw ERROR_WRONG_WORKCHAIN;

            val internalTransferMsg = lazy msg.internalTransferMsg.load({
                throwIfOpcodeDoesNotMatch: ERROR_INVALID_OP
            });
            var forwardTonAmount = internalTransferMsg.forwardTonAmount;
            internalTransferMsg.forwardPayload.checkIsCorrectTLBEither();

            // a little more than needed, it’s ok since it’s sent by the admin and excesses will return back
            checkAmountIsEnoughToTransfer(msg.tonAmount, forwardTonAmount, in.originalForwardFee);

            storage.totalSupply += internalTransferMsg.jettonAmount;
            storage.save();

            reserveToncoinsOnBalance(ton("0.01"), RESERVE_MODE_EXACT_AMOUNT); // reserve for storage fees

            val deployMsg = createMessage({
                bounce: true,
                dest: calcDeployedJettonWallet(msg.mintRecipient, contract.getAddress(), storage.jettonWalletCode),
                value: msg.tonAmount,
                body: msg.internalTransferMsg,
            });
            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        }

        ChangeMinterAdmin => {
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            storage.nextAdminAddress = msg.newAdminAddress;
            storage.save();
        }

        ClaimMinterAdmin => {
            assert (in.senderAddress == storage.nextAdminAddress) throw ERROR_NOT_OWNER;
            storage.adminAddress = storage.nextAdminAddress;
            storage.nextAdminAddress = createAddressNone();
            storage.save();
        }

        DropMinterAdmin => {
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            storage.adminAddress = createAddressNone();
            storage.nextAdminAddress = createAddressNone();
            storage.save();
        }

        ChangeMinterMetadataUri => {
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            storage.metadataUri = msg.newMetadataUri.toCell();
            storage.save();
        }

        UpgradeMinterCode => {
            assert (in.senderAddress == storage.adminAddress) throw ERROR_NOT_OWNER;
            contract.setCodePostponed(msg.newCode);
            contract.setData(msg.newData);
        }

        TopUpTons => {
            // just accept tons
        }

        else => throw 0xFFFF
    }
}



struct JettonDataReply {
    totalSupply: int;
    mintable: bool;
    adminAddress: address;
    jettonContent: Cell<OnchainMetadataReply>;
    jettonWalletCode: cell;
}

struct (0x00) OnchainMetadataReply {
    contentDict: dict;      // map from sha256(key) to Cell<SnakeDataReply>
}

struct (0x00) SnakeDataReply {
    string: SnakeString;
}

get get_jetton_data(): JettonDataReply {
    val storage = lazy MinterStorage.load();
    var metadata: OnchainMetadataReply = {
        contentDict: createEmptyDict()
    };
    metadata.contentDict.setMetadataEntry(stringSha256("uri"), storage.metadataUri.load());
    metadata.contentDict.setMetadataEntry(stringSha256("decimals"), "9");

    return {
        totalSupply: storage.totalSupply,
        mintable: true,
        adminAddress: storage.adminAddress,
        jettonContent: metadata.toCell(),
        jettonWalletCode: storage.jettonWalletCode,
    }
}

get get_wallet_address(ownerAddress: address): address {
    val storage = lazy MinterStorage.load();
    val addrBuilt = buildAddressOfJettonWallet(ownerAddress, contract.getAddress(), storage.jettonWalletCode);
    return address.fromValidBuilder(addrBuilt);
}

get get_next_admin_address(): address {
    val storage = lazy MinterStorage.load();
    return storage.nextAdminAddress;
}

fun dict.setMetadataEntry(mutate self, key: int, string: SnakeString) {
    self.uDictSetRef(256, key, SnakeDataReply { string }.toCell());
}
