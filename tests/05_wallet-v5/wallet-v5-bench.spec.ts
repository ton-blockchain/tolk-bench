import '@ton/test-utils';
import {type Address, beginCell, Cell, Dictionary, external, SendMode, toNano, Transaction} from '@ton/core';

import type { SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Blockchain } from '@ton/sandbox';
import type { KeyPair } from '@ton/crypto';
import { getSecureRandomBytes, keyPairFromSeed, sign } from '@ton/crypto';

import { Opcodes, WalletV5 } from '../../wrappers/05_wallet-v5/wallet-v5';
import {
    bufferToBigInt,
    createAddExtActionMsg,
    createSendTxActionMsg,
    createSeqnoCounter,
    sendInternalMessageFromExtension,
    validUntil,
} from './bench-utils';
import { activateTVM11, myCompile } from "../my-compile";
import { GasLogAndSave } from "../gas-logger";

const numericFolder = '05_wallet-v5';

// a separate "bench" .spec.ts file is created aside from main unit tests
// in order to achieve desired initial FunC gas metrics (to compare with Tact implementation)

describe(numericFolder + ' gas tests', () => {
    let GAS_LOG = new GasLogAndSave(numericFolder);
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let receiver: SandboxContract<TreasuryContract>;
    let wallet: SandboxContract<WalletV5>;
    let seqno: () => bigint;
    let keypair: KeyPair;

    const SUBWALLET_ID = 0n;

    async function sendSignedActionBody(walletAddress: Address, actions: Cell, kind: 'external' | 'internal') {
        const seqnoValue = seqno();
        const requestToSign = beginCell()
            .storeUint(kind === 'external' ? Opcodes.auth_signed : Opcodes.auth_signed_internal, 32)
            .storeUint(SUBWALLET_ID, 32)
            .storeUint(validUntil(), 32)
            .storeUint(seqnoValue, 32)
            .storeSlice(actions.asSlice());

        const operationHash = requestToSign.endCell().hash();
        const signature = sign(operationHash, keypair.secretKey);

        const dataCell = beginCell().storeBuffer(signature, 64).asSlice();
        const operationMsg = requestToSign.storeBuilder(dataCell.asBuilder()).endCell();

        return await (kind === 'external'
            ? blockchain.sendMessage(
                  external({
                      to: walletAddress,
                      body: operationMsg,
                  }),
              )
            : deployer.send({
                  to: walletAddress,
                  value: toNano('0.1'),
                  body: operationMsg,
              }));
    }

    let code: Cell;
    beforeAll(async () => {
        code = await myCompile(numericFolder, 'wallet_v5');
        GAS_LOG.rememberBocSize('wallet_v5', code);
    });
    afterAll(() => {
        GAS_LOG.saveCurrentRunAfterAll();
    });

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        activateTVM11(blockchain);

        keypair = keyPairFromSeed(await getSecureRandomBytes(32));

        deployer = await blockchain.treasury('deployer');
        receiver = await blockchain.treasury('receiver');

        seqno = createSeqnoCounter();

        wallet = blockchain.openContract(
            WalletV5.createFromConfig(
                {
                    signatureAllowed: true,
                    seqno: 0,
                    publicKey: keypair.publicKey,
                    walletId: 0n,
                    extensions: Dictionary.empty(),
                },
                code,
            ),
        );

        const deployResult = await wallet.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: wallet.address,
            deploy: true,
            success: true,
        });

        await deployer.send({
            to: wallet.address,
            value: toNano('10'),
            sendMode: SendMode.PAY_GAS_SEPARATELY,
        });
    });

    it('check correctness of deploy', async () => {
        const walletSeqno = await wallet.getSeqno();

        expect(walletSeqno).toBe(0);

        const walletPublicKey = await wallet.getPublicKey();

        expect(walletPublicKey).toBe(bufferToBigInt(keypair.publicKey));
    });

    it('[bench] externalTransfer', async () => {
        const testReceiver = receiver.address;
        const forwardValue = toNano(1);

        const receiverBalanceBefore = (await blockchain.getContract(testReceiver)).balance;

        const sendTxActionsList = createSendTxActionMsg(testReceiver, forwardValue);

        const externalTransferSendResult = await sendSignedActionBody(wallet.address, sendTxActionsList, 'external');

        expect(externalTransferSendResult.transactions).toHaveTransaction({
            to: wallet.address,
            success: true,
            exitCode: 0,
        });

        expect(externalTransferSendResult.transactions.length).toEqual(2);

        expect(externalTransferSendResult.transactions).toHaveTransaction({
            from: wallet.address,
            to: testReceiver,
            value: forwardValue,
        });

        const fee = externalTransferSendResult.transactions[1]!.totalFees.coins;
        const receiverBalanceAfter = (await blockchain.getContract(testReceiver)).balance;

        expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);

        GAS_LOG.rememberGas('EXTERNAL transfer', externalTransferSendResult.transactions[0]);
    });

    it('[bench] internalTransfer', async () => {
        const testReceiver = receiver.address;
        const forwardValue = toNano(1);

        const receiverBalanceBefore = (await blockchain.getContract(testReceiver)).balance;

        const sendTxActionsList = createSendTxActionMsg(testReceiver, forwardValue);

        const internalTransferSendResult = await sendSignedActionBody(wallet.address, sendTxActionsList, 'internal');

        expect(internalTransferSendResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: wallet.address,
            success: true,
            exitCode: 0,
        });

        expect(internalTransferSendResult.transactions.length).toEqual(3);

        expect(internalTransferSendResult.transactions).toHaveTransaction({
            from: wallet.address,
            to: testReceiver,
            value: forwardValue,
        });

        const fee = internalTransferSendResult.transactions[2]!.totalFees.coins;
        const receiverBalanceAfter = (await blockchain.getContract(testReceiver)).balance;

        expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);

        GAS_LOG.rememberGas('INTERNAL transfer', internalTransferSendResult.transactions.slice(1));
    });

    it('[bench] addExtension', async () => {
        const testExtension = receiver.address;

        const addExtActionsList = createAddExtActionMsg(testExtension);
        const addExtensionSendResult = await sendSignedActionBody(wallet.address, addExtActionsList, 'external');

        expect(addExtensionSendResult.transactions).toHaveTransaction({
            to: wallet.address,
            success: true,
            exitCode: 0,
        });

        const extensions = await wallet.getExtensionsArray();
        expect(extensions.length).toEqual(1);
        expect(extensions[0]).toEqualAddress(testExtension);

        GAS_LOG.rememberGas('ADD extension', addExtensionSendResult.transactions[0]);
    });

    it('[bench] extensionTransfer', async () => {
        const testReceiver = receiver.address;

        const forwardValue = toNano(0.001);
        const receiverBalanceBefore = (await blockchain.getContract(testReceiver)).balance;

        // add deployer as extension
        const actionsListAddExt = createAddExtActionMsg(deployer.address);
        await sendSignedActionBody(wallet.address, actionsListAddExt, 'internal');

        const extensions = await wallet.getExtensionsArray();
        expect(extensions.find((addr) => addr.equals(deployer.address))).toBeTruthy();

        const sendTxActionsList = createSendTxActionMsg(testReceiver, forwardValue);

        const extensionTransferResult = await sendInternalMessageFromExtension(deployer, wallet.address, {
            body: sendTxActionsList,
            value: toNano('0.1'),
        });

        expect(extensionTransferResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: wallet.address,
            success: true,
            exitCode: 0,
        });

        // external to ext + internal + ext transfer action
        expect(extensionTransferResult.transactions.length).toEqual(3);

        expect(extensionTransferResult.transactions).toHaveTransaction({
            from: wallet.address,
            to: testReceiver,
            success: true,
            value: forwardValue,
            exitCode: 0,
        });

        const fee = extensionTransferResult.transactions[2]!.totalFees.coins;
        const receiverBalanceAfter = (await blockchain.getContract(testReceiver)).balance;

        expect(receiverBalanceAfter).toEqual(receiverBalanceBefore + forwardValue - fee);

        GAS_LOG.rememberGas('EXTENSION transfer', extensionTransferResult.transactions.slice(1));
    });
});
