import "messages.tolk"

fun WalletStorage.generateEmptyData(ownerAddress: address, minterAddress: address) {
    val emptyWalletStorage: WalletStorage = {
        balance: 0,
        ownerAddress,
        minterAddress,
    };
    return emptyWalletStorage.toCell();
}

fun buildAddressOfJettonWallet(ownerAddress: address, minterAddress: address, jettonWalletCode: cell): builder {
    val stateInitHash = StateInit.calcHashCodeData(
        jettonWalletCode,
        WalletStorage.generateEmptyData(ownerAddress, minterAddress)
    );
    // todo manual work, how to better avoid it? (it's important to leave builder here)
    return beginCell()
        .storeUint(0b100, 3)
        .storeUint(BASECHAIN, 8)
        .storeUint(stateInitHash, 256)
}

fun address.isAddressOfJettonWallet(self, ownerAddress: address, minterAddress: address, jettonWalletCode: cell) {
    val (wc, hash) = self.getWorkchainAndHash();
    val stateInitHash = StateInit.calcHashCodeData(
        jettonWalletCode,
        WalletStorage.generateEmptyData(ownerAddress, minterAddress)
    );
    return (wc == BASECHAIN) & (hash == stateInitHash);
}
