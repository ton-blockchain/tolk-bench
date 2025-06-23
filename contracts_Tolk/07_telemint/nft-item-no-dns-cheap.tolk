import "@stdlib/gas-payments"

import "common.tolk"
import "storage.tolk"

const cheap_min_tons_for_storage = 30000000; // 0.03 TON
const cheap_minting_price = 30000000; // 0.03 TON

fun ItemStorage.load() {
    return ItemStorage.fromCell(contract.getData())
}

fun ItemStorage.save(self) {
    contract.setData(self.toCell())
}

fun sendMoney(myBalance: int, address: address, value: int): int {
    var amountToSend: int = min(myBalance - cheap_min_tons_for_storage, value);
    if (amountToSend > 0) {
        sendMsg(address, amountToSend, OP_FILL_UP, blockchain.logicalTime(), null, 2); // ignore errors
        myBalance -= amountToSend;
    }
    return myBalance;
}

fun maybeEndAuction(myBalance: int, owner: address, auctionCell: Cell<Auction>, royaltyParamsCell: Cell<RoyaltyParams>, isExternal: bool): (int, address, Cell<Auction>?) {
    val auction = auctionCell.load();
    val auctionState = lazy auction.state.load();
    if (blockchain.now() < auctionState.endTime) {
        return (myBalance, owner, auctionCell as Cell<Auction>);
    }
    if (isExternal) {
        acceptExternalMessage();
    }
    // should end auction
    if ((auctionState.lastBid == null)) {
        // no stakes were made
        // NB: owner is not null now
        return (myBalance, owner, null);
    }
    val auctionConfig = lazy auction.config.load();
    var lastBid = lazy auctionState.lastBid.load();
    val royaltyParams = lazy royaltyParamsCell.load();

    sendMsg(lastBid.bidderAddress, 0, OP_OWNERSHIP_ASSIGNED, blockchain.logicalTime(),
            beginCell()
                    .storeAddress(owner)
                    .storeInt(0, 1)
                    .storeUint(OP_TELEITEM_BID_INFO, 32)
                    .storeCoins(lastBid.bidAmount)
                    .storeUint(lastBid.bidTimestamp, 32),
            1); // paying fees, revert on errors

    if ((royaltyParams.royaltyFactor > 0) & (royaltyParams.royaltyBase > 0) & (royaltyParams.address != auctionConfig.benificiaryAddress)) {
        var royaltyValue: int = min(lastBid.bidAmount, mulDivFloor(lastBid.bidAmount, royaltyParams.royaltyFactor, royaltyParams.royaltyBase));
        lastBid.bidAmount -= royaltyValue;
        myBalance = sendMoney(myBalance, royaltyParams.address, royaltyValue);
    }

    myBalance = sendMoney(myBalance, auctionConfig.benificiaryAddress, lastBid.bidAmount);

    return (myBalance, lastBid.bidderAddress, null);
}

fun processNewBid(myBalance: int, newBidAddress: address, newBid: int, auctionCell: Cell<Auction>): (int, Cell<Auction>) {
    val auction = lazy auctionCell.load();
    val auctionState = lazy auction.state.load();
    assert(newBid >= auctionState.minBid) throw ERR_TOO_SMALL_STAKE;
    val auctionConfig = lazy auction.config.load();
    val newLastBid = LastBidInfo {
        bidderAddress: newBidAddress,
        bidAmount: newBid,
        bidTimestamp: blockchain.now(),
    }.toCell();
    var newEndTime: int = max(auctionState.endTime, blockchain.now() + auctionConfig.minExtendTime);
    if ((auctionConfig.maxBid > 0) & (newBid >= auctionConfig.maxBid)) {
        // for maybe_end_auction
        newEndTime = 0;
    }
    // step is at least GR$1
    var newMinBid: int = max(newBid + one_ton, (newBid * (100 + auctionConfig.minBidStep) + 99) / 100);
    if (auctionState.lastBid != null) {
        val lastBid = lazy auctionState.lastBid.load();
        var toSend: int = min(myBalance - cheap_min_tons_for_storage, lastBid.bidAmount);
        if (toSend > 0) {
            sendMsg(lastBid.bidderAddress, toSend, OP_OUTBID_NOTIFICATION, blockchain.logicalTime(), null, 1);
            myBalance -= toSend;
        }
    }
    return (myBalance, Auction {
        config: auction.config,
        state: AuctionState {
            lastBid: newLastBid,
            minBid: newMinBid,
            endTime: newEndTime,
        }.toCell()
    }.toCell());
}

