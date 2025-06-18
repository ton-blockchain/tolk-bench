import "params.tolk"

@inline
fun packJettonWalletData(balance: int, ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell): cell {
   return  beginCell()
            .storeCoins(balance)
            .storeAddress(ownerAddress)
            .storeAddress(jettonMasterAddress)
            .storeRef(jettonWalletCode)
           .endCell();
}

@inline
fun calculateJettonWalletStateInit(ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell): cell {
  return beginCell()
          .storeUint(0, 2)
          .storeDict(jettonWalletCode)
          .storeDict(packJettonWalletData(0, ownerAddress, jettonMasterAddress, jettonWalletCode))
          .storeUint(0, 1)
         .endCell();
}

@inline
fun calculateJettonWalletAddress(stateInit: cell): address {
  return beginCell().storeUint(4, 3)        // 0b100  (std no anycast)
                     .storeInt(workchain(), 8)
                     .storeUint(stateInit.hash(), 256)
                     .endCell()
                     .beginParse() as address;
}

@inline
fun calculateUserJettonWalletAddress(ownerAddress: address, jettonMasterAddress: address, jettonWalletCode: cell): address {
  return calculateJettonWalletAddress(calculateJettonWalletStateInit(ownerAddress, jettonMasterAddress, jettonWalletCode));
}
