
import "op-codes.tolk"

const MY_WORKCHAIN = BASECHAIN;

@inline
fun isSameWorkchain(addr: address): bool {
    return addr.getWorkchain() == MY_WORKCHAIN;
}

@inline
fun checkSameWorkchain(addr: address) {
    assert(isSameWorkchain(addr)) throw ERROR_WRONG_WORKCHAIN;
}
