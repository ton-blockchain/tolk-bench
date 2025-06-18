import "@stdlib/gas-payments"

import "common.tolk"

const cheap_min_tons_for_storage = 30000000; // 0.03 TON
const cheap_minting_price = 30000000; // 0.03 TON

fun sendMoney(myBalance: int, address: address, value: int): int {
    var amountToSend: int = min(myBalance - cheap_min_tons_for_storage, value);
    if (amountToSend > 0) {
        sendMsg(address, amountToSend, OP_FILL_UP, blockchain.logicalTime(), null, 2); // ignore errors
        myBalance -= amountToSend;
    }
    return myBalance;
}

fun maybeEndAuction(myBalance: int, owner: address, auction: cell, royaltyParams: cell, isExternal: int): (int, address, cell?) {
    var (auctionState: cell, auctionConfig: cell) = unpackAuction(auction);
    var (lastBid: cell?, minBid: int, endTime: int) = unpackAuctionState(auctionState);
    if (blockchain.now() < endTime) {
        return (myBalance, owner, auction);
    }
    if (isExternal) {
        acceptExternalMessage();
    }
    // should end auction
    if ((lastBid == null)) {
        // no stakes were made
        // NB: owner is not null now
        return (myBalance, owner, null);
    }
    var (beneficiaryAddress, _, _, _, _, _) = unpackAuctionConfig(auctionConfig);
    var (bidderAddress, bid: int, bidTs: int) = unpackLastBid(lastBid);
    var (royaltyNum: int, royaltyDenom: int, royaltyAddress) = unpackNftRoyaltyParams(royaltyParams);

    sendMsg(bidderAddress, 0, OP_OWNERSHIP_ASSIGNED, blockchain.logicalTime(),
            beginCell()
                    .storeAddress(owner)
                    .storeInt(0, 1)
                    .storeUint(OP_TELEITEM_BID_INFO, 32)
                    .storeCoins(bid)
                    .storeUint(bidTs, 32),
            1); // paying fees, revert on errors

    if ((royaltyNum > 0) & (royaltyDenom > 0) & !royaltyAddress.bitsEqual(beneficiaryAddress)) {
        var royaltyValue: int = min(bid, mulDivFloor(bid, royaltyNum, royaltyDenom));
        bid -= royaltyValue;
        myBalance = sendMoney(myBalance, royaltyAddress, royaltyValue);
    }

    myBalance = sendMoney(myBalance, beneficiaryAddress, bid);

    return (myBalance, bidderAddress, null);
}

fun processNewBid(myBalance: int, newBidAddress: address, newBid: int, auction: cell): (int, cell) {
    var (auctionState: cell, auctionConfig: cell) = unpackAuction(auction);
    var (oldLastBid: cell?, minBid: int, endTime: int) = unpackAuctionState(auctionState);
    assert(!(newBid < minBid)) throw ERR_TOO_SMALL_STAKE;
    var (beneficiaryAddress: address, initialMinBid: int, maxBid: int, minBidStep: int, minExtendTime: int, _) = unpackAuctionConfig(auctionConfig);
    var newLastBid: cell = packLastBid(newBidAddress, newBid, blockchain.now());
    var newEndTime: int = max(endTime, blockchain.now() + minExtendTime);
    if ((maxBid > 0) & (newBid >= maxBid)) {
        // for maybe_end_auction
        newEndTime = 0;
    }
    // step is at least GR$1
    var newMinBid: int = max(newBid + one_ton, (newBid * (100 + minBidStep) + 99) / 100);
    if (!(oldLastBid == null)) {
        var (oldBidderAddress: address, oldBid: int, _) = unpackLastBid(oldLastBid);
        var toSend: int = min(myBalance - cheap_min_tons_for_storage, oldBid);
        if (toSend > 0) {
            sendMsg(oldBidderAddress, toSend, OP_OUTBID_NOTIFICATION, blockchain.logicalTime(), null, 1);
            myBalance -= toSend;
        }
    }
    var newAuctionState: cell = packAuctionState(newLastBid, newMinBid, newEndTime);
    return (myBalance, packAuction(newAuctionState, auctionConfig));
}

fun prepareAuction(auctionConfig: cell): cell? {
    var (beneficiaryAddress: address, initialMinBid: int, maxBid: int, minBidStep: int, minExtendTime: int, duration: int) = unpackAuctionConfig(auctionConfig);
    // check beneficiary address
    // parseStandardAddress(beneficiaryAddress);    // in FunC, this call was deleted (unused pure fun call)
    if ((initialMinBid < cheap_min_tons_for_storage + cheap_minting_price) | ((maxBid != 0) & (maxBid < initialMinBid)) |
            (minBidStep <= 0) | (minExtendTime > 60 * 60 * 24 * 7) | (duration > 60 * 60 * 24 * 365)) {
        return null;
    }
    var auctionState: cell = packAuctionState(null, initialMinBid, blockchain.now() + duration);
    return packAuction(auctionState, auctionConfig);
}

