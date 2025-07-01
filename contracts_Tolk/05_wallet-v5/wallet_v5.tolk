import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments"
import "errors"
import "c5-register-validation"


const SIZE_SIGNATURE = 512;
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


// -----------------
// handle extra actions

struct (0x02) AddExtensionExtraAction {
    addr: address;
}

struct (0x03) RemoveExtensionExtraAction {
    addr: address;
}

struct (0x04) SetSignatureAllowedExtraAction {
    allowSignature: bool;
}

type ExtraAction =
    AddExtensionExtraAction |
    RemoveExtensionExtraAction |
    SetSignatureAllowedExtraAction
;

// "extra actions" are represented in a snake format: "data".ref("data.ref("data"...))
type SnakedExtraActions = RemainingBitsAndRefs;

fun SnakedExtraActions.hasNext(self) {
    return self.remainingRefsCount()
}

fun SnakedExtraActions.getNext(self): SnakedExtraActions {
    return self.preloadRef().beginParse()
}

@inline_ref
fun processExtraActions(extraActions: SnakedExtraActions, isExtension: bool) {
    while (true) {
        val action = lazy ExtraAction.fromSlice(extraActions);
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
        if (!extraActions.hasNext()) {
            return;
        }
        extraActions = extraActions.getNext();
    }
}

fun processActions(outActions: OutActionsCell?, hasExtraActions: bool, extraActions: SnakedExtraActions, isExternal: bool, isExtension: bool) {
    if (outActions != null) {
        // Simply set the C5 register with all pre-computed actions after verification:
        setTvmRegisterC5(outActions.verifyC5Actions(isExternal));
    }
    if (hasExtraActions) {
        processExtraActions(extraActions, isExtension);
    }
}


// -----------------
// handle incoming messages (internal and external)

struct (0x6578746E) ExtensionActionRequest {
    queryId: uint64;
    outActions: OutActionsCell?;
    hasExtraActions: bool;
    extraActions: SnakedExtraActions;
}

struct (0x73696E74) InternalSignedRequest {
    walletId: uint32;
    validUntil: uint32;
    seqno: uint32;
    outActions: OutActionsCell?;
    hasExtraActions: bool;
    extraActions: SnakedExtraActions;
    // ends with a signature (512 bits), but it's parsed and compared separately
}

struct (0x7369676E) ExternalSignedRequest {
    walletId: uint32;
    validUntil: uint32;
    seqno: uint32;
    outActions: OutActionsCell?;
    hasExtraActions: bool;
    extraActions: SnakedExtraActions;
    // ends with a signature (512 bits), but it's parsed and compared separately
}

type AllowedMessageToWallet = ExtensionActionRequest | InternalSignedRequest;


fun onExternalMessage(inMsgBody: slice) {
    var signature = inMsgBody.getLastBits(SIZE_SIGNATURE);
    var signedSlice = inMsgBody.removeLastBits(SIZE_SIGNATURE);

    var msg = ExternalSignedRequest.fromSlice(signedSlice, {
        throwIfOpcodeDoesNotMatch: ERROR_INVALID_MESSAGE_OPERATION,
    });

    var storage = lazy Storage.load();

    assert (isSignatureValid(signedSlice.hash(), signature, storage.publicKey)) throw ERROR_INVALID_SIGNATURE;
    assert (storage.isSignatureAllowed | (storage.extensions == null)) throw ERROR_SIGNATURE_DISABLED;
    assert (msg.seqno == storage.seqno) throw ERROR_INVALID_SEQNO;
    assert (msg.walletId == storage.subwalletId) throw ERROR_INVALID_WALLET_ID;
    assert (msg.validUntil > blockchain.now()) throw ERROR_EXPIRED;

    acceptExternalMessage();

    // Store and commit the seqno increment to prevent replays even if the subsequent requests fail.
    storage.isSignatureAllowed = true;
    storage.seqno += 1;
    storage.save();

    commitContractDataAndActions();
    processActions(msg.outActions, msg.hasExtraActions, msg.extraActions, true, false);
}


fun onInternalMessage(inMsgFull: cell, inMsgBody: slice) {
    val msg = lazy AllowedMessageToWallet.fromSlice(inMsgBody);

    match (msg) {
        ExtensionActionRequest => {
            var inMsgFullSlice: slice = inMsgFull.beginParse();
            inMsgFullSlice.loadMessageFlags();
            val senderAddress = inMsgFullSlice.loadAddress();

            var (senderWorkchain, senderAddrHash) = senderAddress.getWorkchainAndHash();
            var myWorkchain = contract.getAddress().getWorkchain();
            if (myWorkchain != senderWorkchain) {
                return;
            }

            val storage = lazy Storage.load();
            if (!storage.extensions.exists(senderAddrHash)) {
                // Note that some random contract may have deposited funds with this prefix,
                // so we accept the funds silently instead of throwing an error (wallet v4 does the same).
                return;
            }

            processActions(msg.outActions, msg.hasExtraActions, msg.extraActions, false, true);
        }

        InternalSignedRequest => {
            val bodyLongEnough = inMsgBody.remainingBitsCount() >= SIZE_SIGNATURE + 128;
            if (!bodyLongEnough) {
                return;     // don't try to parse it (it will fail), just ignore
            }

            var signature = inMsgBody.getLastBits(SIZE_SIGNATURE);
            var signedSlice = inMsgBody.removeLastBits(SIZE_SIGNATURE);

            var storage = lazy Storage.load();
            if (!isSignatureValid(signedSlice.hash(), signature, storage.publicKey)) {
                return;
            }

            assert (storage.isSignatureAllowed | (storage.extensions == null)) throw ERROR_SIGNATURE_DISABLED;
            assert (msg.seqno == storage.seqno) throw ERROR_INVALID_SEQNO;
            assert (msg.walletId == storage.subwalletId) throw ERROR_INVALID_WALLET_ID;
            assert (msg.validUntil > blockchain.now()) throw ERROR_EXPIRED;

            // Store and commit the seqno increment to prevent replays even if the subsequent requests fail.
            storage.isSignatureAllowed = true;
            storage.seqno += 1;
            storage.save();

            processActions(msg.outActions, msg.hasExtraActions, msg.extraActions, false, false);
        }

        else => {
            // if opcode is strange or body is empty at all (for instance, bounced messages)
            // just ignore, do not throw
        }
    }
}


// -----------------
// getters of a contract

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
