import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments"


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


const ERROR_SIGNATURE_DISABLED = 132;
const ERROR_INVALID_SEQNO = 133;
const ERROR_INVALID_WALLET_ID = 134;
const ERROR_INVALID_SIGNATURE = 135;
const ERROR_EXPIRED = 136;
const ERROR_EXTERNAL_SEND_MESSAGE_MUST_HAVE_IGNORE_ERRORS_SEND_MODE = 137;
const ERROR_INVALID_MESSAGE_OPERATION = 138;
const ERROR_ADD_EXTENSION = 139;
const ERROR_REMOVE_EXTENSION = 140;
const ERROR_UNSUPPORTED_ACTION = 141;
const ERROR_DISABLE_SIGNATURE_WHEN_EXTENSIONS_IS_EMPTY = 142;
const ERROR_THIS_SIGNATURE_MODE_ALREADY_SET = 143;
const ERROR_REMOVE_LAST_EXTENSION_WHEN_SIGNATURE_DISABLED = 144;
const ERROR_EXTENSION_WRONG_WORKCHAIN = 145;
const ERROR_ONLY_EXTENSION_CAN_CHANGE_SIGNATURE_MODE = 146;
const ERROR_INVALID_C5 = 147;

const SIZE_BOOL = 1;
const SIZE_SEQNO = 32;
const SIZE_WALLET_ID = 32;
const SIZE_PUBLIC_KEY = 256;
const SIZE_VALID_UNTIL = 32;
const SIZE_MESSAGE_FLAGS = 4;
const SIZE_SIGNATURE = 512;
const SIZE_MESSAGE_OPERATION_PREFIX = 32;
const SIZE_ADDRESS_HASH = 256;
const SIZE_QUERY_ID = 64;

const `prefix::signed_external` = 0x7369676E;
const `prefix::signed_internal` = 0x73696E74;
const `prefix::extension_action` = 0x6578746E;

/// returns the number of trailing zeroes in slice s.
@pure
fun countTrailingZeroes(s: slice): int
    asm "SDCNTTRAIL0";

// `action_send_msg` has 0x0ec3c86d prefix
// https://github.com/ton-blockchain/ton/blob/5c392e0f2d946877bb79a09ed35068f7b0bd333a/crypto/block/block.tlb#L380
fun slice.enforceAndRemoveActionSendMsgPrefix(self): slice
    asm "x{0ec3c86d} SDBEGINS";

/// put raw list of OutActions to C5 register.
/// OutList TLB-schema - https://github.com/ton-blockchain/ton/blob/5c392e0f2d946877bb79a09ed35068f7b0bd333a/crypto/block/block.tlb#L378
/// C5 register - https://docs.ton.org/tvm.pdf, page 11
fun setC5Actions(actionList: cell): void
    asm "c5 POP";

/// transforms an ordinary or exotic cell into a Slice, as if it were an ordinary cell. A flag is returned indicating whether c is exotic. If that be the case, its type can later be deserialized from the first eight bits of s.
@pure
fun cell.beginParseRaw(self): (slice, int)
    asm "XCTOS";

@inline
fun cell.verifyC5Actions(self, isExternal: bool): cell {
  // XCTOS doesn't automatically load exotic cells (unlike CTOS `begin_parse`).
  // we use it in `verify_c5_actions` because during action phase processing exotic cells in c5 won't be unfolded too.
  // exotic cell starts with 0x02, 0x03 or 0x04 so it will not pass action_send_msg prefix check
  var (cs: slice, _) = self.beginParseRaw();

  var count: int = 0;

  while (!cs.isEnd()) {
    // only `action_send_msg` is allowed; `action_set_code`, `action_reserve_currency` or `action_change_library` are not.
    cs = cs.enforceAndRemoveActionSendMsgPrefix();

    assert(cs.remainingBitsCount() == 8) throw ERROR_INVALID_C5; // send_mode
    assert(cs.remainingRefsCount() == 2) throw ERROR_INVALID_C5; // next-action-ref and MessageRelaxed ref

    // enforce that send_mode has +2 bit (ignore errors) set for external message.
    // if such send_mode is not set and sending fails at the action phase (for example due to insufficient balance) then the seqno will not be increased and the external message will be processed again and again.

    // action_send_msg#0ec3c86d mode:(## 8) out_msg:^(MessageRelaxed Any) = OutAction;
    // https://github.com/ton-blockchain/ton/blob/5c392e0f2d946877bb79a09ed35068f7b0bd333a/crypto/block/block.tlb#L380
    // load 7 bits and make sure that they end with 1
    assert(!(isExternal & (countTrailingZeroes(cs.preloadBits(7)) > 0))) throw ERROR_EXTERNAL_SEND_MESSAGE_MUST_HAVE_IGNORE_ERRORS_SEND_MODE;

    (cs, _) = cs.preloadRef().beginParseRaw();
    count += 1;
  }
  assert(count <= 255) throw ERROR_INVALID_C5;
  assert(cs.remainingRefsCount() == 0) throw ERROR_INVALID_C5;

  return self;
}

