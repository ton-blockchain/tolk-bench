
struct WalletStorage {
    balance: coins;     // todo jettonAmount?
    ownerAddress: address;
    minterAddress: address;
}

struct MinterStorage {
    totalSupply: coins;
    adminAddress: address;
    content: cell;
    jettonWalletCode: cell;
}

