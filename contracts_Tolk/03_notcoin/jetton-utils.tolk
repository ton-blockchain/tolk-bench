import "gas"
import "errors"
import "messages"

fun WalletStorage.generateEmptyData(ownerAddress: address, minterAddress: address) {
    val emptyWalletStorage: WalletStorage = {
        status: 0,
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
        .storeUint(MY_WORKCHAIN, 8)
        .storeUint(stateInitHash, 256);
}

fun address.isAddressOfJettonWallet(self, ownerAddress: address, minterAddress: address, jettonWalletCode: cell) {
    val (wc, hash) = self.getWorkchainAndHash();
    val stateInitHash = StateInit.calcHashCodeData(
        jettonWalletCode,
        WalletStorage.generateEmptyData(ownerAddress, minterAddress)
    );
    return (wc == MY_WORKCHAIN) & (hash == stateInitHash);
}

fun ForwardPayloadRemainder.checkIsCorrectTLBEither(self) {
    // self is TL/B `(Either Cell ^Cell)`; we want to test, that if ^Cell, no other data exists in a slice
    var mutableCopy = self;
    if (mutableCopy.loadMaybeRef() != null) {
        mutableCopy.assertEnd();
    }
    // else forward_payload in slice - arbitrary bits and refs
}

// todo del after TVM 11
// parse after sender_address
@inline
fun slice.retrieveFwdFee(mutate self): coins {
    self.loadAddress(); // skip dst
    self.loadCoins(); // skip value
    self.skipDict(); // skip extracurrency collection
    self.loadCoins(); // skip ihr_fee
    var fwdFee: int = self.loadCoins();
    return fwdFee;
}
