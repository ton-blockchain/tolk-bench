@pure
fun OP_TRANSFER(): int
    asm "0x5fcc3d14 PUSHINT";

@pure
fun OP_OWNERSHIP_ASSIGNED(): int
    asm "0x05138d91 PUSHINT";

@pure
fun OP_EXCESSES(): int
    asm "0xd53276db PUSHINT";

@pure
fun OP_GET_STATIC_DATA(): int
    asm "0x2fcb26a2 PUSHINT";

@pure
fun OP_REPORT_STATIC_DATA(): int
    asm "0x8b771735 PUSHINT";

@pure
fun OP_GET_ROYALTY_PARAMS(): int
    asm "0x693d3950 PUSHINT";

@pure
fun OP_REPORT_ROYALTY_PARAMS(): int
    asm "0xa8cb00ad PUSHINT";

// NFTEditable
@pure
fun OP_EDIT_CONTENT(): int
    asm "0x1a0b9d51 PUSHINT";

@pure
fun OP_TRANSFER_EDITORSHIP(): int
    asm "0x1c04412a PUSHINT";

@pure
fun OP_EDITORSHIP_ASSIGNED(): int
    asm "0x511a4463 PUSHINT";
