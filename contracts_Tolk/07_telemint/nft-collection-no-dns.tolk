import "@stdlib/gas-payments"

import "common.tolk"
import "storage.tolk"
import "messages.tolk"

fun CollectionStorage.load() {
    return CollectionStorage.fromCell(contract.getData())
}

fun CollectionStorage.save(self) {
    contract.setData(self.toCell())
}

fun checkRestrictions(restrictions: OverrideRestrictionsAtDeploy, senderAddress: address) : address {
    if (restrictions.forceSenderAddress != null) {
        assert(senderAddress == restrictions.forceSenderAddress) throw ERR_INVALID_SENDER_ADDRESS;
    }
    if (restrictions.rewriteSenderAddress != null) {
        senderAddress = restrictions.rewriteSenderAddress;
    }
    return senderAddress;
}

fun deployItem(senderAddress: address, bidAmount: coins, nftItemCode: cell, params: SignedDataAtDeploy, fullDomain: TelegramString, defaultRoyaltyParams: Cell<RoyaltyParams>) {
    if (params.restrictions != null) {
        senderAddress = checkRestrictions(params.restrictions.load(), senderAddress);
    }

    val auctionConfig = lazy params.auctionConfig.load();
    assert(bidAmount >= auctionConfig.minBid) throw ERR_NOT_ENOUGH_FUNDS;
    if (auctionConfig.isInvalid()) {
        val returnBidMsg = createMessage({
            bounce: false,
            dest: senderAddress,
            value: 0,
            body: ReturnBidBackToBidder{}
        });
        returnBidMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        return;
    }

    var itemIndex: int = (params.tokenName as slice).bitsHash();

    val deployMsg = createMessage({
        bounce: true,
        dest: {
            workchain: MY_WORKCHAIN,
            stateInit: {
                code: nftItemCode,
                data: ItemStorageUninitialized.generateEmptyData(itemIndex, contract.getAddress())
            }
        },
        value: 0,
        body: TelemintItemDeploy {
            bidderAddress: senderAddress,
            bidAmount: bidAmount,
            tokenInfo: TokenNameAndDomain { tokenName: params.tokenName, domain: fullDomain }.toCell(),
            nftContent: params.content,
            auctionConfig: params.auctionConfig,
            royaltyParams: params.royalty != null ? params.royalty : defaultRoyaltyParams,
        }
    });
    deployMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

type AllowedMessageForCollection = TopUp | AskToDeployItem;

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    if (flags & 1) {
        // ignore all bounced messages
        return;
    }
    var senderAddress = cs.loadAddress();

    assert(!inMsgBody.isEnd()) throw ERR_WRONG_TOPUP_COMMENT;

    val msg = lazy AllowedMessageForCollection.fromSlice(inMsgBody);

    match (msg) {
        TopUp => {
            // NB: it is not possible to recover any money transferred to this account
            // so we return back all transfers except ones with comment #topup in it
            assert(msg.comment.bitsEqual("#topup") & (msg.comment.remainingRefsCount() == 0)) throw ERR_WRONG_TOPUP_COMMENT;
        }

        AskToDeployItem => {
            val storage = lazy CollectionStorage.load();
            val hash = msg.signedData.hash();
            assert(isSignatureValid(hash, msg.signature as slice, storage.publicKey)) throw ERR_INVALID_SIGNATURE;

            val input = lazy SignedDataAtDeploy.fromSlice(msg.signedData);
            assert(storage.subwalletId == input.subwalletId) throw ERR_WRONG_SUBWALLET_ID;
            var now = blockchain.now();
            assert(input.validSince < now) throw ERR_NOT_YET_VALID_SIGNATURE;
            assert(now < input.validTill) throw ERR_EXPIRED_SIGNATURE;

            deployItem(senderAddress, msgValue, storage.nftItemCode, input, storage.fullDomain.load(), storage.royaltyParams);
        }

        else => throw ERR_UNKNOWN_OP
    }
}

fun onExternalMessage(inMsg: slice) {
    var storage = lazy CollectionStorage.load();
    assert(!storage.isCollectionInitialized) throw ERR_FORBIDDEN_TOUCH;
    acceptExternalMessage();
    storage.isCollectionInitialized = true;
    storage.save();
}

// Get methods

// todo make such built-in function?
fun StateInit.generateCellCodeData(code: cell, data: cell): cell asm (data code) """
    NEWC
    b{00} STSLICECONST      // no fixedPrefixLength, no tickTock
    STOPTREF                // code
    STOPTREF                // data
    b{0} STSLICECONST       // no library
    ENDC
""";

fun buildAddressOfNftItem(itemIndex: int, collectionAddress: address, nftItemCode: cell): builder {
    val stateInitCell = StateInit.generateCellCodeData(
        nftItemCode,
        ItemStorageUninitialized.generateEmptyData(itemIndex, collectionAddress)
    );
    // todo manual work, how to better avoid it? (it's important to leave builder here)
    return beginCell()
        .storeUint(0b100, 3)
        .storeUint(BASECHAIN, 8)
        .storeUint(stateInitCell.hash(), 256)
}

get get_collection_data() : (bool, cell, address) {
    val storage = lazy CollectionStorage.load();
    return (true, storage.content, createAddressNone());
}

get get_nft_address_by_index(index: int) : address {
    val storage = lazy CollectionStorage.load();
    val addrBuilt = buildAddressOfNftItem(index, contract.getAddress(), storage.nftItemCode);
    return address.fromValidBuilder(addrBuilt);
}

get get_nft_content(index: int, individualNftContent: cell) : cell {
    return individualNftContent;
}
