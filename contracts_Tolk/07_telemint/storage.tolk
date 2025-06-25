
struct CollectionStorage {
    isCollectionInitialized: bool;
    subwalletId: uint32;
    publicKey: uint256;
    content: cell;
    nftItemCode: cell;
    fullDomain: Cell<TTT>;
    royaltyParams: Cell<RoyaltyParams>;
}

struct TTT {        // todo naming
    length: uint8;
    data: RemainingBitsAndRefs;
}

struct RoyaltyParams {
    royaltyFactor: uint16;
    royaltyBase: uint16;
    address: address;
}

struct ItemStorage {
    config: Cell<ItemConfig>;
    state: Cell<ItemState>?;
}

struct ItemConfig {
    index: uint256;
    collectionAddress: address;
}

struct ItemState {
    ownerAddress: address;
    content: Cell<ItemContent>;
    auction: Cell<Auction>?;
    royaltyParams: Cell<RoyaltyParams>;
}

struct ItemContent {
    nftContent: cell;
    dns: cell?;
    tokenInfo: cell;
}

struct AuctionConfig {
    benificiaryAddress: address;
    minBid: coins;
    maxBid: coins;
    minBidStep: uint8;
    minExtendTime: uint32;
    duration: uint32;
}

struct AuctionState {
    lastBid: Cell<LastBidInfo>?;
    minBid: coins;
    endTime: uint32;
}

struct Auction {
    state: Cell<AuctionState>;
    config: Cell<AuctionConfig>;
}

struct LastBidInfo {
    bidderAddress: address;
    bidAmount: coins;
    bidTimestamp: uint32;
}

fun ItemStorage.generateEmptyData(index: int, collectionAddress: address) {
    val emptyItemStorage: ItemStorage = {
        config: ItemConfig { index, collectionAddress }.toCell(),
        state: null,
    };
    return emptyItemStorage.toCell()
}

fun Auction.createStartingFromNow(config: Cell<AuctionConfig>, minBid: coins, duration: int) {
    return Auction {
        config: config,
        state: AuctionState {
            lastBid: null,
            minBid: minBid,
            endTime: blockchain.now() + duration
        }.toCell()
    }.toCell()
}