fun prepareAuction(auctionConfigCell: Cell<AuctionConfig>): Cell<Auction>? {
    val config = lazy auctionConfigCell.load();
    if ((config.minBid < cheap_min_tons_for_storage + cheap_minting_price) | ((config.maxBid != 0) & (config.maxBid < config.minBid)) |
        (config.minBidStep <= 0) | (config.minExtendTime > 60 * 60 * 24 * 7) | (config.duration > 60 * 60 * 24 * 365)) {
        return null;
    }

    return Auction {
        config: auctionConfigCell,
        state: AuctionState {
            lastBid: null,
            minBid: config.minBid,
            endTime: blockchain.now() + config.duration
        }.toCell()
    }.toCell()
}

fun deployItem(myBalance: int, msg: slice): Cell<ItemState>? {
    // Do not throw errors here!
    var (bidderAddress: address, bid: int, tokenInfo: cell, nftContent: cell, auctionConfig: cell, royaltyParams: cell) = unpackTeleitemMsgDeploy(msg);
    var auction = prepareAuction(auctionConfig as Cell<AuctionConfig>);
    if (auction == null) {
        return null;
    }
    var (myBalance redef, newAuction: Cell<Auction>?) = processNewBid(myBalance, bidderAddress, bid, auction);
    var (myBalance redef, owner: address, newAuction redef) = maybeEndAuction(myBalance, createAddressNone(), newAuction, royaltyParams as Cell<RoyaltyParams>, false);
    var content: Cell<ItemContent> = ItemContent{
        nftContent: nftContent,
        dns: null,
        tokenInfo: tokenInfo,
    }.toCell();

    return ItemState {
        ownerAddress: owner,
        content: content,
        auction: newAuction,
        royaltyParams: royaltyParams as Cell<RoyaltyParams>,
    }.toCell()
}

