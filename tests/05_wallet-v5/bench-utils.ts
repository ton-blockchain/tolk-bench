import type { SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Address, beginCell, Cell, SendMode } from '@ton/core';
import { Opcodes } from '../../wrappers/05_wallet-v5/wallet-v5';

export async function sendInternalMessageFromExtension(
    via: SandboxContract<TreasuryContract>,
    to: Address,
    opts: {
        value: bigint;
        body: Cell;
    }
) {
    return await via.send({
        to,
        value: opts.value,
        body: beginCell()
            .storeUint(Opcodes.auth_extension, 32)
            .storeUint(0, 64)
            .storeSlice(opts.body.asSlice())
            .endCell()
    });
}

export function createSendTxActionMsg(testReceiver: Address, forwardValue: bigint) {
    const sendTxMsg = beginCell()
        .storeUint(0x10, 6)
        .storeAddress(testReceiver)
        .storeCoins(forwardValue)
        .storeUint(0, 1 + 4 + 4 + 64 + 32 + 1 + 1)
        .storeRef(beginCell().endCell())
        .endCell();

    const sendTxActionAction = beginCell()
        .storeUint(0x0ec3c86d, 32)
        .storeInt(SendMode.PAY_GAS_SEPARATELY | SendMode.IGNORE_ERRORS, 8)
        .storeRef(sendTxMsg)
        .endCell();

    const actionsList = beginCell()
        .storeMaybeRef(
            beginCell()
                .storeRef(beginCell().endCell()) // empty child - end of action list
                .storeSlice(sendTxActionAction.beginParse())
                .endCell()
        )
        .storeBit(false) // no other_actions
        .endCell();

    return actionsList;
}

export function createAddExtActionMsg(testExtension: Address) {
    const addExtensionAction = beginCell()
        .storeUint(Opcodes.action_extended_add_extension, 8)
        .storeAddress(testExtension)
        .endCell();

    const actionsList = beginCell()
        .storeMaybeRef(null) // no c5 out actions
        .storeBit(true) // have other actions
        .storeSlice(addExtensionAction.beginParse())
        .endCell();

    return actionsList;
}

export function bufferToBigInt(buffer: Buffer): bigint {
    return BigInt('0x' + buffer.toString('hex'));
}

export function validUntil(ttlMs = 1000 * 60 * 3) {
    return BigInt(Math.floor((Date.now() + ttlMs) / 1000));
}

export function createSeqnoCounter() {
    let seqno = 0n;
    let step = 0;
    return () => {
        if (step++ % 2 === 1) {
            return seqno++;
        } else {
            return seqno;
        }
    };
}