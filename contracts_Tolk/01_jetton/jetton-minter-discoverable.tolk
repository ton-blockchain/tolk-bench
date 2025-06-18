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

type AllowedMinterMessage =
    MintNewJettons |
    BurnNotificationForMinter |
    RequestWalletAddress |
    ChangeMinterAdmin |
    ChangeMinterContent |
;

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    if (inMsgBody.isEnd()) { // ignore empty messages todo if to delete, no tests fail
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

    val msg = lazy AllowedMinterMessage.fromSlice(inMsgBody);

    // todo load storage once or in every branch?
    var storage = MinterStorage.load();

    match (msg) {
        BurnNotificationForMinter => {
            assert(senderAddress.isAddressOfJettonWallet(msg.fromOwnerAddress, contract.getAddress(), storage.jettonWalletCode)) throw 74;

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
            assert(msgValue > fwdFee + MINIMAL_MESSAGE_VALUE_BOUND) throw 75;

            var includedAddress: Cell<address>? = msg.isIncludeAddress
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
                        walletAddress,
                        includedAddress,
                    }
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        MintNewJettons => {
            assert(senderAddress == storage.adminAddress) throw 73;

            // todo why do we originally get jettonAmount from masterMsg, not from msg.jettonAmount?
            var internalTransferMsg = lazy msg.internalTransferMsg.load();
            storage.totalSupply += internalTransferMsg.jettonAmount;
            storage.save();
            // assert(internalTransferMsg.jettonAmount == msg.jettonAmount, 888);   // it's okay

            val deployMsg = createMessage({
                bounce: true,
                dest: {
                    stateInit: {
                        code: storage.jettonWalletCode,
                        data: WalletStorage.generateEmptyData(msg.toOwnerAddress, contract.getAddress())
                    }
                },
                value: msg.tonAmount,
                body: msg.internalTransferMsg,  // a newly-deployed wallet contract will immediately handle it
            });
            deployMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
        }

        ChangeMinterAdmin => {
            assert(senderAddress == storage.adminAddress) throw 73;
            storage.adminAddress = msg.newAdminAddress;
            storage.save();
        }

        ChangeMinterContent => {
            assert(senderAddress == storage.adminAddress) throw 73;
            storage.content = msg.newContent;
            storage.save();
        }

        else => throw 0xFFFF
    }
}

get get_jetton_data(): (int, bool, address, cell, cell) {
    val storage = lazy MinterStorage.load();
    return (storage.totalSupply, true, storage.adminAddress, storage.content, storage.jettonWalletCode);
}

get get_wallet_address(ownerAddress: address): address {
    val storage = lazy MinterStorage.load();
    val addrBuilt = buildAddressOfJettonWallet(ownerAddress, contract.getAddress(), storage.jettonWalletCode);
    return address.fromValidBuilder(addrBuilt);
}
