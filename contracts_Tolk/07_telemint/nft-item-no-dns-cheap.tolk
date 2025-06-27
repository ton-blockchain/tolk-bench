import "@stdlib/gas-payments"

import "common.tolk"
import "storage.tolk"
import "messages.tolk"

// actual storage of NFT item is tricky: it's either inited or not;
// after NFT has been inited, it's represented as `ItemStorage`;
// before initialization, it has only cell ItemConfig: `ItemStorageUninitialized`;
// hence, we start parsing it, then we detect, whether it's inited or not
struct ItemStorageEitherInitedOrNot {
    contractData: slice;
}

// how do we detect whether it's inited or not?
// the answer: when "inited", we store `ownerAddress` and other fields,
// so, we have some data bits, and for uninited, we have only 1 ref (see ItemStorageUninitialized)
fun ItemStorageEitherInitedOrNot.isInited(self) {
    val hasData = self.contractData.remainingBitsCount();
    return hasData
}

fun ItemStorageEitherInitedOrNot.parseAsUninited(self) {
    return ItemStorageUninitialized.fromSlice(self.contractData)
}

fun ItemStorageEitherInitedOrNot.parseAsInited(self) {
    return ItemStorage.fromSlice(self.contractData)
}

fun startLoadingItemStorage(): ItemStorageEitherInitedOrNot {
    return {
        contractData: contract.getData().beginParse()
    }
}

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

fun Auction.isExpired(self) {
    return blockchain.now() >= self.endTime
}

