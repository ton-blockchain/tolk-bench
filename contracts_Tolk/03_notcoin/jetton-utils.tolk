import "fees-management"
import "storage"

fun calcDeployedJettonWallet(ownerAddress: address, minterAddress: address, jettonWalletCode: cell): AutoDeployAddress {
    val emptyWalletStorage: WalletStorage = {
        status: 0,
        jettonBalance: 0,
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

fun calcAddressOfJettonWallet(ownerAddress: address, minterAddress: address, jettonWalletCode: cell) {
    val jwDeployed = calcDeployedJettonWallet(ownerAddress, minterAddress, jettonWalletCode);
    return jwDeployed.calculateAddress()
}
