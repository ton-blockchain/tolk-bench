import "@stdlib/gas-payments"

import "common.tolk"

fun unwrapSignedCmd(signedCmd: slice, publicKey: int, subwalletId: int, msgValue: int) {
    var (signature: slice, hash: int, gotSubwalletId: int, validSince: int, validTill: int, cmd: slice)
            = unpackSignedCmd(signedCmd);
    assert(isSignatureValid(hash, signature, publicKey)) throw ERR_INVALID_SIGNATURE;
    assert(subwalletId == gotSubwalletId) throw ERR_WRONG_SUBWALLET_ID;
    var ts: int = blockchain.now();
    assert(validSince < ts) throw ERR_NOT_YET_VALID_SIGNATURE;
    assert(ts < validTill) throw ERR_EXPIRED_SIGNATURE;
    return cmd;
}

@inline
fun unpackDeployMsgV2(cs: slice) {
    var res = (
            cs.loadText(), // token_name
            cs.loadRef(), // content
            cs.loadRef(), // auction_config
            cs.loadMaybeRef(), // royalty
            cs.loadMaybeRef() // restrictions
    );
    cs.assertEnd();
    return res;
}
const ERR_INVALID_SENDER_ADDRESS = 224;
const OP_TELEMINT_MSG_DEPLOY_V2 = 0x4637289b;

@inline
fun checkRestrictions(restrictions: cell?, senderAddress: address): address {
  if (restrictions != null) {
     var cs: slice = restrictions.beginParse();
     var hasForceSenderAddress: int = cs.loadUint(1);
     if (hasForceSenderAddress) {
        var forceSenderAddress: address = cs.loadAddress();
        assert(forceSenderAddress.bitsEqual(senderAddress)) throw ERR_INVALID_SENDER_ADDRESS;
     }
     var hasRewriteSenderAddress: int = cs.loadUint(1);
     if (hasRewriteSenderAddress) {
        var rewriteSenderAddress: address = cs.loadAddress();
        senderAddress = rewriteSenderAddress;
     }
  }
  return senderAddress;
}

fun deployItem(senderAddress: address, bid: int, itemCode: cell, cmd: slice, fullDomain: slice, defaultRoyaltyParams: cell) {
    var (tokenName, content, auctionConfig, royalty, restrictions) = unpackDeployMsgV2(cmd);
    senderAddress = checkRestrictions(restrictions, senderAddress);

    var (beneficiaryAddress: address, initialMinBid: int, maxBid: int, minBidStep: int, minExtendTime: int, _) = unpackAuctionConfig(auctionConfig);
    assert(bid >= initialMinBid) throw ERR_NOT_ENOUGH_FUNDS;
    var itemIndex: int = tokenName.bitsHash();
    var stateInit: cell = packItemStateInit(itemIndex, itemCode);
    var itemAddress: address = calculateAddress(workchain, stateInit);
    if ((royalty == null)) {
        royalty = defaultRoyaltyParams;
    }
    var tokenInfo: cell = packTokenInfo(tokenName, fullDomain);
    var deployMsg: cell = packTeleitemMsgDeploy(senderAddress, bid, tokenInfo, content, auctionConfig, royalty);
    var msg: cell = packInitIntMessage(itemAddress, stateInit, deployMsg);
    sendRawMessage(msg, 64); // carry all the remaining value of the inbound message, fee deducted from amount
}

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    if (flags & 1) { // ignore all bounced messages
        return;
    }
    var senderAddress = cs.loadAddress();

    var op: int = inMsgBody.isEnd() ? 0 : inMsgBody.loadUint(32);

    if (op == 0) { // regular money transfer
        // NB: it is not possible to recover any money transferred to this account
        // so we return back all transfers except ones with comment #topup in it
        assert(inMsgBody.bitsEqual("#topup") & (inMsgBody.remainingRefsCount() == 0)) throw ERR_WRONG_TOPUP_COMMENT;
        return;
    }

    assert(op == OP_TELEMINT_MSG_DEPLOY_V2) throw ERR_UNKNOWN_OP;

    var (_, subwalletId, publicKey, _, itemCode, fullDomain, defaultRoyaltyParams) = unpackCollectionData();
    var cmd = unwrapSignedCmd(inMsgBody, publicKey, subwalletId, msgValue);
    deployItem(senderAddress, msgValue, itemCode, cmd, fullDomain, defaultRoyaltyParams);
}

fun onExternalMessage(inMsg: slice) {
    var (touched, subwalletId, publicKey, content, itemCode, fullDomain, royaltyParams) = unpackCollectionData();
    assert(!(touched)) throw ERR_FORBIDDEN_TOUCH;
    acceptExternalMessage();
    saveCollectionData(true, subwalletId, publicKey, content, itemCode, fullDomain, royaltyParams);
}

// Get methods

get get_collection_data(): (bool, cell, address) {
    var (_, _, _, content, _, _, _) = unpackCollectionData();
    return (true, content, createAddressNone());
}

get get_nft_address_by_index(index: int): address {
    var (_, _, _, _, itemCode, _, _) = unpackCollectionData();
    var stateInit: cell = packItemStateInit(index, itemCode);
    return calculateAddress(workchain, stateInit);
}

get get_nft_content(index: int, individualNftContent: cell): cell {
    return individualNftContent;
}
