import "messages.tolk"

@inline
fun packJettonWalletData(balance: int, ownerAddress: address, minterAddress: address): cell {
    return WalletStorage {
        balance: balance,
        ownerAddress: ownerAddress,
        minterAddress: minterAddress,
    }.toCell()
}

@inline
fun calculateJettonWalletStateInit(ownerAddress: address, minterAddress: address, jettonWalletCode: cell): cell {
    return beginCell()
        .storeUint(0, 2)
        .storeDict(jettonWalletCode)
        .storeDict(packJettonWalletData(0, ownerAddress, minterAddress))
        .storeUint(0, 1)
        .endCell();
}

@inline
fun calculateJettonWalletAddress(stateInit: cell): address {
    return beginCell().storeUint(4, 3)        // 0b100  (std no anycast)
        .storeInt(BASECHAIN, 8)
        .storeUint(stateInit.hash(), 256)
        .endCell()
        .beginParse() as address;
}

@inline
fun calculateUserJettonWalletAddress(ownerAddress: address, minterAddress: address, jettonWalletCode: cell): address {
    return calculateJettonWalletAddress(calculateJettonWalletStateInit(ownerAddress, minterAddress, jettonWalletCode));
}
