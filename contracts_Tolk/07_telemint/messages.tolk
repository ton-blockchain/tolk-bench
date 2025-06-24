import "storage.tolk"

// todo + "#topup"
struct (0x00000000) TopUp {
    comment: RemainingBitsAndRefs;
}

struct (0x4637289b) AskToDeployItem {
    signature: bits512;
    signedData: RemainingBitsAndRefs;
}

struct SignedDataAtDeploy {
    subwalletId: uint32;
    validSince: uint32;
    validTill: uint32;
    cmd: RemainingBitsAndRefs;
}

struct (0x299a3e15) TelemintItemDeploy {
    bidderAddress: address;
    bidAmount: coins;
    tokenInfo: cell;
    nftContent: cell;
    auctionConfig: Cell<AuctionConfig>;
    royaltyParams: Cell<RoyaltyParams>;
}

struct (0x00000000) MakeNewStakeOrTopUp {
    comment: RemainingBitsAndRefs;     // if empty — a new stake; if "#topup" — just top-up contract balance
}

struct (0x693d3950) RequestRoyaltyParams {
    queryId: uint64;
}

struct (0x2fcb26a2) RequestStaticData {
    queryId: uint64;
}

struct (0x371638ae) AskToCancelAuction {
    queryId: uint64;
}

struct (0x487a8e81) AskToStartAuction {
    queryId: uint64;
    newAuctionConfig: Cell<AuctionConfig>;
}

struct (0x5fcc3d14) AskToTransfer {
    queryId: uint64;
    newOwnerAddress: address;
    sendExcessesTo: address;
    customPayload: cell?;
    forwardAmount: coins;
    forwardPayload: RemainingBitsAndRefs;
}
