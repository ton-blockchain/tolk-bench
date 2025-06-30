struct RoyaltyParams {
    numerator: uint16;
    denominator: uint16;
    royaltyAddress: address;
}

struct NftCollectionStorage {
    ownerAddress: address;
    nextItemIndex: uint64;
    content: cell;
    nftItemCode: cell;
    royaltyParams: Cell<RoyaltyParams>;
}

struct NftItemStorage {
    index: uint64;
    collectionAddress: address;
    ownerAddress: address;
    content: cell;
}

struct NftItemStorageUninitialized {
    index: uint64;
    collectionAddress: address;
}

fun calcDeployedNftItem(index: uint64, collectionAddress: address, nftItemCode: cell): AutoDeployAddress {
    val emptyNftItemStorage: NftItemStorageUninitialized = {
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