fun deployItem(myBalance: int, msg: slice): cell? {
    // Do not throw errors here!
    var (bidderAddress: address, bid: int, tokenInfo: cell, nftContent: cell, auctionConfig: cell, royaltyParams: cell) = unpackTeleitemMsgDeploy(msg);
    var auction: cell? = prepareAuction(auctionConfig);
    if ((auction == null)) {
        return null;
    }
    var (myBalance redef, newAuction: cell?) = processNewBid(myBalance, bidderAddress, bid, auction);
    var (myBalance redef, owner: address, newAuction redef) = maybeEndAuction(myBalance, createAddressNone(), newAuction, royaltyParams, 0);
    var content: cell = packItemContent(nftContent, null, tokenInfo);
    return packItemState(owner, content, newAuction, royaltyParams);

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

    var (config: cell, state: cell?) = unpackItemData();
    var (index: int, collectionAddress: address) = unpackItemConfig(config);

    if (collectionAddress.bitsEqual(senderAddress)) {
        assert(op == OP_TELEITEM_MSG_DEPLOY) throw ERR_FORBIDDEN_NOT_DEPLOY;
        if ((state == null)) {
            var newState: cell? = deployItem(myBalance, inMsgBody);
            if (!(newState == null)) {
                return saveItemData(config, newState);
            }
        }
        var bidderAddress = inMsgBody.loadAddress(); // first field in teleitem_msg_deploy
        sendMsg(bidderAddress, 0, OP_TELEITEM_RETURN_BID, blockchain.logicalTime(), null, 64); // carry all the remaining value of the inbound message
        return;
    }

    assert(!((state == null))) throw ERR_UNINITED;
    var (ownerAddress, content: cell, auction: cell?, royaltyParams: cell) = unpackItemState(state);

    if (op == OP_GET_ROYALTY_PARAMS) {
        var queryId: int = inMsgBody.loadUint(64);
        sendMsg(senderAddress, 0, OP_REPORT_ROYALTY_PARAMS, queryId, beginCell().storeSlice(royaltyParams.beginParse()), 64); // carry all the remaining value of the inbound message
        return;
    }

    if (op == OP_NFT_CMD_GET_STATIC_DATA) {
        var queryId: int = inMsgBody.loadUint(64);
        sendMsg(senderAddress, 0, OP_REPORT_STATIC_DATA, queryId, beginCell().storeUint(index, 256).storeAddress(collectionAddress), 64); // carry all the remaining value of the inbound message
        return;
    }

    var isTopup = (op == 0) & inMsgBody.bitsEqual("#topup") & (inMsgBody.remainingRefsCount() == 0);
    if (isTopup) {
        return;
    }

    if (!(auction == null)) {
        // sender do not pay for auction with its message
        myBalance -= msgValue;
        (myBalance, ownerAddress, auction) = maybeEndAuction(myBalance, ownerAddress, auction, royaltyParams, 0);
        if ((auction == null)) {
            var newState: cell = packItemState(ownerAddress, content, auction, royaltyParams);
            saveItemData(config, newState);
        }
        myBalance += msgValue;
    }

    if (op == OP_TELEITEM_CANCEL_AUCTION) {
        assert(!((auction == null))) throw ERR_NO_AUCTION;
        assert(senderAddress.bitsEqual(ownerAddress)) throw ERR_FORBIDDEN_AUCTION;
        var queryId: int = inMsgBody.loadUint(64);
        var (auctionState: cell, auctionConfig: cell) = unpackAuction(auction);
        var (lastBid: cell?, minBid: int, endTime: int) = unpackAuctionState(auctionState);
        assert((lastBid == null)) throw ERR_ALREADY_HAS_STAKES;
        var newState: cell = packItemState(ownerAddress, content, null, royaltyParams);
        if (queryId) {
            sendMsg(senderAddress, 0, OP_TELEITEM_OK, queryId, null, 64); // carry all the remaining value of the inbound message
        }
        return saveItemData(config, newState);
    }

    if (!(auction == null)) {
        assert(op == 0) throw ERR_FORBIDDEN_NOT_STAKE;
        (myBalance, auction) = processNewBid(myBalance, senderAddress, msgValue, auction);
        (myBalance, ownerAddress, auction) = maybeEndAuction(myBalance, ownerAddress, auction, royaltyParams, 0);
        var newState: cell = packItemState(ownerAddress, content, auction, royaltyParams);
        return saveItemData(config, newState);
    }

    if (op == 0) {
        assert(senderAddress.bitsEqual(ownerAddress)) throw ERR_FORBIDDEN_TOPUP; // only owner can fill-up balance, prevent coins lost right after the auction
        // if owner send bid right after auction he can restore it by transfer response message
        return;
    }

    if (op == OP_TELEITEM_START_AUCTION) {
        assert(senderAddress.bitsEqual(ownerAddress)) throw ERR_FORBIDDEN_AUCTION;
        var queryId: int = inMsgBody.loadUint(64);
        var newAuctionConfig: cell = inMsgBody.loadRef();
        var newAuction: cell? = prepareAuction(newAuctionConfig);
        assert(!((newAuction == null))) throw ERR_INVALID_AUCTION_CONFIG;
        var newState: cell = packItemState(ownerAddress, content, newAuction, royaltyParams);
        if (queryId) {
            sendMsg(senderAddress, 0, OP_TELEITEM_OK, queryId, null, 64); // carry all the remaining value of the inbound message
        }
        return saveItemData(config, newState);
    }

    if (op == OP_NFT_CMD_TRANSFER) {
        assert(senderAddress.bitsEqual(ownerAddress)) throw ERR_FORBIDDEN_TRANSFER;
        var newOwnerAddress = transferOwnership(myBalance, ownerAddress, inMsgBody, fwdFee);
        var newState: cell = packItemState(newOwnerAddress, content, auction, royaltyParams);
        return saveItemData(config, newState);
    }

    throw ERR_UNKNOWN_OP;
}

