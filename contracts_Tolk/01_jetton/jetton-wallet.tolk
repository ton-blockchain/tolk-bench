// Jetton Wallet Smart Contract

tolk 0.13

import "params.tolk"
import "op-codes.tolk"
import "discovery-params.tolk"
import "jetton-utils.tolk"

/*

NOTE that this tokens can be transferred within the same workchain.

This is suitable for most tokens, if you need tokens transferable between workchains there are two solutions:

1) use more expensive but universal function to calculate message forward fee for arbitrary destination (see `misc/forward-fee-calc.cs`)

2) use token holder proxies in target workchain (that way even 'non-universal' token can be used from any workchain)

*/

@pure
fun minTonsForStorage(): int
    asm "10000000 PUSHINT"; // 0.01 TON
// Note that 2 * gas_consumptions is expected to be able to cover fees on both wallets (sender and receiver)
// and also constant fees on inter-wallet interaction, in particular fwd fee on state_init transfer
// that means that you need to reconsider this fee when:
// a) jetton logic become more gas-heavy
// b) jetton-wallet code (sent with inter-wallet message) become larger or smaller
// c) global fee changes / different workchain
@pure
fun gasConsumption(): int
    asm "15000000 PUSHINT"; // 0.015 TON

/*
  Storage
  storage#_ balance:Coins owner_address:MsgAddressInt jetton_master_address:MsgAddressInt jetton_wallet_code:^Cell = Storage;
*/

@inline
fun loadData(): (int, address, address, cell) {
  var ds: slice = contract.getData().beginParse();
  return (ds.loadCoins(), ds.loadAddress(), ds.loadAddress(), ds.loadRef());
}

@inline
fun saveData(balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) {
  contract.setData(packJettonWalletData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode));
}

/*
  transfer query_id:uint64 amount:(VarUInteger 16) destination:MsgAddress
           response_destination:MsgAddress custom_payload:(Maybe ^Cell)
           forward_ton_amount:(VarUInteger 16) forward_payload:(Either Cell ^Cell)
           = InternalMsgBody;
  internal_transfer  query_id:uint64 amount:(VarUInteger 16) from:MsgAddress
                     response_address:MsgAddress
                     forward_ton_amount:(VarUInteger 16)
                     forward_payload:(Either Cell ^Cell) 
                     = InternalMsgBody;
*/

fun sendTokens(inMsgBody: slice, senderAddress: address, msgValue: int, fwdFee: int) {
  var queryId: int = inMsgBody.loadUint(64);
  var jettonAmount: int = inMsgBody.loadCoins();
  var toOwnerAddress = inMsgBody.loadAddress();
  forceChain(toOwnerAddress);
  var (balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) = loadData();
  balance -= jettonAmount;

  assert(ownerAddress == senderAddress) throw 705;
  assert(balance >= 0) throw 706;

  var stateInit: cell = calculateJettonWalletStateInit(toOwnerAddress, jettonMasterAddress, jettonWalletCode);
  var toWalletAddress = calculateJettonWalletAddress(stateInit);
  var responseAddress = inMsgBody.loadAddress();
  var customPayload: dict = inMsgBody.loadDict();
  var forwardTonAmount: int = inMsgBody.loadCoins();
  assert(inMsgBody.remainingBitsCount() >= 1) throw 708;
  var eitherForwardPayload: slice = inMsgBody;
  var msg = beginCell()
    .storeUint(0x18, 6)
    .storeAddress(toWalletAddress)
    .storeCoins(0)
    .storeUint(4 + 2 + 1, 1 + 4 + 4 + 64 + 32 + 1 + 1 + 1)
    .storeRef(stateInit);
  var msgBody = beginCell()
    .storeUint(OP_INTERNAL_TRANSFER(), 32)
    .storeUint(queryId, 64)
    .storeCoins(jettonAmount)
    .storeAddress(ownerAddress)
    .storeAddress(responseAddress)
    .storeCoins(forwardTonAmount)
    .storeSlice(eitherForwardPayload)
    .endCell();

  msg = msg.storeRef(msgBody);
  var fwdCount: int = forwardTonAmount ? 2 : 1;
  assert(msgValue >
                     forwardTonAmount +
                     // 3 messages: wal1->wal2,  wal2->owner, wal2->response
                     // but last one is optional (it is ok if it fails)
                     fwdCount * fwdFee +
                     (2 * gasConsumption() + minTonsForStorage())) throw 709;
                     // universal message send fee calculation may be activated here
                     // by using this instead of fwd_fee
                     // msg_fwd_fee(to_wallet, msg_body, state_init, 15)

  sendRawMessage(msg.endCell(), 64); // revert on errors
  saveData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode);
}

/*
  internal_transfer  query_id:uint64 amount:(VarUInteger 16) from:MsgAddress
                     response_address:MsgAddress
                     forward_ton_amount:(VarUInteger 16)
                     forward_payload:(Either Cell ^Cell) 
                     = InternalMsgBody;
*/

