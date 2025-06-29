
// encoded as TL/B `len: (## 8) data: (bits (len*8))`
type TelegramString = slice;

fun TelegramString.packToBuilder(self, mutate b: builder) {
    val bytes = self.remainingBitsCount() / 8;      // assume it's divisible (since decoded from input)
    b.storeUint(bytes, 8);
    b.storeSlice(self);
}

fun TelegramString.unpackFromSlice(mutate s: slice) {
    val bytes = s.loadUint(8);
    return s.loadBits(bytes * 8);
}

struct CollectionStorage {
    isCollectionInitialized: bool;
    subwalletId: uint32;
    publicKey: uint256;
    content: cell;
    nftItemCode: cell;
    fullDomain: Cell<TelegramString>;
    royaltyParams: Cell<RoyaltyParams>;
}

struct RoyaltyParams {
    royaltyFactor: uint16;
    royaltyBase: uint16;
    address: address;
}

struct ItemStorageUninitialized {
    config: Cell<ItemConfig>;
}

struct ItemStorage {
    config: Cell<ItemConfig>;
    ownerAddress: address;
    content: Cell<ItemContent>;
    auction: Cell<Auction>?;
    royaltyParams: Cell<RoyaltyParams>;
}

struct ItemConfig {
    index: uint256;
    collectionAddress: address;
}

struct ItemContent {
    nftContent: cell;
    dns: cell?;
    tokenInfo: Cell<TokenNameAndDomain>;
}

struct TokenNameAndDomain {
    tokenName: TelegramString;
    domain: TelegramString;
}

struct AuctionConfig {
    benificiaryAddress: address;
    minBid: coins;
    maxBid: coins;
    minBidStep: uint8;
    minExtendTime: uint32;
    duration: uint32;
}

struct Auction {
    config: Cell<AuctionConfig>;
    lastBid: Cell<LastBidInfo>?;
    minBid: coins;
    endTime: uint32;
}

struct LastBidInfo {
    bidderAddress: address;
    bidAmount: coins;
    bidTimestamp: uint32;
}

fun ItemStorageUninitialized.generateEmptyData(index: int, collectionAddress: address) {
    val emptyItemStorage: ItemStorageUninitialized = {
        config: ItemConfig { index, collectionAddress }.toCell(),
    };
    return emptyItemStorage.toCell()
}

fun Auction.createStartingFromNow(config: Cell<AuctionConfig>, minBid: coins, duration: int): Auction {
    return {
        config: config,
        lastBid: null,
        minBid: minBid,
        endTime: blockchain.now() + duration
    }
}