struct(0x02) AddExtensionExtraAction {
    addr: address;
}

struct(0x03) RemoveExtensionExtraAction {
    addr: address;
}

struct(0x04) SetSignatureAllowedExtraAction{
    allowSignature: bool;
}

type ExtraAction =
    AddExtensionExtraAction |
    RemoveExtensionExtraAction |
    SetSignatureAllowedExtraAction
;

@inline_ref
fun processActions(cs: slice, isExternal: bool, isExtension: bool) {
    var c5Actions = cs.loadMaybeRef();
    if (c5Actions != null) {
        // Simply set the C5 register with all pre-computed actions after verification:
        setC5Actions(c5Actions.verifyC5Actions(isExternal));
    }
    val hasOtherActions = cs.loadBool();
    if (!hasOtherActions) {
        return;
    }

    // Loop extended actions
    while (true) {
        val action = lazy ExtraAction.fromSlice(cs);
        match (action) {
            AddExtensionExtraAction => {
                var (extensionWorkchain, extensionAddrHash) = action.addr.getWorkchainAndHash();
                var myWorkchain = contract.getAddress().getWorkchain();
                assert (myWorkchain == extensionWorkchain) throw ERROR_EXTENSION_WRONG_WORKCHAIN;

                var storage = lazy Storage.load();
                val inserted = storage.extensions.tryInsert(extensionAddrHash);
                assert (inserted) throw ERROR_ADD_EXTENSION;
                storage.save();
            }

            RemoveExtensionExtraAction => {
                var (extensionWorkchain, extensionAddrHash) = action.addr.getWorkchainAndHash();
                var myWorkchain = contract.getAddress().getWorkchain();
                assert (myWorkchain == extensionWorkchain) throw ERROR_EXTENSION_WRONG_WORKCHAIN;

                var storage = lazy Storage.load();
                val removed = storage.extensions.tryDelete(extensionAddrHash);
                assert (removed) throw ERROR_REMOVE_EXTENSION;
                if (!storage.isSignatureAllowed) {
                    assert (storage.extensions != null) throw ERROR_REMOVE_LAST_EXTENSION_WHEN_SIGNATURE_DISABLED;
                }
                storage.save();
            }

            SetSignatureAllowedExtraAction => {
                assert (isExtension) throw ERROR_ONLY_EXTENSION_CAN_CHANGE_SIGNATURE_MODE;

                var storage = lazy Storage.load();
                assert (storage.isSignatureAllowed != action.allowSignature) throw ERROR_THIS_SIGNATURE_MODE_ALREADY_SET;
                if (!action.allowSignature) {
                    assert (storage.extensions != null) throw ERROR_DISABLE_SIGNATURE_WHEN_EXTENSIONS_IS_EMPTY;
                }
                storage.isSignatureAllowed = action.allowSignature;
                storage.save();
            }

            else => throw ERROR_UNSUPPORTED_ACTION
        }
        if (!cs.remainingRefsCount()) {
            return;
        }
        cs = cs.preloadRef().beginParse();
    }
}

// ------------------------------------------------------------------------------------------------

