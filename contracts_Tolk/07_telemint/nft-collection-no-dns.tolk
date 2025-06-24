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

fun slice.loadTextString(mutate self) : slice {
    val len = self.loadUint(8);
    val data = self.loadBits(len * 8);
    return data
}

struct DeployItemCmdAfterText {
    content: cell;
    auctionConfig: Cell<AuctionConfig>;
    royalty: Cell<RoyaltyParams>?;
    restrictions: Cell<Restrictions>?;
}

struct Restrictions {
    forceSenderAddress: address?;
    rewriteSenderAddress: address?;
}

const ERR_INVALID_SENDER_ADDRESS = 224;

@inline
fun checkRestrictions(restrictionsCell: Cell<Restrictions>?, senderAddress: address) : address {
    if (restrictionsCell != null) {
        val restrictions = restrictionsCell.load();
        if (restrictions.forceSenderAddress != null) {
            assert(senderAddress == restrictions.forceSenderAddress) throw ERR_INVALID_SENDER_ADDRESS;
        }
        if (restrictions.rewriteSenderAddress != null) {
            senderAddress = restrictions.rewriteSenderAddress;
        }
    }
    return senderAddress;
}

fun deployItem(senderAddress: address, bidAmount: coins, nftItemCode: cell, cmd: slice, fullDomain: slice, defaultRoyaltyParams: Cell<RoyaltyParams>) {
    val tokenName = cmd.loadTextString();
    val params = DeployItemCmdAfterText.fromSlice(cmd);
    senderAddress = checkRestrictions(params.restrictions, senderAddress);

    val auctionConfig = lazy params.auctionConfig.load();
    assert(bidAmount >= auctionConfig.minBid) throw ERR_NOT_ENOUGH_FUNDS;
    if (auctionConfig.isInvalid()) {
        sendMsg(senderAddress, 0, OP_TELEITEM_RETURN_BID, blockchain.logicalTime(), null, 64); // carry all the remaining value of the inbound message
        return;
    }

    var itemIndex: int = tokenName.bitsHash();
    var tokenInfo: cell = packTokenInfo(tokenName, fullDomain);

    val deployMsg = createMessage({
        bounce: true,
        dest: {
            workchain: MY_WORKCHAIN,
            stateInit: {
                code: nftItemCode,
                data: ItemStorage.generateEmptyData(itemIndex, contract.getAddress(), null)
            }
        },
        value: 0,
        body: TelemintItemDeploy {
            bidderAddress: senderAddress,
            bidAmount: bidAmount,
            tokenInfo: tokenInfo,
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

            deployItem(senderAddress, msgValue, storage.nftItemCode, input.cmd, storage.fullDomain.load().data, storage.royaltyParams);
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

get get_collection_data() : (bool, cell, address) {
    val storage = lazy CollectionStorage.load();
    return (true, storage.content, createAddressNone());
}

get get_nft_address_by_index(index: int) : address {
    val storage = lazy CollectionStorage.load();
    var stateInit = packItemStateInit(index, storage.nftItemCode);
    return calculateAddress(MY_WORKCHAIN, stateInit);
}

get get_nft_content(index: int, individualNftContent: cell) : cell {
    return individualNftContent;
}
