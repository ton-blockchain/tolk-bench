import "@stdlib/tvm-dicts"

const SIZE_ADDRESS_HASH = 256;

type ExtensionsDict = dict;

struct Storage {
    isSignatureAllowed: bool;
    seqno: uint32;
    subwalletId: uint32;
    publicKey: uint256;
    extensions: ExtensionsDict;     // from address hash to true
}

fun Storage.load() {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}


fun ExtensionsDict.exists(self, addrHash: uint256) {
    var (_, extensionFound) = self.uDictGet(SIZE_ADDRESS_HASH, addrHash);
    return extensionFound;
}

fun ExtensionsDict.tryInsert(mutate self, addrHash: uint256) {
    // todo how to optimize it? need to achieve `b{1} PUSHSLICE`
    return self.uDictSetBuilderIfNotExists(SIZE_ADDRESS_HASH, addrHash, beginCell().storeBool(true));
}

fun ExtensionsDict.tryDelete(mutate self, addrHash: uint256) {
    return self.uDictDelete(SIZE_ADDRESS_HASH, addrHash);
}

