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

    val msg = lazy AllowedMinterMessage.fromSlice(inMsgBody);

    // todo load storage once or in every branch?
    var storage = MinterStorage.load();

    match (msg) {
        MintNewJettons => {
            assert(senderAddress == storage.adminAddress) throw 73;

            // todo why do we originally get jettonAmount from masterMsg, not from msg.jettonAmount?
            var internalTransferMsg = lazy msg.internalTransferMsg.load();
            storage.totalSupply += internalTransferMsg.jettonAmount;
            storage.save();
            // assert(internalTransferMsg.jettonAmount == msg.jettonAmount, 888);   // it's okay

            var stateInit: cell = calculateJettonWalletStateInit(msg.toAddress, contract.getAddress(), storage.jettonWalletCode);
            var toWalletAddress = calculateJettonWalletAddress(stateInit);
            var deployMsg = beginCell()
                .storeUint(0x18, 6)
                .storeAddress(toWalletAddress)
                .storeCoins(msg.amount)
                .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
                .storeRef(stateInit)
                .storeRef(msg.internalTransferMsg)
                .endCell();
            sendRawMessage(deployMsg, 1); // pay transfer fees separately, revert on errors
        }

        BurnNotificationForMinter => {
            assert(senderAddress == calculateUserJettonWalletAddress(msg.fromOwnerAddress, contract.getAddress(), storage.jettonWalletCode)) throw 74;

            storage.totalSupply -= msg.jettonAmount;
            storage.save();

            if (msg.sendExcessesTo.isInternal()) {
                var excessesMsg = beginCell()
                    .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 011000
                    .storeAddress(msg.sendExcessesTo)
                    .storeCoins(0)
                    .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                    .storeUint(OP_EXCESSES, 32)
                    .storeUint(msg.queryId, 64)
                    .endCell();
                sendRawMessage(excessesMsg, 2 + 64);
            }
        }

        RequestWalletAddress => {
            assert(msgValue > fwdFee + MINIMAL_MESSAGE_VALUE_BOUND) throw 75;

            var includedAddress: cell? = msg.isIncludeAddress
                ? beginCell().storeAddress(msg.ownerAddress).endCell()
                : null;

            var responseMsg = beginCell()
                .storeUint(0x18, 6)
                .storeAddress(senderAddress)
                .storeCoins(0)
                .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeUint(OP_TAKE_WALLET_ADDRESS, 32)
                .storeUint(msg.queryId, 64);

            if (msg.ownerAddress.getWorkchain() == BASECHAIN) {
                responseMsg = responseMsg.storeAddress(calculateUserJettonWalletAddress(msg.ownerAddress, contract.getAddress(), storage.jettonWalletCode));
            } else {
                responseMsg = responseMsg.storeUint(0, 2); // addr_none
            }
            sendRawMessage(responseMsg.storeMaybeRef(includedAddress).endCell(), 64);
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
    return calculateUserJettonWalletAddress(ownerAddress, contract.getAddress(), storage.jettonWalletCode);
}