@inline_ref
fun Auction.calcNewOwnerOnExpire(self, mutate myBalance: int, oldOwner: address, royaltyParamsCell: Cell<RoyaltyParams>): address {
    if (self.lastBid == null) {
        // no stakes were made
        // NB: owner is not null now
        return oldOwner;
    }
    val auctionConfig = lazy self.config.load();
    var lastBid = lazy self.lastBid.load();
    val royaltyParams = lazy royaltyParamsCell.load();

    val newOwner = lastBid.bidderAddress;
    val ownershipMsg = createMessage({
        bounce: false,
        dest: newOwner,
        value: 0,
        // if `coins` values are very-very large, body may not fit the same cell as message contents;
        // but since we know that send amount is 0 (4 bits) and expect relatively small bidAmount,
        // force the compiler not to create a ref for message body
        body: UnsafeBodyNoRef {
            forceInline: NotificationOwnershipAssigned {
                queryId: blockchain.logicalTime(),
                oldOwnerAddress: oldOwner,
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
    return newOwner;
}

@inline
fun Auction.processNewBid(mutate self, mutate myBalance: coins, newBidAddress: address, newBid: int) {
    assert(newBid >= self.minBid) throw ERR_TOO_SMALL_STAKE;
    val auctionConfig = lazy self.config.load();

    var newEndTime: int = max(self.endTime, blockchain.now() + auctionConfig.minExtendTime);
    if ((auctionConfig.maxBid > 0) & (newBid >= auctionConfig.maxBid)) {
        // mark expired when current bid reaches max
        newEndTime = 0;
    }

    // step is at least GR$1
    var newMinBid: int = max(newBid + ton("1"), (newBid * (100 + auctionConfig.minBidStep) + 99) / 100);
    if (self.lastBid != null) {
        val lastBid = lazy self.lastBid.load();
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

    self.lastBid = LastBidInfo {
        bidderAddress: newBidAddress,
        bidAmount: newBid,
        bidTimestamp: blockchain.now(),
    }.toCell();
    self.minBid = newMinBid;
    self.endTime = newEndTime;
}

fun initializeItemOnDeployingByCollection(uninitedSt: ItemStorageUninitialized, myBalance: int, msg: TelemintItemDeploy): ItemStorage {
    var ownerAddress = createAddressNone();
    var auctionForStorage: Cell<Auction>? = null;

    val auctionConfig = lazy msg.auctionConfig.load();
    var auction = Auction.createStartingFromNow(msg.auctionConfig, auctionConfig.minBid, auctionConfig.duration);
    auction.processNewBid(mutate myBalance, msg.bidderAddress, msg.bidAmount);
    if (auction.isExpired()) {
        ownerAddress = auction.calcNewOwnerOnExpire(mutate myBalance, ownerAddress, msg.royaltyParams);
    } else {
        auctionForStorage = auction.toCell();
    }

    return {
        config: uninitedSt.config,
        ownerAddress,
        content: ItemContent{
            nftContent: msg.nftContent,
            dns: null,
            tokenInfo: msg.tokenInfo,
        }.toCell(),
        auction: auctionForStorage,
        royaltyParams: msg.royaltyParams,
    }
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

    var loadingStorage = startLoadingItemStorage();
    if (!loadingStorage.isInited()) {
        val uninitedSt = loadingStorage.parseAsUninited();
        val itemConfig = lazy uninitedSt.config.load();
        assert (senderAddress == itemConfig.collectionAddress) throw ERR_UNINITED;

        // using a message from collection, convert "uninitialized" to "initialized" state
        val msg = TelemintItemDeploy.fromSlice(inMsgBody, {
            throwIfOpcodeDoesNotMatch: ERR_UNKNOWN_OP
        });
        val storage = initializeItemOnDeployingByCollection(uninitedSt, myBalance, msg);
        storage.save();
        return;
    }

    var state = loadingStorage.parseAsInited();

    // since the last accepted message, current auction might have expired
    if (state.auction != null) {
        val auction = state.auction.load();
        if (auction.isExpired()) {
            myBalance -= msgValue;      // sender does not pay for auction with its message
            state.ownerAddress = auction.calcNewOwnerOnExpire(mutate myBalance, state.ownerAddress, state.royaltyParams);
            myBalance += msgValue;
            state.auction = null;
            state.save();
        }
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
            var auction = state.auction.load();
            auction.processNewBid(mutate myBalance, senderAddress, msgValue);
            if (auction.isExpired()) {
                state.ownerAddress = auction.calcNewOwnerOnExpire(mutate myBalance, state.ownerAddress, state.royaltyParams);
                state.auction = null;
            } else {
                state.auction = auction.toCell();
            }
            state.save();
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
            val itemConfig = lazy state.config.load();
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
            assert (senderAddress == state.ownerAddress) throw ERR_FORBIDDEN_AUCTION;

            val config = lazy msg.newAuctionConfig.load();
            assert (!config.isInvalid()) throw ERR_INVALID_AUCTION_CONFIG;

            state.auction = Auction.createStartingFromNow(msg.newAuctionConfig, config.minBid, config.duration).toCell();
            state.save();

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

            val auction = lazy state.auction.load();
            assert (auction.lastBid == null) throw ERR_ALREADY_HAS_STAKES;
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
            state.save();
        }

        AskToTransfer => {
            assert (state.auction == null) throw ERR_FORBIDDEN_NOT_STAKE;
            assert (senderAddress == state.ownerAddress) throw ERR_FORBIDDEN_TRANSFER;
            assert (msg.newOwnerAddress.getWorkchain() == MY_WORKCHAIN) throw ERR_INCORRECT_WORKCHAIN;

            var restAmount: int = myBalance - MIN_TONS_FOR_STORAGE;
            if (msg.forwardTonAmount) {
                restAmount -= (msg.forwardTonAmount + fwdFee);
            }
            var needResponse = msg.sendExcessesTo.isInternal();
            if (needResponse) {
                assert(msg.sendExcessesTo.getWorkchain() == MY_WORKCHAIN) throw ERR_INCORRECT_WORKCHAIN;
                restAmount -= fwdFee;
            }

            assert (restAmount >= 0) throw ERR_NOT_ENOUGH_FUNDS; // base nft spends fixed amount of gas, will not check for response

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
            state.save();
        }

        TelemintItemDeploy => {
            val itemConfig = lazy state.config.load();
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
    var state = lazy ItemStorage.load();
    val auction = state.auction!.load();    // if no auction in progress, parsing will fail, it's ok
    if (auction.isExpired()) {
        acceptExternalMessage();
        var myBalance = contract.getOriginalBalance();
        state.ownerAddress = auction.calcNewOwnerOnExpire(mutate myBalance, state.ownerAddress, state.royaltyParams);
        state.auction = null;
        state.save();
    }
}

//
//  GET Methods
//

get get_nft_data(): (bool, int, address, address, cell?) {
    var loadingStorage = startLoadingItemStorage();
    if (!loadingStorage.isInited()) {
        val uninitedSt = loadingStorage.parseAsUninited();
        val itemConfig = lazy uninitedSt.config.load();
        return (false, itemConfig.index, itemConfig.collectionAddress, createAddressNone(), null);
    } else {
        val storage = loadingStorage.parseAsInited();
        val itemConfig = lazy storage.config.load();
        return (true, itemConfig.index, itemConfig.collectionAddress, storage.ownerAddress, storage.content);
    }
}

get get_telemint_token_name(): slice {
    val storage = lazy ItemStorage.load();
    val itemContent = lazy storage.content.load();
    var (tokenName: slice, domain: slice) = unpackTokenInfo(itemContent.tokenInfo);
    return tokenName;
}

get get_telemint_auction_state(): (address?, int, int, int, int) {
    val storage = lazy ItemStorage.load();
    assert (storage.auction != null) throw ERR_NO_AUCTION;

    val auction = storage.auction.load();
    var (bidderAddress: address?, bid: int, bidTs: int) = (null, 0, 0);
    if (auction.lastBid != null) {
        val lastBid = auction.lastBid.load();
        (bidderAddress, bid, bidTs) = (lastBid.bidderAddress, lastBid.bidAmount, lastBid.bidTimestamp);
    }
    return (bidderAddress, bid, bidTs, auction.minBid, auction.endTime);
}

get get_telemint_auction_config(): (address?, int, int, int, int, int) {
    val storage = lazy ItemStorage.load();
    if (storage.auction == null) {
        // Do not throw error, so it is easy to check if get_telemint_auction_config method exists
        return (null, 0, 0, 0, 0, 0);
    }

    val auction = lazy storage.auction.load();
    val c = lazy auction.config.load();
    return (c.benificiaryAddress, c.minBid, c.maxBid, c.minBidStep, c.minExtendTime, c.duration);
}

get royalty_params(): RoyaltyParams {
    val storage = lazy ItemStorage.load();
    return storage.royaltyParams.load();
}
