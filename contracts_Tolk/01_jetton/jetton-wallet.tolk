// Jetton Wallet Smart Contract

tolk 0.99

import "@stdlib/gas-payments"
import "op-codes.tolk"
import "jetton-utils.tolk"
import "messages.tolk"

const MIN_TONS_FOR_STORAGE = ton("0.01");
// Note that 2 * gas_consumptions is expected to be able to cover fees on both wallets (sender and receiver)
// and also constant fees on inter-wallet interaction, in particular fwd fee on state_init transfer
// that means that you need to reconsider this fee when:
// a) jetton logic become more gas-heavy
// b) jetton-wallet code (sent with inter-wallet message) become larger or smaller
// c) global fee changes / different workchain
const EXPECTED_GAS_UPPER_BOUND = ton("0.015");

fun WalletStorage.load() {
    return WalletStorage.fromCell(contract.getData())
}

fun WalletStorage.save(self) {
    contract.setData(self.toCell())
}

// todo inline or inline_ref?
@inline
fun onBounce(inMsgBody: slice) {
    inMsgBody.skipBouncedPrefix();
    var op: int = inMsgBody.loadUint(32);
    assert((op == OP_INTERNAL_TRANSFER) | (op == OP_BURN_NOTIFICATION)) throw 709;
    var queryId: int = inMsgBody.loadUint(64);
    var jettonAmount: int = inMsgBody.loadCoins();
    var storage = lazy WalletStorage.load();
    storage.balance += jettonAmount;
    storage.save();
}

type AllowedWalletMessage =
    AskToTransfer |
    AskToBurn |
    InternalTransfer |
;

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

    val msg = lazy AllowedWalletMessage.fromSlice(inMsgBody);

    match (msg) {
        AskToTransfer => {
            assert(msg.forwardPayload.remainingBitsCount()) throw 708;
            assert(msg.toOwnerAddress.getWorkchain() == BASECHAIN) throw 333;

            var storage = lazy WalletStorage.load();
            assert(senderAddress == storage.ownerAddress) throw 705;
            assert(storage.balance >= msg.jettonAmount) throw 706;
            storage.balance -= msg.jettonAmount;
            storage.save();

            var forwardedMessagesCount = msg.forwardTonAmount ? 2 : 1;
            assert(msgValue >
                msg.forwardTonAmount +
                // 3 messages: wal1->wal2,  wal2->owner, wal2->response
                // but last one is optional (it is ok if it fails)
                forwardedMessagesCount * fwdFee +
                (2 * EXPECTED_GAS_UPPER_BOUND + MIN_TONS_FOR_STORAGE)
            ) throw 709;

            var msgBody = beginCell()
                .storeUint(OP_INTERNAL_TRANSFER, 32)
                .storeUint(msg.queryId, 64)
                .storeCoins(msg.jettonAmount)
                .storeAddress(storage.ownerAddress)
                .storeAddress(msg.sendExcessesTo)
                .storeCoins(msg.forwardTonAmount)
                .storeSlice(msg.forwardPayload)
                .endCell();

            var stateInit: cell = calculateJettonWalletStateInit(msg.toOwnerAddress, storage.minterAddress, contract.getCode());
            var toWalletAddress = calculateJettonWalletAddress(stateInit);
            var deployMsg = beginCell()
                .storeUint(0x18, 6)
                .storeAddress(toWalletAddress)
                .storeCoins(0)
                .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
                .storeRef(stateInit)
                .storeRef(msgBody)
                .endCell();

            sendRawMessage(deployMsg, 64); // revert on errors
        }

        InternalTransfer => {
            var storage = lazy WalletStorage.load();
            if (senderAddress != storage.minterAddress) {
                assert(senderAddress == calculateUserJettonWalletAddress(msg.ownerAddress, storage.minterAddress, contract.getCode())) throw 707;
            }
            storage.balance += msg.jettonAmount;
            storage.save();

            var tonBalanceBeforeMsg: int = myBalance - msgValue;
            var storageFee: int = MIN_TONS_FOR_STORAGE - min(tonBalanceBeforeMsg, MIN_TONS_FOR_STORAGE);
            msgValue -= (storageFee + EXPECTED_GAS_UPPER_BOUND);

            if (msg.forwardTonAmount) {
                msgValue -= (msg.forwardTonAmount + fwdFee);

                var msgBody = beginCell()
                    .storeUint(OP_TRANSFER_NOTIFICATION, 32)
                    .storeUint(msg.queryId, 64)
                    .storeCoins(msg.jettonAmount)
                    .storeAddress(msg.ownerAddress)
                    .storeSlice(msg.forwardPayload)
                    .endCell();

                var notifyMinterMsg = beginCell()
                    .storeUint(0x10, 6) // we should not bounce here cause receiver can have uninitialized contract
                    .storeAddress(storage.ownerAddress)
                    .storeCoins(msg.forwardTonAmount)
                    .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                    .storeRef(msgBody)
                    .endCell();

                sendRawMessage(notifyMinterMsg, 1);
            }

            if (msg.sendExcessesTo.isInternal() & (msgValue > 0)) {
                var excessesMsg = beginCell()
                    .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 010000
                    .storeAddress(msg.sendExcessesTo)
                    .storeCoins(msgValue)
                    .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                    .storeUint(OP_EXCESSES, 32)
                    .storeUint(msg.queryId, 64)
                    .endCell();
                sendRawMessage(excessesMsg, 2);
            }
        }

        AskToBurn => {
            assert(msgValue > fwdFee + 2 * EXPECTED_GAS_UPPER_BOUND) throw 707;

            var storage = lazy WalletStorage.load();
            assert(senderAddress == storage.ownerAddress) throw 705;
            assert(storage.balance >= msg.jettonAmount) throw 706;
            storage.balance -= msg.jettonAmount;
            storage.save();

            var msgBody = beginCell()
                .storeUint(OP_BURN_NOTIFICATION, 32)
                .storeUint(msg.queryId, 64)
                .storeCoins(msg.jettonAmount)
                .storeAddress(storage.ownerAddress)
                .storeAddress(msg.sendExcessesTo)
                .endCell();

            var notifyMinterMsg = beginCell()
                .storeUint(0x18, 6)
                .storeAddress(storage.minterAddress)
                .storeCoins(0)
                .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
                .storeRef(msgBody)
                .endCell();

            sendRawMessage(notifyMinterMsg, 64);
        }

        else => throw 0xFFFF
    }
}

get get_wallet_data(): (coins, address, address, cell) {
    val storage = lazy WalletStorage.load();
    return (storage.balance, storage.ownerAddress, storage.minterAddress, contract.getCode())
}
