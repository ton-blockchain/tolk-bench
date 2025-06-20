import "storage.tolk"

struct NftItemInitAtDeployment {
    ownerAddress: address;
    content: cell;
}

struct (0x693d3950) RequestRoyaltyParams {
    queryId: uint64;
}

struct (0xa8cb00ad) ResponseRoyaltyParams {
    queryId: uint64;
    royaltyParams: RoyaltyParams;
}

struct (0x00000001) DeployNft {
    queryId: uint64;
    itemIndex: uint64;
    amount: coins;
    initParams: Cell<NftItemInitAtDeployment>;
}

struct (0x00000002) BatchDeployNfts {
    queryId: uint64;
    deployList: dict;       // actually, a map of [itemIndex => BatchDeployDictItem]
}

struct BatchDeployDictItem {
    amount: coins;
    initParams: Cell<NftItemInitAtDeployment>;
}

struct (0x00000003) ChangeNftOwner {
    queryId: uint64;
    newOwnerAddress: address;
}

struct (0x2fcb26a2) RequestStaticData {
    queryId: uint64;
}

struct (0x8b771735) ResponseStaticData {
    queryId: uint64;
    index: uint256;
    collectionAddress: address;
}

struct (0x05138d91) NotificationOwnershipAssigned {
    queryId: uint64;
    ownerAddress: address;
    payload: RemainingBitsAndRefs;
}

struct (0xd53276db) ReturnExcessesBack {
    queryId: uint64;
}

struct (0x5fcc3d14) AskToTransfer {
    queryId: uint64;
    newOwnerAddress: address;
    sendExcessesTo: address;
    customPayload: dict;
    forwardTonAmount: coins;
    forwardPayload: RemainingBitsAndRefs;
}

