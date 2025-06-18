// moved to the separate file to keep hex of the previous codes unchanged

import "params.tolk";

@pure
fun OP_PROVIDE_WALLET_ADDRESS(): int
    asm "0x2c76b973 PUSHINT";
@pure
fun OP_TAKE_WALLET_ADDRESS(): int
    asm "0xd1735400 PUSHINT";

@inline
fun isResolvable(addr: address): bool {
    return addr.getWorkchain() == workchain();
}
