import "@stdlib/gas-payments"
import "errors"
import "jetton-utils"
import "messages"
import "storage"
import "fees-management"

type AllowedMessageToMinter =
    MintNewJettons |
    BurnNotificationForMinter |
    RequestWalletAddress |
    ChangeMinterAdmin |
    ChangeMinterContent |
;

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    if (inMsgBody.isEnd()) { // ignore empty messages todo if to delete, no tests fail
        return;    // todo what if we throw 0xFFFF here?
    }
    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    if (flags & 1) { // ignore all bounced messages
        return; // todo why do we need this? for example, will throw 0xFFFF on bounce
    }
    var senderAddress = cs.loadAddress();
    cs.loadAddress(); // skip dst
    cs.loadCoins(); // skip value
    cs.skipBits(1); // skip extracurrency collection
    cs.loadCoins(); // skip ihr_fee
    val incomingFwdFee = cs.loadCoins();
    val fwdFee = calculateOriginalMessageFee(BASECHAIN, incomingFwdFee);

    val msg = lazy AllowedMessageToMinter.fromSlice(inMsgBody);

    // todo load storage once or in every branch?
    var storage = MinterStorage.load();

    match (msg) {
        BurnNotificationForMinter => {
            assert (senderAddress.isAddressOfJettonWallet(msg.burnInitiator, contract.getAddress(), storage.jettonWalletCode)) throw ERR_UNAUTHORIZED_BURN;

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
            excessesMsg.send(SEND_MODE_IGNORE_ERRORS + SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        RequestWalletAddress => {
            assert (msgValue > fwdFee + MINIMAL_MESSAGE_VALUE_BOUND) throw ERR_NOT_ENOUGH_AMOUNT_TO_RESPOND;

            var respondOwnerAddress: Cell<address>? = msg.includeOwnerAddress
                ? msg.ownerAddress.toCell()
                : null;

            var walletAddress: builder;
            if (msg.ownerAddress.getWorkchain() == BASECHAIN) {
                walletAddress = buildAddressOfJettonWallet(msg.ownerAddress, contract.getAddress(), storage.jettonWalletCode);
            } else {
                walletAddress = beginCell().storeAddressNone();
            }

            val respondMsg = createMessage({
                bounce: true,
                dest: senderAddress,
                value: 0,
                body: UnsafeBodyNoRef {     // tell the compiler that `builder` (walletAddress) is small and safe to inline
                    forceInline: ResponseWalletAddress {
                        queryId: msg.queryId,
                        jettonWalletAddress: walletAddress,
                        ownerAddress: respondOwnerAddress,
                    }
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        MintNewJettons => {
            assert (senderAddress == storage.adminAddress) throw ERR_NOT_FROM_ADMIN;

            var internalTransferMsg = lazy msg.internalTransferMsg.load();
            storage.totalSupply += internalTransferMsg.jettonAmount;
            storage.save();

            val deployMsg = createMessage({
                bounce: true,
                dest: calcDeployedJettonWallet(msg.mintRecipient, contract.getAddress(), storage.jettonWalletCode),
                value: msg.tonAmount,
                body: msg.internalTransferMsg,  // a newly-deployed wallet contract will immediately handle it
            });
            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
        }

        ChangeMinterAdmin => {
            assert (senderAddress == storage.adminAddress) throw ERR_NOT_FROM_ADMIN;
            storage.adminAddress = msg.newAdminAddress;
            storage.save();
        }

        ChangeMinterContent => {
            assert (senderAddress == storage.adminAddress) throw ERR_NOT_FROM_ADMIN;
            storage.content = msg.newContent;
            storage.save();
        }

        else => throw 0xFFFF
    }
}



struct JettonDataReply {
    totalSupply: int;
    mintable: bool;
    adminAddress: address;
    jettonContent: cell;
    jettonWalletCode: cell;
}

get get_jetton_data(): JettonDataReply {
    val storage = lazy MinterStorage.load();

    return {
        totalSupply: storage.totalSupply,
        mintable: true,
        adminAddress: storage.adminAddress,
        jettonContent: storage.content,
        jettonWalletCode: storage.jettonWalletCode,
    }
}

get get_wallet_address(ownerAddress: address): address {
    val storage = lazy MinterStorage.load();
    val addrBuilt = buildAddressOfJettonWallet(ownerAddress, contract.getAddress(), storage.jettonWalletCode);
    return address.fromValidBuilder(addrBuilt);
}