@inline
fun transferOwnership(myBalance: int, ownerAddress: address, inMsgBody: slice, fwdFees: int): address {
    var (queryId: int, newOwnerAddress: address, responseDestination: address, customPayload: cell?, forwardAmount: int, forwardPayload: slice)
            = unpackNftCmdTransfer(inMsgBody);

    forceChain(newOwnerAddress);

    var restAmount: int = myBalance - cheap_min_tons_for_storage;
    if (forwardAmount) {
        restAmount -= (forwardAmount + fwdFees);
    }
    var needResponse = !responseDestination.isNone();
    if (needResponse) {
        restAmount -= fwdFees;
    }

    assert(restAmount >= 0) throw ERR_NOT_ENOUGH_FUNDS; // base nft spends fixed amount of gas, will not check for response

    if (forwardAmount) {
        sendMsg(newOwnerAddress, forwardAmount, OP_OWNERSHIP_ASSIGNED, queryId,
                beginCell().storeAddress(ownerAddress).storeSlice(forwardPayload), 1); // paying fees, revert on errors

    }
    if (needResponse) {
        forceChain(responseDestination);
        sendMsg(responseDestination, restAmount, OP_EXCESSES, queryId, null, 1); // paying fees, revert on errors
    }

    return newOwnerAddress;
}

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var myBalance: int = contract.getOriginalBalance();
    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    if (flags & 1) { // ignore all bounced messages
        return;
    }
    var senderAddress = cs.loadAddress();

    cs.loadAddress(); // skip dst
    cs.loadCoins(); // skip value
    cs.loadMaybeRef(); // skip extracurrency collection
    cs.loadCoins(); // skip ihr_fee
    var fwdFee: int = mulDivFloor(cs.loadCoins(), 3, 2); // we use message fwd_:fee for estimation of forward_payload costs

    var op: int = inMsgBody.isEnd() ? 0 : inMsgBody.loadUint(32);

    var storage = ItemStorage.load();
    val itemConfig = storage.config.load();

    if (itemConfig.collectionAddress.bitsEqual(senderAddress)) {
        assert(op == OP_TELEITEM_MSG_DEPLOY) throw ERR_FORBIDDEN_NOT_DEPLOY;
        if (storage.state == null) {
            var newState = deployItem(myBalance, inMsgBody);
            if (newState != null) {
                storage.state = newState;
                storage.save();
                return;
            }
        }
        var bidderAddress = inMsgBody.loadAddress(); // first field in teleitem_msg_deploy
        sendMsg(bidderAddress, 0, OP_TELEITEM_RETURN_BID, blockchain.logicalTime(), null, 64); // carry all the remaining value of the inbound message
        return;
    }

    assert(storage.state != null) throw ERR_UNINITED;
    var itemState: ItemState = storage.state.load();
    var auction = itemState.auction;
    var ownerAddress = itemState.ownerAddress;
    var content = itemState.content;
    var royaltyParams = itemState.royaltyParams;

    if (op == OP_GET_ROYALTY_PARAMS) {
        var queryId: int = inMsgBody.loadUint(64);
        sendMsg(senderAddress, 0, OP_REPORT_ROYALTY_PARAMS, queryId, beginCell().storeSlice(royaltyParams.beginParse()), 64); // carry all the remaining value of the inbound message
        return;
    }

    if (op == OP_NFT_CMD_GET_STATIC_DATA) {
        var queryId: int = inMsgBody.loadUint(64);
        sendMsg(senderAddress, 0, OP_REPORT_STATIC_DATA, queryId, beginCell().storeUint(itemConfig.index, 256).storeAddress(itemConfig.collectionAddress), 64); // carry all the remaining value of the inbound message
        return;
    }

    var isTopup = (op == 0) & inMsgBody.bitsEqual("#topup") & (inMsgBody.remainingRefsCount() == 0);
    if (isTopup) {
        return;
    }

    if (!(auction == null)) {
        // sender do not pay for auction with its message
        myBalance -= msgValue;
        (myBalance, ownerAddress, auction) = maybeEndAuction(myBalance, ownerAddress, auction, royaltyParams, false);
        if ((auction == null)) {
            storage.state = packItemState(ownerAddress, content, auction, royaltyParams);
            storage.save();
        }
        myBalance += msgValue;
    }

    if (op == OP_TELEITEM_CANCEL_AUCTION) {
        assert(auction != null) throw ERR_NO_AUCTION;
        assert(senderAddress == ownerAddress) throw ERR_FORBIDDEN_AUCTION;
        var queryId: int = inMsgBody.loadUint(64);
        val loadedAuction = lazy auction.load();
        val auctionState = lazy loadedAuction.state.load();
        assert(auctionState.lastBid == null) throw ERR_ALREADY_HAS_STAKES;
        if (queryId) {
            sendMsg(senderAddress, 0, OP_TELEITEM_OK, queryId, null, 64); // carry all the remaining value of the inbound message
        }
        storage.state = packItemState(ownerAddress, content, null, royaltyParams);
        storage.save();
        return;
    }

    if (!(auction == null)) {
        assert(op == 0) throw ERR_FORBIDDEN_NOT_STAKE;
        (myBalance, auction) = processNewBid(myBalance, senderAddress, msgValue, auction);
        (myBalance, ownerAddress, auction) = maybeEndAuction(myBalance, ownerAddress, auction, royaltyParams, false);
        storage.state = packItemState(ownerAddress, content, auction, royaltyParams);
        storage.save();
        return;
    }

    if (op == 0) {
        assert(senderAddress == ownerAddress) throw ERR_FORBIDDEN_TOPUP; // only owner can fill-up balance, prevent coins lost right after the auction
        // if owner send bid right after auction he can restore it by transfer response message
        return;
    }

    if (op == OP_TELEITEM_START_AUCTION) {
        assert(senderAddress == ownerAddress) throw ERR_FORBIDDEN_AUCTION;
        var queryId: int = inMsgBody.loadUint(64);
        var newAuctionConfig: cell = inMsgBody.loadRef();
        var newAuction = prepareAuction(newAuctionConfig as Cell<AuctionConfig>);
        assert(!((newAuction == null))) throw ERR_INVALID_AUCTION_CONFIG;
        if (queryId) {
            sendMsg(senderAddress, 0, OP_TELEITEM_OK, queryId, null, 64); // carry all the remaining value of the inbound message
        }
        storage.state = packItemState(ownerAddress, content, newAuction, royaltyParams);
        storage.save();
        return;
    }

    if (op == OP_NFT_CMD_TRANSFER) {
        assert(senderAddress.bitsEqual(ownerAddress)) throw ERR_FORBIDDEN_TRANSFER;
        var newOwnerAddress = transferOwnership(myBalance, ownerAddress, inMsgBody, fwdFee);
        storage.state = packItemState(newOwnerAddress, content, auction, royaltyParams);
        storage.save();
        return;
    }

    throw ERR_UNKNOWN_OP;
}

