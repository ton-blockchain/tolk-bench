@pure
fun workchain(): int
    asm "0 PUSHINT";

fun forceChain(addr: address) {
    assert(addr.getWorkchain() == workchain()) throw 333;
}
