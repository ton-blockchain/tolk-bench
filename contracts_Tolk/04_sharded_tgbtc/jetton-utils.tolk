import "messages.tolk"
import "errors.tolk"
import "sharding.tolk"

fun WalletStorage.generateEmptyData(ownerAddress: address, minterAddress: address) {
    val emptyWalletStorage: WalletStorage = {
        balance: 0,
        ownerAddress,
        minterAddress,
    };
    return emptyWalletStorage.toCell();
}

fun address.getShardPrefix(self): int {
    val firstBits = (self as slice).preloadUint(3 + 8 + SHARD_DEPTH);
    val mask = (1 << SHARD_DEPTH) - 1;
    return firstBits & mask;
}

fun buildAddressOfJettonWallet(ownerAddress: address, minterAddress: address, jettonWalletCode: cell): builder {
    val stateInitHash = StateInit.calcHashPrefixCodeData(
        SHARD_DEPTH,
        jettonWalletCode,
        WalletStorage.generateEmptyData(ownerAddress, minterAddress)
    );
    // todo manual work, how to better avoid it? (it's important to leave builder here)
    var mask = (1 << (256 - SHARD_DEPTH)) - 1;
    return beginCell()
        .storeUint(0b100, 3)
        .storeUint(MY_WORKCHAIN, 8)
        .storeUint(ownerAddress.getShardPrefix(), SHARD_DEPTH)
        .storeUint(stateInitHash & mask, 256 - SHARD_DEPTH);
}

fun address.isAddressOfJettonWallet(self, ownerAddress: address, minterAddress: address, jettonWalletCode: cell) {
    val (wc, hash) = self.getWorkchainAndHash();
    val stateInitHash = StateInit.calcHashPrefixCodeData(
        SHARD_DEPTH,
        jettonWalletCode,
        WalletStorage.generateEmptyData(ownerAddress, minterAddress)
    );
    var mask = (1 << (256 - SHARD_DEPTH)) - 1;
    return (wc == MY_WORKCHAIN) & ((hash & mask) == (stateInitHash & mask));
}

fun ForwardPayloadRemainder.checkIsCorrectTLBEither(self) {
    // self is TL/B `(Either Cell ^Cell)`; we want to test, that if ^Cell, no other data exists in a slice
    var mutableCopy = self;
    if (mutableCopy.loadMaybeRef() != null) {
        mutableCopy.assertEnd();
    }
    // else forward_payload in slice - arbitrary bits and refs
}

// parse after sender_address
@inline
fun slice.retrieveFwdFee(mutate self): coins {
    self.loadAddress(); // skip dst
    self.loadCoins(); // skip value
    self.skipDict(); // skip extracurrency collection
    self.loadCoins(); // skip ihr_fee
    var fwdFee: coins = self.loadCoins();
    return fwdFee;
}