fun onExternalMessage(inMsg: slice) {
    var storage = lazy ItemStorage.load();
    var itemState = lazy storage.state!.load();
    var (myBalance, ownerAddress, auction) = maybeEndAuction(contract.getOriginalBalance(), itemState.ownerAddress, itemState.auction!, itemState.royaltyParams, true);
    itemState.auction = auction;
    itemState.ownerAddress = ownerAddress;
    storage.state = itemState.toCell();
    storage.save();
}

//
//  GET Methods
//

get get_nft_data(): (bool, int, address, address, cell?) {
    val storage = lazy ItemStorage.load();
    val itemConfig = lazy storage.config.load();
    if (storage.state == null) {
        return (false, itemConfig.index, itemConfig.collectionAddress, createAddressNone(), null);
    }
    val itemState = lazy storage.state.load();
    val itemContent = lazy itemState.content.load();
    return (true, itemConfig.index, itemConfig.collectionAddress, itemState.ownerAddress, itemContent.nftContent);
}

get get_telemint_token_name(): slice {
    val storage = lazy ItemStorage.load();
    val itemState = lazy storage.state!.load();
    val itemContent = lazy itemState.content.load();
    var (tokenName: slice, domain: slice) = unpackTokenInfo(itemContent.tokenInfo);
    return tokenName;
}

get get_telemint_auction_state(): (address?, int, int, int, int) {
    val storage = lazy ItemStorage.load();
    val itemState = lazy storage.state!.load();
    assert (itemState.auction != null) throw ERR_NO_AUCTION;

    val auction = itemState.auction.load();
    val auctionState = auction.state.load();
    var (bidderAddress: address?, bid: int, bidTs: int) = (null, 0, 0);
    if (auctionState.lastBid != null) {
        val lastBid = auctionState.lastBid.load();
        (bidderAddress, bid, bidTs) = (lastBid.bidderAddress, lastBid.bidAmount, lastBid.bidTimestamp);
    }
    return (bidderAddress, bid, bidTs, auctionState.minBid, auctionState.endTime);
}

get get_telemint_auction_config(): (address?, int, int, int, int, int) {
    val storage = lazy ItemStorage.load();
    val itemState = lazy storage.state!.load();     // in FunC, there was no check for null
    if (itemState.auction == null) {
        // Do not throw error, so it is easy to check if get_telemint_auction_config method exists
        return (null, 0, 0, 0, 0, 0);
    }

    val auction = lazy itemState.auction.load();
    val c = lazy auction.config.load();
    return (c.benificiaryAddress, c.minBid, c.maxBid, c.minBidStep, c.minExtendTime, c.duration);
}

get royalty_params(): RoyaltyParams {
    val storage = lazy ItemStorage.load();
    // todo with lazy, it does not work!!!
    val itemState = storage.state!.load();     // in FunC, there was no check for null
    return itemState.royaltyParams.load();
}