fun receiveTokens(inMsgBody: slice, senderAddress: address, myTonBalance: int, fwdFee: int, msgValue: int) {
  // NOTE we can not allow fails in action phase since in that case there will be
  // no bounce. Thus check and throw in computation phase.
  var (balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) = loadData();
  var queryId: int = inMsgBody.loadUint(64);
  var jettonAmount: int = inMsgBody.loadCoins();
  balance += jettonAmount;
  var fromAddress = inMsgBody.loadAddress();
  var responseAddress = inMsgBody.loadAddress();
  assert((jettonMasterAddress == senderAddress)
      |
    (calculateUserJettonWalletAddress(fromAddress, jettonMasterAddress, jettonWalletCode) == senderAddress)) throw 707;
  var forwardTonAmount: int = inMsgBody.loadCoins();

  var tonBalanceBeforeMsg: int = myTonBalance - msgValue;
  var storageFee: int = minTonsForStorage() - min(tonBalanceBeforeMsg, minTonsForStorage());
  msgValue -= (storageFee + gasConsumption());
  if(forwardTonAmount) {
    msgValue -= (forwardTonAmount + fwdFee);
    var eitherForwardPayload: slice = inMsgBody;

    var msgBody = beginCell()
        .storeUint(OP_TRANSFER_NOTIFICATION(), 32)
        .storeUint(queryId, 64)
        .storeCoins(jettonAmount)
        .storeAddress(fromAddress)
        .storeSlice(eitherForwardPayload)
        .endCell();

    var msg = beginCell()
      .storeUint(0x10, 6) // we should not bounce here cause receiver can have uninitialized contract
      .storeAddress(ownerAddress)
      .storeCoins(forwardTonAmount)
      .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
      .storeRef(msgBody);

    sendRawMessage(msg.endCell(), 1);
  }

  if (responseAddress.isInternal() & (msgValue > 0)) {
    var msg = beginCell()
      .storeUint(0x10, 6) // nobounce - int_msg_info$0 ihr_disabled:Bool bounce:Bool bounced:Bool src:MsgAddress -> 010000
      .storeAddress(responseAddress)
      .storeCoins(msgValue)
      .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
      .storeUint(OP_EXCESSES(), 32)
      .storeUint(queryId, 64);
    sendRawMessage(msg.endCell(), 2);
  }

  saveData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode);
}

fun burnTokens(inMsgBody: slice, senderAddress: address, msgValue: int, fwdFee: int) {
  // NOTE we can not allow fails in action phase since in that case there will be
  // no bounce. Thus check and throw in computation phase.
  var (balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) = loadData();
  var queryId: int = inMsgBody.loadUint(64);
  var jettonAmount: int = inMsgBody.loadCoins();
  var responseAddress = inMsgBody.loadAddress();
  // ignore custom payload
  // slice custom_payload = in_msg_body~load_dict();
  balance -= jettonAmount;
  assert(ownerAddress == senderAddress) throw 705;
  assert(balance >= 0) throw 706;
  assert(msgValue > fwdFee + 2 * gasConsumption()) throw 707;

  var msgBody = beginCell()
      .storeUint(OP_BURN_NOTIFICATION(), 32)
      .storeUint(queryId, 64)
      .storeCoins(jettonAmount)
      .storeAddress(ownerAddress)
      .storeAddress(responseAddress)
      .endCell();

  var msg = beginCell()
    .storeUint(0x18, 6)
    .storeAddress(jettonMasterAddress)
    .storeCoins(0)
    .storeUint(1, 1 + 4 + 4 + 64 + 32 + 1 + 1)
    .storeRef(msgBody);

  sendRawMessage(msg.endCell(), 64);

  saveData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode);
}

fun onBounce(inMsgBody: slice) {
  inMsgBody.skipBits(32); // 0xFFFFFFFF
  var (balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell) = loadData();
  var op: int = inMsgBody.loadUint(32);
  assert((op == OP_INTERNAL_TRANSFER()) | (op == OP_BURN_NOTIFICATION())) throw 709;
  var queryId: int = inMsgBody.loadUint(64);
  var jettonAmount: int = inMsgBody.loadCoins();
  balance += jettonAmount;
  saveData(balance, ownerAddress, jettonMasterAddress, jettonWalletCode);
}

fun onInternalMessage(myBalance: int, msgValue: int, inMsgFull: cell, inMsgBody: slice) {
  if (inMsgBody.isEnd()) { // ignore empty messages
    return;
  }

  var cs: slice = inMsgFull.beginParse();
  var flags: int = cs.loadUint(4);
  if (flags & 1) {
    onBounce(inMsgBody);
    return;
  }
  var senderAddress = cs.loadAddress();
  cs.loadAddress(); // skip dst
  cs.loadCoins(); // skip value
  cs.skipBits(1); // skip extracurrency collection
  cs.loadCoins(); // skip ihr_fee
  var fwdFee: int = mulDivFloor(cs.loadCoins(), 3, 2); // we use message fwd_fee for estimation of forward_payload costs

  var op: int = inMsgBody.loadUint(32);

  if (op == OP_TRANSFER()) { // outgoing transfer
    sendTokens(inMsgBody, senderAddress, msgValue, fwdFee);
    return;
  }

  if (op == OP_INTERNAL_TRANSFER()) { // incoming transfer
    receiveTokens(inMsgBody, senderAddress, myBalance, fwdFee, msgValue);
    return;
  }

  if (op == OP_BURN()) { // burn
    burnTokens(inMsgBody, senderAddress, msgValue, fwdFee);
    return;
  }

  throw 0xffff;
}

get get_wallet_data(): (int, address, address, cell) {
  return loadData();
}