fun onExternalMessage(inMsg: slice) {
    var myBalance: int = contract.getOriginalBalance();
    var (config: cell, state: cell?) = unpackItemData();
    state = state!;     // in FunC, there was no check for null
    var (ownerAddress, content: cell, auction: cell?, royaltyParams: cell) = unpackItemState(state);
    auction = auction!; // in FunC, there was no check for null
    (myBalance, ownerAddress, auction) = maybeEndAuction(myBalance, ownerAddress, auction, royaltyParams, -1);
    var newState: cell = packItemState(ownerAddress, content, auction, royaltyParams);
    return saveItemData(config, newState);
}

//
//  GET Methods
//

get get_nft_data(): (bool, int, address, address, cell?) {
    var (config: cell, state: cell?) = unpackItemData();
    var (itemIndex: int, collectionAddress) = unpackItemConfig(config);
    if ((state == null)) {
        return (false, itemIndex, collectionAddress, createAddressNone(), null);
    }
    var (ownerAddress, content: cell, auction: cell?, royaltyParams: cell) = unpackItemState(state);
    var (nftContent: cell, dns: dict, tokenInfo: cell) = unpackItemContent(content);
    return (true, itemIndex, collectionAddress, ownerAddress, nftContent);
}

get get_telemint_token_name(): slice {
    var (config: cell, state: cell?) = unpackItemData();
    state = state!;     // in FunC, there was no check for null
    var (ownerAddress: address, content: cell, auction: cell?, royaltyParams: cell) = unpackItemState(state);
    var (nftContent: cell, dns: dict, tokenInfo: cell) = unpackItemContent(content);
    var (tokenName: slice, domain: slice) = unpackTokenInfo(tokenInfo);
    return tokenName;
}

get get_telemint_auction_state(): (address?, int, int, int, int) {
    var (config: cell, state: cell?) = unpackItemData();
    state = state!;     // in FunC, there was no check for null
    var (ownerAddress: address, content: cell, auction: cell?, royaltyParams: cell) = unpackItemState(state);
    assert (!((auction == null))) throw ERR_NO_AUCTION;
    var (auctionState: cell, auctionConfig: cell) = unpackAuction(auction);
    var (lastBid: cell?, minBid: int, endTime: int) = unpackAuctionState(auctionState);
    var (bidderAddress: address?, bid: int, bidTs: int) = (null, 0, 0);
    if (!(lastBid == null)) {
        (bidderAddress, bid, bidTs) = unpackLastBid(lastBid);
    }
    return (bidderAddress, bid, bidTs, minBid, endTime);
}

get get_telemint_auction_config(): (address?, int, int, int, int, int) {
    var (config: cell, state: cell?) = unpackItemData();
    state = state!;     // in FunC, there was no check for null
    var (ownerAddress: address, content: cell, auction: cell?, royaltyParams: cell) = unpackItemState(state);
    if ((auction == null)) {
        // Do not throw error, so it is easy to check if get_telemint_auction_config method exists
        return (null, 0, 0, 0, 0, 0);
    }
    var (auctionState: cell, auctionConfig: cell) = unpackAuction(auction);
    var (beneficiaryAddress: address, initialMinBid: int, maxBid: int, minBidStep: int, minExtendTime: int, duration: int) =
            unpackAuctionConfig(auctionConfig);
    return (beneficiaryAddress, initialMinBid, maxBid, minBidStep, minExtendTime, duration);
}

get royalty_params(): (int, int, address) {
    var (config: cell, state: cell?) = unpackItemData();
    state = state!;     // in FunC, there was no check for null
    var (ownerAddress: address, content: cell, auction: cell?, royaltyParams: cell) = unpackItemState(state);
    var (numerator: int, denominator: int, destination: address) = unpackNftRoyaltyParams(royaltyParams);
    return (numerator, denominator, destination);
}
