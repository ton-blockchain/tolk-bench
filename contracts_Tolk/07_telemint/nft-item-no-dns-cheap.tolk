import "@stdlib/gas-payments"

import "common.tolk"
import "storage.tolk"
import "messages.tolk"


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
    val auction = lazy auctionCell.load();
    val auctionState = lazy auction.state.load();
    if (blockchain.now() < auctionState.endTime) {
        return (myBalance, owner, auctionCell);
    }
    if (isExternal) {
        acceptExternalMessage();
    }
    // should end auction
    if (auctionState.lastBid == null) {
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
    var newMinBid: int = max(newBid + ton("1"), (newBid * (100 + auctionConfig.minBidStep) + 99) / 100);
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

fun onItemIsDeployingByCollection(myBalance: int, msg: TelemintItemDeploy): Cell<ItemState> {
    val auctionConfig = lazy msg.auctionConfig.load();
    var auction: Cell<Auction>? = Auction.createStartingFromNow(msg.auctionConfig, auctionConfig.minBid, auctionConfig.duration);
    var ownerAddress: address;

    (myBalance, auction) = processNewBid(myBalance, msg.bidderAddress, msg.bidAmount, auction);
    (myBalance, ownerAddress, auction) = maybeEndAuction(myBalance, createAddressNone(), auction, msg.royaltyParams, false);

    return ItemState {
        ownerAddress: ownerAddress,
        content: ItemContent{
            nftContent: msg.nftContent,
            dns: null,
            tokenInfo: msg.tokenInfo,
        }.toCell(),
        auction: auction,
        royaltyParams: msg.royaltyParams,
    }.toCell()
}

type AllowedMessageToItem =
    TelemintItemDeploy |
    MakeNewStakeOrTopUp |
    RequestRoyaltyParams |
    RequestStaticData |
    AskToStartAuction |
    AskToCancelAuction |
    AskToTransfer |
;

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

    var storage = ItemStorage.load();

    if (storage.state == null) {
        val itemConfig = lazy storage.config.load();
        assert (senderAddress == itemConfig.collectionAddress) throw ERR_UNINITED;

        val msg = TelemintItemDeploy.fromSlice(inMsgBody, {throwIfOpcodeDoesNotMatch: ERR_UNKNOWN_OP});
        storage.state = onItemIsDeployingByCollection(myBalance, msg);
        storage.save();
        return;
    }

    var state: ItemState = storage.state.load();

    if (state.auction != null) {
        myBalance -= msgValue;      // sender does not pay for auction with its message
        (myBalance, state.ownerAddress, state.auction) = maybeEndAuction(myBalance, state.ownerAddress, state.auction, state.royaltyParams, false);
        if (state.auction == null) {
            storage.state = state.toCell();
            storage.save();
        }
        myBalance += msgValue;
    }

    // treat an empty message like "stake" (with attached tons)
    if (inMsgBody.isEnd()) {
        inMsgBody = stringHexToSlice("00000000");
    }

    val msg = lazy AllowedMessageToItem.fromSlice(inMsgBody);

    match (msg) {
        MakeNewStakeOrTopUp => {
            // todo make a separate struct with opcode "00000000#topup"? (now the compiler doesn't allow > 64 bits)
            var isTopup = msg.comment.bitsEqual("#topup") & (msg.comment.remainingRefsCount() == 0);
            if (isTopup) {
                return;
            }

            if (state.auction == null) {
                // only owner can fill-up balance, prevent coins lost right after the auction
                // if owner send bid right after auction he can restore it by transfer response message
                assert(senderAddress == state.ownerAddress) throw ERR_FORBIDDEN_TOPUP;
                return;
            }
            (myBalance, state.auction) = processNewBid(myBalance, senderAddress, msgValue, state.auction);
            (myBalance, state.ownerAddress, state.auction) = maybeEndAuction(myBalance, state.ownerAddress, state.auction, state.royaltyParams, false);
            storage.state = state.toCell();
            storage.save();
        }

        RequestRoyaltyParams => {
            sendMsg(senderAddress, 0, OP_REPORT_ROYALTY_PARAMS, msg.queryId, beginCell().storeSlice(state.royaltyParams.beginParse()), 64); // carry all the remaining value of the inbound message
        }

        RequestStaticData => {
            val itemConfig = lazy storage.config.load();
            sendMsg(senderAddress, 0, OP_REPORT_STATIC_DATA, msg.queryId, beginCell().storeUint(itemConfig.index, 256).storeAddress(itemConfig.collectionAddress), 64); // carry all the remaining value of the inbound message
        }

        AskToStartAuction => {
            assert (state.auction == null) throw ERR_FORBIDDEN_NOT_STAKE;
            assert(senderAddress == state.ownerAddress) throw ERR_FORBIDDEN_AUCTION;

            val config = lazy msg.newAuctionConfig.load();
            assert(!config.isInvalid()) throw ERR_INVALID_AUCTION_CONFIG;

            state.auction = Auction.createStartingFromNow(msg.newAuctionConfig, config.minBid, config.duration);
            storage.state = state.toCell();
            storage.save();

            if (msg.queryId) {
                sendMsg(senderAddress, 0, OP_TELEITEM_OK, msg.queryId, null, 64); // carry all the remaining value of the inbound message
            }
        }

        AskToCancelAuction => {
            assert (state.auction != null) throw ERR_NO_AUCTION;
            assert (senderAddress == state.ownerAddress) throw ERR_FORBIDDEN_AUCTION;

            val loadedAuction = lazy state.auction.load();
            val auctionState = lazy loadedAuction.state.load();
            assert (auctionState.lastBid == null) throw ERR_ALREADY_HAS_STAKES;
            if (msg.queryId) {
                sendMsg(senderAddress, 0, OP_TELEITEM_OK, msg.queryId, null, 64); // carry all the remaining value of the inbound message
            }

            state.auction = null;
            storage.state = state.toCell();
            storage.save();
        }

        AskToTransfer => {
            assert (state.auction == null) throw ERR_FORBIDDEN_NOT_STAKE;
            assert(senderAddress == state.ownerAddress) throw ERR_FORBIDDEN_TRANSFER;
            assert(msg.newOwnerAddress.getWorkchain() == MY_WORKCHAIN) throw ERR_INCORRECT_WORKCHAIN;

            var restAmount: int = myBalance - cheap_min_tons_for_storage;
            if (msg.forwardAmount) {
                restAmount -= (msg.forwardAmount + fwdFee);
            }
            var needResponse = msg.sendExcessesTo.isInternal();
            if (needResponse) {
                assert(msg.sendExcessesTo.getWorkchain() == MY_WORKCHAIN) throw ERR_INCORRECT_WORKCHAIN;
                restAmount -= fwdFee;
            }

            assert(restAmount >= 0) throw ERR_NOT_ENOUGH_FUNDS; // base nft spends fixed amount of gas, will not check for response

            if (msg.forwardAmount) {
                sendMsg(msg.newOwnerAddress, msg.forwardAmount, OP_OWNERSHIP_ASSIGNED, msg.queryId,
                    beginCell().storeAddress(state.ownerAddress).storeSlice(msg.forwardPayload), 1); // paying fees, revert on errors

            }
            if (needResponse) {
                sendMsg(msg.sendExcessesTo, restAmount, OP_EXCESSES, msg.queryId, null, 1); // paying fees, revert on errors
            }

            state.ownerAddress = msg.newOwnerAddress;
            storage.state = state.toCell();
            storage.save();
        }

        TelemintItemDeploy => {
            val itemConfig = lazy storage.config.load();
            assert (senderAddress == itemConfig.collectionAddress) throw ERR_FORBIDDEN_NOT_DEPLOY;
            sendMsg(msg.bidderAddress, 0, OP_TELEITEM_RETURN_BID, blockchain.logicalTime(), null, 64); // carry all the remaining value of the inbound message
        }

        else => throw ERR_UNKNOWN_OP
    }
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
