import "gas"
import "op-codes"

const STATUS_SIZE = 4;

const MSG_INFO_REST_BITS = 1 + 4 + 4 + 64 + 32;


const MSG_WITH_STATE_INIT_AND_BODY_SIZE = MSG_INFO_REST_BITS + 1 + 1 + 1;
const MSG_HAVE_STATE_INIT = 4;
const MSG_STATE_INIT_IN_REF = 2;
const MSG_BODY_IN_REF = 1;

// if no StateInit:
// 0b0 for `Maybe (Either StateInit ^StateInit)` and 0b1 or 0b0 for `body:(Either X ^X)`

const MSG_ONLY_BODY_SIZE = MSG_INFO_REST_BITS + 1 + 1;


@inline
fun packJettonWalletDataBuilder(status: int, balance: int, ownerAddress: address, jettonMasterAddress: address): builder {
    return beginCell()
        .storeUint(status, STATUS_SIZE)
        .storeCoins(balance)
        .storeAddress(ownerAddress)
        .storeAddress(jettonMasterAddress);
}

@inline
fun packJettonWalletData(status: int, balance: int, ownerAddress: address, jettonMasterAddress: address): cell {
    return packJettonWalletDataBuilder(status, balance, ownerAddress, jettonMasterAddress)
           .endCell();
}

@inline
fun calculateJettonWalletStateInit(ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell): cell {
    /*
    https://github.com/ton-blockchain/ton/blob/8a9ff339927b22b72819c5125428b70c406da631/crypto/block/block.tlb#L144
    _ split_depth:(Maybe (## 5)) special:(Maybe TickTock)
    code:(Maybe ^Cell) data:(Maybe ^Cell)
    library:(Maybe ^Cell) = StateInit;
  */
    return beginCell()
    .storeUint(0, 2) // 0b00 - No split_depth; No special
    .storeMaybeRef(jettonWalletCode)
    .storeMaybeRef(
        packJettonWalletData(
            0, // status
            0, // balance
            ownerAddress,
            jettonMasterAddress)
    )
    .storeUint(0, 1) // Empty libraries
    .endCell();
}

@inline
fun calculateJettonWalletAddress(stateInit: cell): address {
    /*
    https://github.com/ton-blockchain/ton/blob/8a9ff339927b22b72819c5125428b70c406da631/crypto/block/block.tlb#L105
    addr_std$10 anycast:(Maybe Anycast) workchain_id:int8 address:bits256  = MsgAddressInt;
    */
    return beginCell()
    .storeUint(4, 3) // 0b100 = addr_std$10 tag; No anycast
    .storeInt(MY_WORKCHAIN, 8)
    .storeUint(stateInit.hash(), 256)
    .endCell()
    .beginParse() as address;
}

@inline
fun calculateUserJettonWalletAddress(ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell): address {
    return calculateJettonWalletAddress(calculateJettonWalletStateInit(ownerAddress, jettonMasterAddress, jettonWalletCode));
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


// store msg_flags and address none
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
    var fwdFee: int = self.loadCoins();
    return fwdFee;
}
