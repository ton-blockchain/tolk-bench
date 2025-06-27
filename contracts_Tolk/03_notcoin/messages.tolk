
struct WalletStorage {
    status: uint4;
    balance: coins;     // todo rename? balanceInJettons?
    ownerAddress: address;
    minterAddress: address;
}

struct MinterStorage {
    totalSupply: coins;
    adminAddress: address;
    nextAdminAddress: address;
    jettonWalletCode: cell;
    metadataUrl: cell;
}
