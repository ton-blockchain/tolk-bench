import "workchain.tolk"
import "op-codes.tolk"

const SHARD_DEPTH = 8;

const MSG_WITH_STATE_INIT_AND_BODY_SIZE = MSG_INFO_REST_BITS + 1 + 1 + 1;
const MSG_HAVE_STATE_INIT = 4;
const MSG_STATE_INIT_IN_REF = 2;
const MSG_BODY_IN_REF = 1;

// if no StateInit:
// 0b0 for `Maybe (Either StateInit ^StateInit)` and 0b1 or 0b0 for `body:(Either X ^X)`

const MSG_INFO_REST_BITS = 1 + 4 + 4 + 64 + 32;

const MSG_ONLY_BODY_SIZE = MSG_INFO_REST_BITS + 1 + 1;

@inline
fun packJettonWalletData(balance: int, ownerAddress: address, jettonMasterAddress: address): cell {
    return beginCell()
        .storeCoins(balance)
        .storeAddress(ownerAddress)
        .storeAddress(jettonMasterAddress)
        .endCell();
}

@inline
fun getAddressShardPrefix(address: address): int {
    /*
    https://github.com/ton-blockchain/ton/blob/8a9ff339927b22b72819c5125428b70c406da631/crypto/block/block.tlb#L105
    addr_std$10 anycast:(Maybe Anycast) workchain_id:int8 address:bits256  = MsgAddressInt;
    */
    (address as slice).skipBits(3 + 8); // skip $10 anycast:(Maybe Anycast) workchain_id:int8
    return (address as slice).preloadUint(SHARD_DEPTH);
}

@inline
fun calculateJettonWalletStateInit(ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell): cell {
    /*
    https://github.com/ton-blockchain/ton/blob/26761a1d139402ef343081810677d2582c3eff51/crypto/block/block.tlb#L144
    _ fixed_prefix_length:(Maybe (## 5)) special:(Maybe TickTock)
    code:(Maybe ^Cell) data:(Maybe ^Cell)
    library:(Maybe ^Cell) = StateInit;
  */
    return beginCell()
        .storeUint(1, 1) // ;; Use fixed_prefix_length;
        .storeUint(SHARD_DEPTH, 5)
        .storeUint(0, 1) //  No special
        .storeMaybeRef(jettonWalletCode)
        .storeMaybeRef(
            packJettonWalletData(
                0, // balance
                ownerAddress,
                jettonMasterAddress)
        )
        .storeUint(0, 1) // Empty libraries
        .endCell();
}

@inline
fun calculateJettonWalletAddress(shardPrefix: int, stateInit: cell): address {
    /*
    https://github.com/ton-blockchain/ton/blob/8a9ff339927b22b72819c5125428b70c406da631/crypto/block/block.tlb#L105
    addr_std$10 anycast:(Maybe Anycast) workchain_id:int8 address:bits256  = MsgAddressInt;
    */
    var mask: int = (1 << (256 - SHARD_DEPTH)) - 1;
    var prefixLess: int = stateInit.hash() & mask;

    return beginCell()
        .storeUint(4, 3) // 0b100 = addr_std$10 tag; No anycast
        .storeInt(MY_WORKCHAIN, 8)
        .storeUint(shardPrefix, SHARD_DEPTH)
        .storeUint(prefixLess, 256 - SHARD_DEPTH)
        .endCell()
        .beginParse() as address;
}

@inline
fun calculateUserJettonWalletAddress(ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell): address {
    var shardPrefix: int = getAddressShardPrefix(ownerAddress);
    return calculateJettonWalletAddress(shardPrefix, calculateJettonWalletStateInit(ownerAddress, jettonMasterAddress, jettonWalletCode));
}

@inline
fun checkEitherForwardPayload(s: slice) {
    if (s.preloadUint(1)) {
        // forward_payload in ref
        var (remainBits: int, remainRefs: int) = s.remainingBitsAndRefsCount();
        assert((remainRefs == 1) & (remainBits == 1)) throw ERROR_INVALID_MESSAGE; // we check that there is no excess in the slice
    }
    // else forward_payload in slice - arbitrary bits and refs
}

@inline
fun builder.storeMsgFlagsAndAddressNone(mutate self, msgFlags: int): self {
    return self.storeUint(msgFlags, 6);
}

@inline
fun builder.storeStatinitRefAndBodyRef(mutate self, stateInit: cell, body: cell): self {
    return self
        .storeUint(MSG_HAVE_STATE_INIT + MSG_STATE_INIT_IN_REF + MSG_BODY_IN_REF, MSG_WITH_STATE_INIT_AND_BODY_SIZE)
        .storeRef(stateInit)
        .storeRef(body);
}

@inline
fun builder.storeOnlyBodyRef(mutate self, body: cell): self {
    return self
        .storeUint(MSG_BODY_IN_REF, MSG_ONLY_BODY_SIZE)
        .storeRef(body);
}

@inline
fun builder.storePrefixOnlyBody(mutate self): self {
    return self
        .storeUint(0, MSG_ONLY_BODY_SIZE);
}

// parse after sender_address
@inline
fun slice.retrieveFwdFee(mutate self): coins {
    self.loadAddress(); // skip dst
    self.loadCoins(); // skip value
    self.skipDict(); // skip extracurrency collection
    self.loadCoins(); // skip ihr_fee
    var fwdFee: coins = self.loadCoins();
    return fwdFee;
}
