import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments"
import "errors"
import "c5-register-validation"


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
    assert (!isExternal) throw ERROR_INVALID_SIGNATURE;
    return;
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
