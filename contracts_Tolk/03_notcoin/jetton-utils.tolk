import "gas"
import "errors"
import "messages"


fun calcDeployedJettonWallet(ownerAddress: address, minterAddress: address, jettonWalletCode: cell): AutoDeployAddress {
    val emptyWalletStorage: WalletStorage = {
        status: 0,
        balance: 0,
        ownerAddress,
        minterAddress,
    };

    return {
        workchain: MY_WORKCHAIN,
        stateInit: {
            code: jettonWalletCode,
            data: emptyWalletStorage.toCell()
        }
    }
}

fun buildAddressOfJettonWallet(ownerAddress: address, minterAddress: address, jettonWalletCode: cell) {
    val jwDeployed = calcDeployedJettonWallet(ownerAddress, minterAddress, jettonWalletCode);
    return jwDeployed.buildAddress()
}

fun address.isAddressOfJettonWallet(self, ownerAddress: address, minterAddress: address, jettonWalletCode: cell) {
    val jwDeployed = calcDeployedJettonWallet(ownerAddress, minterAddress, jettonWalletCode);
    return jwDeployed.addressMatches(self)
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