@inline
fun processSignedRequest(inMsgBody: slice, isExternal: bool) {
  var signature: slice = inMsgBody.getLastBits(SIZE_SIGNATURE);
  var signedSlice: slice = inMsgBody.removeLastBits(SIZE_SIGNATURE);

  var cs: slice = signedSlice;
  cs.skipBits(SIZE_MESSAGE_OPERATION_PREFIX); // skip signed_internal or signed_external prefix
  var (walletId: int, validUntil: int, seqno: int) = (cs.loadUint(SIZE_WALLET_ID), cs.loadUint(SIZE_VALID_UNTIL), cs.loadUint(SIZE_SEQNO));

  var storage = lazy Storage.load();

  var isSignatureValid = isSignatureValid(signedSlice.hash(), signature, storage.publicKey);
  if (!isSignatureValid) {
    if (isExternal) {
      throw ERROR_INVALID_SIGNATURE;
    } else {
      return;
    }
  }

  assert (storage.isSignatureAllowed | (storage.extensions == null)) throw ERROR_SIGNATURE_DISABLED;
  assert (seqno == storage.seqno) throw ERROR_INVALID_SEQNO;
  assert (walletId == storage.subwalletId) throw ERROR_INVALID_WALLET_ID;
  assert (validUntil > blockchain.now()) throw ERROR_EXPIRED;

  if (isExternal) {
    acceptExternalMessage();
  }

  // Store and commit the seqno increment to prevent replays even if the subsequent requests fail.
  storage.isSignatureAllowed = true;
  storage.seqno += 1;
  storage.save();

  if (isExternal) {
    commitContractDataAndActions();
  }

  processActions(cs, isExternal, false);
}

@inline
fun onExternalMessage(inMsgBody: slice) {
  assert(inMsgBody.preloadUint(SIZE_MESSAGE_OPERATION_PREFIX) == `prefix::signed_external`) throw ERROR_INVALID_MESSAGE_OPERATION;
  processSignedRequest(inMsgBody, true);
}

// ------------------------------------------------------------------------------------------------

@inline
fun onInternalMessage(inMsgFull: cell, inMsgBody: slice) {
  if (inMsgBody.remainingBitsCount() < SIZE_MESSAGE_OPERATION_PREFIX) {
    return;
  }
  var op: int = inMsgBody.preloadUint(SIZE_MESSAGE_OPERATION_PREFIX);
  if ((op != `prefix::extension_action`) & (op != `prefix::signed_internal`)) {
    return;
  }

  // bounded messages has 0xffffff prefix and skipped by op check

  if (op == `prefix::extension_action`) {
    inMsgBody.skipBits(SIZE_MESSAGE_OPERATION_PREFIX);

    var inMsgFullSlice: slice = inMsgFull.beginParse();
    inMsgFullSlice.skipBits(SIZE_MESSAGE_FLAGS);
    // Authenticate extension by its address.
    var (senderWorkchain: int, senderAddrHash: int) = inMsgFullSlice.loadAddress().getWorkchainAndHash();
    var myWorkchain = contract.getAddress().getWorkchain();
    if (myWorkchain != senderWorkchain) {
      return;
    }

      val storage = lazy Storage.load();

    // Note that some random contract may have deposited funds with this prefix,
    // so we accept the funds silently instead of throwing an error (wallet v4 does the same).
    if (!storage.extensions.exists(senderAddrHash)) {
      return;
    }

    inMsgBody.skipBits(SIZE_QUERY_ID); // skip query_id

    processActions(inMsgBody, false, true);
    return;

  }

  // Additional check to make sure that there are enough bits for reading before signature check
  if (inMsgBody.remainingBitsCount() < SIZE_MESSAGE_OPERATION_PREFIX + SIZE_WALLET_ID + SIZE_VALID_UNTIL + SIZE_SEQNO + SIZE_SIGNATURE) {
    return;
  }
  processSignedRequest(inMsgBody, false);
}



get is_signature_allowed(): bool {
    val storage = lazy Storage.load();
    return storage.isSignatureAllowed;
}

get seqno(): int {
    val storage = lazy Storage.load();
    return storage.seqno;
}

get get_subwallet_id(): int {
    val storage = lazy Storage.load();
    return storage.subwalletId;
}

get get_public_key(): int {
    val storage = lazy Storage.load();
    return storage.publicKey;
}

// Returns raw dictionary (or null if empty) where keys are address hashes. Workchains of extensions are same with wallet smart contract workchain
get get_extensions(): dict {
    val storage = lazy Storage.load();
    return storage.extensions;
}
