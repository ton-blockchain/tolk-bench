@pure
fun OP_TRANSFER(): int
    asm "0xf8a7ea5 PUSHINT";
@pure
fun OP_TRANSFER_NOTIFICATION(): int
    asm "0x7362d09c PUSHINT";
@pure
fun OP_INTERNAL_TRANSFER(): int
    asm "0x178d4519 PUSHINT";
@pure
fun OP_EXCESSES(): int
    asm "0xd53276db PUSHINT";
@pure
fun OP_BURN(): int
    asm "0x595f07bc PUSHINT";
@pure
fun OP_BURN_NOTIFICATION(): int
    asm "0x7bdd97de PUSHINT";

// Minter
@pure
fun OP_MINT(): int
    asm "21 PUSHINT";
