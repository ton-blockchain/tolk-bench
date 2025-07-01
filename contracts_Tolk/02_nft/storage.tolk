// SnakeString describes a (potentially long) string inside a cell;
// short strings are stored as-is, like "my-picture.png";
// long strings are nested refs, like "xxxx".ref("yyyy".ref("zzzz"))
type SnakeString = slice;

fun SnakeString.unpackFromSlice(mutate s: slice) {
    // obviously, SnakeString can be only the last: it's just "the remainder";
    // for correctness, it's better to validate it has no more refs:
    // assert (s.remainingRefsCount() <= 1) throw 5;
    // but since here we're matching the original FunC implementation, leave no checks
    val snakeRemainder = s;
    s = createEmptySlice();     // no more left to read
    return snakeRemainder
}

fun SnakeString.packToBuilder(self, mutate b: builder) {
    b.storeSlice(self)
}


struct RoyaltyParams {
    numerator: uint16;
    denominator: uint16;
    royaltyAddress: address;
}

struct NftCollectionStorage {
    ownerAddress: address;
    nextItemIndex: uint64;
    content: Cell<CollectionContent>;
    nftItemCode: cell;
    royaltyParams: Cell<RoyaltyParams>;
}

struct CollectionContent {
    collectionMetadata: cell;
    commonContent: Cell<SnakeString>;
}

struct NftItemStorage {
    index: uint64;
    collectionAddress: address;
    ownerAddress: address;
    content: Cell<SnakeString>;
}

struct NftItemStorageNotInitialized {
    index: uint64;
    collectionAddress: address;
}

fun calcDeployedNftItem(index: uint64, collectionAddress: address, nftItemCode: cell): AutoDeployAddress {
    val emptyNftItemStorage: NftItemStorageNotInitialized = {
        index,
        collectionAddress,
    };

    return {
        stateInit: {
            code: nftItemCode,
            data: emptyNftItemStorage.toCell()
        }
    }
}
