
struct WalletStorage {
    balance: coins;     // todo rename? myJettonBalance?
    ownerAddress: address;
    minterAddress: address;
}

struct MinterStorage {
    totalSupply: coins;
    adminAddress: address;
    content: cell;
    jettonWalletCode: cell;
}

type ForwardPayloadRemainder = RemainingBitsAndRefs;

struct (0x0f8a7ea5) AskToTransfer {
    queryId: uint64;
    jettonAmount: coins;
    toOwnerAddress: address;
    sendExcessesTo: address;
    customPayload: cell?;
    forwardTonAmount: coins;
    forwardPayload: ForwardPayloadRemainder;
}

struct (0x7362d09c) TransferNotificationForOwner {
    queryId: uint64;
    jettonAmount: coins;
    fromAddress: address;       // todo what is this address?
    forwardPayload: ForwardPayloadRemainder;
}

struct (0x178d4519) InternalTransfer {
    queryId: uint64;
    jettonAmount: coins;
    ownerAddress: address;      // todo fromOwnerAddress?
    sendExcessesTo: address;
    forwardTonAmount: coins;
    forwardPayload: ForwardPayloadRemainder;
}

struct (0xd53276db) ReturnExcessesBack {
    queryId: uint64;
}

struct (0x595f07bc) AskToBurn {
    queryId: uint64;
    jettonAmount: coins;
    sendExcessesTo: address;
    customPayload: cell?;
}

struct (0x7bdd97de) BurnNotificationForMinter {
    queryId: uint64;
    jettonAmount: coins;
    fromOwnerAddress: address;
    sendExcessesTo: address;
}

struct (0x2c76b973) RequestWalletAddress {
    queryId: uint64;
    ownerAddress: address;
    isIncludeAddress: bool;
}

struct (0xd1735400) ResponseWalletAddress {
    queryId: uint64;
    walletAddress: builder;
    includedAddress: Cell<address>?;
}

struct (0x00000015) MintNewJettons {
    queryId: uint64;
    toAddress: address;
    amount: coins;          // todo amount of what? rename?
    jettonAmount: coins;    // todo unused, what does it mean?
    internalTransferMsg: Cell<InternalTransfer>;
}

struct (0x00000003) ChangeMinterAdmin {
    queryId: uint64;
    newAdminAddress: address;
}

struct (0x00000004) ChangeMinterContent {
    queryId: uint64;
    newContent: cell;
}
