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
    var amountToSend: int = min(myBalance - MIN_TONS_FOR_STORAGE, value);
    if (amountToSend > 0) {
        val sendMoneyMsg = createMessage({
            bounce: false,
            dest: address,
            value: amountToSend,
            body: SendMoneyToSomebody {
                queryId: blockchain.logicalTime()
            }
        });
        sendMoneyMsg.send(SEND_MODE_IGNORE_ERRORS);
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

    val newOwnerAddress = lastBid.bidderAddress;
    val ownershipMsg = createMessage({
        bounce: false,
        dest: newOwnerAddress,
        value: 0,
        // if `coins` values are very-very large, body may not fit the same cell as message contents;
        // but since we know that send amount is 0 (4 bits) and expect relatively small bidAmount,
        // force the compiler not to create a ref for message body
        body: UnsafeBodyNoRef {
            forceInline: NotificationOwnershipAssigned {
                queryId: blockchain.logicalTime(),
                oldOwnerAddress: owner,
                payload: ForwardPayloadInlineWrapper {
                    contents: ProvidedTeleitemBidInfo {
                        bidAmount: lastBid.bidAmount,
                        bidTimestamp: lastBid.bidTimestamp,
                    }
                }
            }
        }
    });
    ownershipMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);

    if ((royaltyParams.royaltyFactor > 0) & (royaltyParams.royaltyBase > 0) & (royaltyParams.address != auctionConfig.benificiaryAddress)) {
        var royaltyValue: int = min(lastBid.bidAmount, mulDivFloor(lastBid.bidAmount, royaltyParams.royaltyFactor, royaltyParams.royaltyBase));
        lastBid.bidAmount -= royaltyValue;
        myBalance = sendMoney(myBalance, royaltyParams.address, royaltyValue);
    }

    myBalance = sendMoney(myBalance, auctionConfig.benificiaryAddress, lastBid.bidAmount);

    return (myBalance, newOwnerAddress, null);
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
        var toSend: int = min(myBalance - MIN_TONS_FOR_STORAGE, lastBid.bidAmount);
        if (toSend > 0) {
            val notificationMsg = createMessage({
                bounce: false,
                dest: lastBid.bidderAddress,
                value: toSend,
                body: OutbidNotificationToBidder {
                    queryId: blockchain.logicalTime()
                }
            });
            notificationMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
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

        val msg = TelemintItemDeploy.fromSlice(inMsgBody, {
            throwIfOpcodeDoesNotMatch: ERR_UNKNOWN_OP
        });
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
            val respondMsg = createMessage({
                bounce: false,
                dest: senderAddress,
                value: 0,
                body: ResponseRoyaltyParams {
                    queryId: msg.queryId,
                    royaltyParams: state.royaltyParams.load()
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        RequestStaticData => {
            val itemConfig = lazy storage.config.load();
            val respondMsg = createMessage({
                bounce: false,
                dest: senderAddress,
                value: 0,
                // since item index is encoded as 256-bit (not 64-bit),
                // size of a response becomes too long (64 + 256 + address), the compiler will create a ref;
                // but because we know that msg value = 0 (4 bits),
                // tell the compiler to inline body into a message cell directly
                body: UnsafeBodyNoRef {
                    forceInline: ResponseStaticData {
                        queryId: msg.queryId,
                        index: itemConfig.index,
                        collectionAddress: itemConfig.collectionAddress,
                    }
                }
            });
            respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
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
                val respondMsg = createMessage({
                    bounce: false,
                    dest: senderAddress,
                    value: 0,
                    body: RespondTeleitemOK{}
                });
                respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            }
        }

        AskToCancelAuction => {
            assert (state.auction != null) throw ERR_NO_AUCTION;
            assert (senderAddress == state.ownerAddress) throw ERR_FORBIDDEN_AUCTION;

            val loadedAuction = lazy state.auction.load();
            val auctionState = lazy loadedAuction.state.load();
            assert (auctionState.lastBid == null) throw ERR_ALREADY_HAS_STAKES;
            if (msg.queryId) {
                val respondMsg = createMessage({
                    bounce: false,
                    dest: senderAddress,
                    value: 0,
                    body: RespondTeleitemOK{}
                });
                respondMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
            }

            state.auction = null;
            storage.state = state.toCell();
            storage.save();
        }

        AskToTransfer => {
            assert (state.auction == null) throw ERR_FORBIDDEN_NOT_STAKE;
            assert(senderAddress == state.ownerAddress) throw ERR_FORBIDDEN_TRANSFER;
            assert(msg.newOwnerAddress.getWorkchain() == MY_WORKCHAIN) throw ERR_INCORRECT_WORKCHAIN;

            var restAmount: int = myBalance - MIN_TONS_FOR_STORAGE;
            if (msg.forwardTonAmount) {
                restAmount -= (msg.forwardTonAmount + fwdFee);
            }
            var needResponse = msg.sendExcessesTo.isInternal();
            if (needResponse) {
                assert(msg.sendExcessesTo.getWorkchain() == MY_WORKCHAIN) throw ERR_INCORRECT_WORKCHAIN;
                restAmount -= fwdFee;
            }

            assert(restAmount >= 0) throw ERR_NOT_ENOUGH_FUNDS; // base nft spends fixed amount of gas, will not check for response

            if (msg.forwardTonAmount) {
                val ownershipMsg = createMessage({
                    bounce: false,
                    dest: msg.newOwnerAddress,
                    value: msg.forwardTonAmount,
                    // in FunC implementation, forward_payload was embedded directly (not into a ref);
                    // it can fail if payload is big;
                    // Tolk compiler will always create a ref (cell) here, because it's undetermined;
                    // force it not to create a ref to follow initial FunC implementation
                    body: UnsafeBodyNoRef {
                        forceInline: NotificationOwnershipAssigned {
                            queryId: msg.queryId,
                            oldOwnerAddress: state.ownerAddress,
                            payload: msg.forwardPayload,
                        }
                    }
                });
                ownershipMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
            if (needResponse) {
                val excessesMsg = createMessage({
                    bounce: false,
                    dest: msg.sendExcessesTo,
                    value: restAmount,
                    body: ReturnExcessesBack {
                        queryId: msg.queryId
                    }
                });
                excessesMsg.send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            state.ownerAddress = msg.newOwnerAddress;
            storage.state = state.toCell();
            storage.save();
        }

        TelemintItemDeploy => {
            val itemConfig = lazy storage.config.load();
            assert (senderAddress == itemConfig.collectionAddress) throw ERR_FORBIDDEN_NOT_DEPLOY;
            val returnBidMsg = createMessage({
                bounce: false,
                dest: msg.bidderAddress,
                value: 0,
                body: ReturnBidBackToBidder{}
            });
            returnBidMsg.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
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
