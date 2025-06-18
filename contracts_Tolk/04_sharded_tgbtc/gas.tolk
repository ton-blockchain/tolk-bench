import "@stdlib/gas-payments"
import "workchain.tolk"
import "op-codes.tolk"

const ONE_TON = 1000000000;

const MIN_STORAGE_DURATION = 5 * 365 * 24 * 3600; // 5 years

//# Precompiled constants
//
//All of the contents are result of contract emulation tests
//

//## Minimal fees
//
//- Transfer [/sandbox_tests/JettonWallet.spec.ts#L935](L935) `0.028627415` TON
//- Burn [/sandbox_tests/JettonWallet.spec.ts#L1185](L1185) `0.016492002` TON


//## Storage
//
//Get calculated in a separate test file [/sandbox_tests/StateInit.spec.ts](StateInit.spec.ts)

//- `JETTON_WALLET_BITS` [/sandbox_tests/StateInit.spec.ts#L92](L92)
const JETTON_WALLET_BITS = 1026;

//- `JETTON_WALLET_CELLS`: [/sandbox_tests/StateInit.spec.ts#L92](L92)
const JETTON_WALLET_CELLS = 3;

// difference in JETTON_WALLET_BITS/JETTON_WALLET_INITSTATE_BITS is difference in
// StateInit and AccountStorage (https://github.com/ton-blockchain/ton/blob/master/crypto/block/block.tlb)
// we count bits as if balances are max possible
//- `JETTON_WALLET_INITSTATE_BITS` [/sandbox_tests/StateInit.spec.ts#L95](L95)
const JETTON_WALLET_INITSTATE_BITS = 812;
//- `JETTON_WALLET_INITSTATE_CELLS` [/sandbox_tests/StateInit.spec.ts#L95](L95)
const JETTON_WALLET_INITSTATE_CELLS = 3;

// jetton-wallet.fc#L163 - maunal bits counting
const BURN_NOTIFICATION_BITS = 754; // body = 32+64+124+(3+8+256)+(3+8+256)
const BURN_NOTIFICATION_CELLS = 1; // body always in ref

//## Gas
//
//Gas constants are calculated in the main test suite.
//First the related transaction is found, and then it's
//resulting gas consumption is printed to the console.

//- `SEND_TRANSFER_GAS_CONSUMPTION` [/sandbox_tests/JettonWallet.spec.ts#L1142](L1142)
const SEND_TRANSFER_GAS_CONSUMPTION = 9047;

//- `RECEIVE_TRANSFER_GAS_CONSUMPTION` [/sandbox_tests/JettonWallet.spec.ts#L1151](L1151)
const RECEIVE_TRANSFER_GAS_CONSUMPTION = 10266;

//- `SEND_BURN_GAS_CONSUMPTION` [/sandbox_tests/JettonWallet.spec.ts#L1423](L1423)
const SEND_BURN_GAS_CONSUMPTION = 5529;

//- `RECEIVE_BURN_GAS_CONSUMPTION` [/sandbox_tests/JettonWallet.spec.ts#L1424](L1424)
const RECEIVE_BURN_GAS_CONSUMPTION = 7038;


@pure
fun getPrecompiledGasConsumption(): int?
    asm "GETPRECOMPILEDGAS";

@inline
fun calculateJettonWalletMinStorageFee(): int {
    return calculateStorageFee(MY_WORKCHAIN, MIN_STORAGE_DURATION, JETTON_WALLET_BITS, JETTON_WALLET_CELLS);
}

@inline
fun forwardInitStateOverhead(): int {
    return calculateMessageFeeWithoutLumpPrice(MY_WORKCHAIN, JETTON_WALLET_INITSTATE_BITS, JETTON_WALLET_INITSTATE_CELLS);
}

@inline
fun checkAmountIsEnoughToTransfer(msgValue: int, forwardTonAmount: int, fwdFee: int) {
    var fwdCount: int = forwardTonAmount ? 2 : 1; // second sending (forward) will be cheaper that first

    var jettonWalletGasConsumption: int? = getPrecompiledGasConsumption();
    var sendTransferGasConsumption: int = (jettonWalletGasConsumption == null) ? SEND_TRANSFER_GAS_CONSUMPTION : jettonWalletGasConsumption;
    var receiveTransferGasConsumption: int = (jettonWalletGasConsumption == null) ? RECEIVE_TRANSFER_GAS_CONSUMPTION : jettonWalletGasConsumption;

    assert(msgValue >
        forwardTonAmount +
        // 3 messages: wal1->wal2,  wal2->owner, wal2->response
        // but last one is optional (it is ok if it fails)
        fwdCount * fwdFee +
        forwardInitStateOverhead() + // additional fwd fees related to initstate in iternal_transfer
        calculateGasFee(MY_WORKCHAIN, sendTransferGasConsumption) +
        calculateGasFee(MY_WORKCHAIN, receiveTransferGasConsumption) +
        calculateJettonWalletMinStorageFee()
    ) throw ERROR_NOT_ENOUGH_GAS;
}



@inline
fun checkAmountIsEnoughToBurn(msgValue: int) {
    var jettonWalletGasConsumption: int? = getPrecompiledGasConsumption();
    var sendBurnGasConsumption: int = (jettonWalletGasConsumption == null) ? SEND_BURN_GAS_CONSUMPTION : jettonWalletGasConsumption;

    assert(msgValue >
        calculateMessageFee(MY_WORKCHAIN, BURN_NOTIFICATION_BITS, BURN_NOTIFICATION_CELLS) +
        calculateGasFee(MY_WORKCHAIN, sendBurnGasConsumption) +
        calculateGasFee(MY_WORKCHAIN, RECEIVE_BURN_GAS_CONSUMPTION)
    ) throw ERROR_NOT_ENOUGH_GAS;
}
