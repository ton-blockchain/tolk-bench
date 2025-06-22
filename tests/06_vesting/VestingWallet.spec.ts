import {Blockchain, SandboxContract, TreasuryContract} from '@ton/sandbox';
import {Address, beginCell, Cell, internal, MessageRelaxed, SenderArguments, SendMode, toNano} from '@ton/core';
import {ErrorCodes, Opcodes, VestingWallet} from '../../wrappers/06_vesting/VestingWallet';
import '@ton/test-utils';
import {createWalletTransferV3} from "@ton/ton/dist/wallets/signing/createWalletTransfer";
import {KeyPair, keyPairFromSeed} from "@ton/crypto";
import { findTransactionRequired } from '@ton/test-utils';
import { GasLogAndSave } from "../gas-logger";
import { myCompile } from "../my-compile";

function senderArgsToMessageRelaxed(args: SenderArguments): MessageRelaxed {
    return internal({
        to: args.to,
        value: args.value,
        init: args.init,
        body: args.body,
        bounce: args.bounce
    })
}

const addresses = [
    '-1:0073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '0:2073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '-1:3073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '0:4073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '0:5073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '0:6073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '-1:7073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '0:8073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '0:9073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c',
    '0:A073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e590000',
].map(addressString => Address.parse(addressString));

const SUB_WALLET_ID = 345;
const VESTING_START_TIME = 1689422684;
const VESTING_TOTAL_DURATION = 60 * 60 * 24 * 30 * 12;
const UNLOCK_PERIOD = 60 * 60 * 24 * 30;
const CLIFF_DURATION = 60 * 60 * 24 * 30 * 2;
const VESTING_TOTAL_AMOUNT = toNano(123000n);

const ELECTOR_ADDRESS = Address.parse('Ef8zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM0vF');
const CONFIG_ADDRESS = Address.parse('Ef9VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVbxn');

const numericFolder = '06_vesting';

describe(numericFolder, () => {
    const GAS_LOG = new GasLogAndSave(numericFolder);
    let code: Cell;

    beforeAll(async () => {
        code = await myCompile(numericFolder, 'VestingWallet');
        GAS_LOG.rememberBocSize("vesting wallet", code);
    });
    afterAll(() => {
        GAS_LOG.saveCurrentRunAfterAll();
    })

    let ownerKeyPair: KeyPair;
    let notOwnerKeyPair: KeyPair;

    let blockchain: Blockchain;
    let vestingWallet: SandboxContract<VestingWallet>;
    let vestingSender: SandboxContract<TreasuryContract>
    let owner: SandboxContract<TreasuryContract>

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        blockchain.now = VESTING_START_TIME;

        ownerKeyPair = keyPairFromSeed(Buffer.from('vt58J2v6FaBuXFGcyGtqT5elpVxcZ+I1zgu/GUfA5uY=', 'base64'));
        notOwnerKeyPair = keyPairFromSeed(Buffer.from('vt59J2v6FaBuXFGcyGtqT5elpVxcZ+I1zgu/GUfA5uY=', 'base64'));

        vestingSender = await blockchain.treasury('vestingSender');
        owner = await blockchain.treasury('owner');

        vestingWallet = blockchain.openContract(
            VestingWallet.createFromConfig(
                {
                    subWalletId: SUB_WALLET_ID,
                    publicKeyHex: ownerKeyPair.publicKey.toString('hex'),
                    vestingStartTime: VESTING_START_TIME,
                    vestingTotalDuration: VESTING_TOTAL_DURATION,
                    unlockPeriod: UNLOCK_PERIOD,
                    cliffDuration: CLIFF_DURATION,
                    vestingTotalAmount: VESTING_TOTAL_AMOUNT,
                    vestingSenderAddress: vestingSender.address,
                    ownerAddress: owner.address
                },
                code
            )
        );

        const deployer = await blockchain.treasury('deployer');
        const deployResult = await vestingWallet.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: vestingWallet.address,
            deploy: true,
            success: true,
        });

        const topUpResult = await vestingWallet.sendSimple(owner.getSender(), {
            value: toNano('123000'),
        });

        expect(topUpResult.transactions).toHaveTransaction({
            from: owner.address,
            to: vestingWallet.address,
            success: true
        });
        expect(topUpResult.transactions.length).toBe(2);

        await checkLockupData();

    });

    async function checkLockupData(expectedSeqno?: number) {
        const seqno = await vestingWallet.getSeqno();
        expect(seqno).toBe(expectedSeqno || 0);

        const subWalletId = await vestingWallet.getSubWalletId();
        expect(subWalletId).toBe(SUB_WALLET_ID);

        const publicKeyHex = await vestingWallet.getPublicKeyHex();
        expect(publicKeyHex).toBe(ownerKeyPair.publicKey.toString('hex'));

        const lockupData = await vestingWallet.getVestingData();
        expect(lockupData.vestingStartTime).toBe(VESTING_START_TIME);
        expect(lockupData.vestingTotalDuration).toBe(VESTING_TOTAL_DURATION);
        expect(lockupData.unlockPeriod).toBe(UNLOCK_PERIOD);
        expect(lockupData.cliffDuration).toBe(CLIFF_DURATION);
        expect(lockupData.vestingTotalAmount).toBe(VESTING_TOTAL_AMOUNT);
        expect(lockupData.vestingSenderAddress.toString()).toBe(vestingSender.address.toString());
        expect(lockupData.ownerAddress.toString()).toBe(owner.address.toString());
    }

    it('should deploy', async () => {
        // the check is done inside beforeEach
        // blockchain and vestingWallet are ready to use

        await checkLockupData();

    });

    // ADD WHITELIST

    async function addWhitelist(count: number, increaser: SandboxContract<TreasuryContract>) {
        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const result = await vestingWallet.sendAddWhitelist(increaser.getSender(), {
            queryId: 123 + count,
            value: toNano('1'),
            addresses: addresses.slice(0, count)
        });

        expect(result.transactions).toHaveTransaction({
            from: increaser.address,
            to: vestingWallet.address,
            success: true,
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: increaser.address,
            success: true,
            body: beginCell().storeUint(Opcodes.add_whitelist_response, 32).storeUint(123 + count, 64).endCell()
        });

        expect(result.transactions.length).toBe(3);

        const lastTx: any = result.transactions[result.transactions.length - 1];
        expect(lastTx.inMessage.info.src.toString()).toBe(vestingWallet.address.toString());
        expect(lastTx.inMessage.info.dest.toString()).toBe(increaser.address.toString());
        expect(lastTx.inMessage.info.value.coins).toBeLessThan(toNano('1'));

        const whitelist = await vestingWallet.getWhitelist();
        const whitelistStrings = whitelist.map((address: Address) => address.toString());
        expect(whitelist.length).toBe(count);

        for (let i = 0; i < count; i++) {
            expect(whitelistStrings.indexOf(addresses[i].toString()) > -1).toBeTruthy();
            expect(await vestingWallet.getIsWhitelisted(addresses[i])).toBeTruthy();
        }

        for (let i = count; i < 10; i++) {
            expect(await vestingWallet.getIsWhitelisted(addresses[i])).toBeFalsy();
        }

        expect(await vestingWallet.getIsWhitelisted(Address.parse('0:0073f6ed7a84ac7d90739db7741f9d487478854b69960769f74859081e592d1c'))).toBeFalsy()

        await checkLockupData();

        return result;
    }

    it('[bench] add 1 whitelist', async () => {
        const res = await addWhitelist(1, vestingSender);
        GAS_LOG.rememberGas("ADD whitelist", res.transactions.slice(1));
    });
    it('add 2 whitelist', async () => {
        await addWhitelist(2, vestingSender);
    });
    it('add 3 whitelist', async () => {
        await addWhitelist(3, vestingSender);
    });
    it('add 4 whitelist', async () => {
        await addWhitelist(4, vestingSender);
    });
    it('add 5 whitelist', async () => {
        await addWhitelist(5, vestingSender);
    });
    it('add 6 whitelist', async () => {
        await addWhitelist(6, vestingSender);
    });
    it('add 7 whitelist', async () => {
        await addWhitelist(7, vestingSender);
    });
    it('add 8 whitelist', async () => {
        await addWhitelist(8, vestingSender);
    });
    it('add 9 whitelist', async () => {
        await addWhitelist(9, vestingSender);
    });
    it('add 10 whitelist', async () => {
        await addWhitelist(10, vestingSender);
    });

    async function whitelistNotVestingSender(notVestingSender: SandboxContract<TreasuryContract>) {

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const result = await vestingWallet.sendAddWhitelist(notVestingSender.getSender(), {
            queryId: 123,
            value: toNano('1'),
            addresses: addresses.slice(0, 1)
        });

        expect(result.transactions).toHaveTransaction({
            from: notVestingSender.address,
            to: vestingWallet.address,
            success: true,
        });
        expect(result.transactions.length).toBe(2);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);

        await checkLockupData();
    }

    it('add whitelist not sender', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await whitelistNotVestingSender(notVestingSender);
    });

    it('add whitelist by owner', async () => {
        await whitelistNotVestingSender(owner);
    });

    it('add whitelist twice', async () => {
        const increaser = vestingSender;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const result = await vestingWallet.sendAddWhitelist(increaser.getSender(), {
            queryId: 123,
            value: toNano('1'),
            addresses: addresses.slice(0, 2)
        });

        expect(result.transactions).toHaveTransaction({
            from: increaser.address,
            to: vestingWallet.address,
            success: true,
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: increaser.address,
            success: true,
            body: beginCell().storeUint(Opcodes.add_whitelist_response, 32).storeUint(123, 64).endCell()
        });
        expect(result.transactions.length).toBe(3);

        const whitelist = await vestingWallet.getWhitelist();
        const whitelistStrings = whitelist.map((address: Address) => address.toString());
        expect(whitelist.length).toBe(2);

        expect(whitelistStrings.indexOf(addresses[0].toString()) > -1).toBeTruthy();
        expect(whitelistStrings.indexOf(addresses[1].toString()) > -1).toBeTruthy();
        expect(whitelistStrings.indexOf(addresses[4].toString()) > -1).toBeFalsy();
        expect(await vestingWallet.getIsWhitelisted(addresses[0])).toBeTruthy();
        expect(await vestingWallet.getIsWhitelisted(addresses[1])).toBeTruthy();
        expect(await vestingWallet.getIsWhitelisted(addresses[4])).toBeFalsy();

        const result2 = await vestingWallet.sendAddWhitelist(increaser.getSender(), {
            queryId: 777,
            value: toNano('1'),
            addresses: [addresses[4]]
        });

        expect(result2.transactions).toHaveTransaction({
            from: increaser.address,
            to: vestingWallet.address,
            success: true,
        });

        expect(result2.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: increaser.address,
            success: true,
            body: beginCell().storeUint(Opcodes.add_whitelist_response, 32).storeUint(777, 64).endCell()
        });
        expect(result2.transactions.length).toBe(3);

        const lastTx: any = result2.transactions[result2.transactions.length - 1];
        expect(lastTx.inMessage.info.src.toString()).toBe(vestingWallet.address.toString());
        expect(lastTx.inMessage.info.dest.toString()).toBe(increaser.address.toString());
        expect(lastTx.inMessage.info.value.coins).toBeLessThan(toNano('1'));

        const whitelist2 = await vestingWallet.getWhitelist();
        const whitelistStrings2 = whitelist2.map((address: Address) => address.toString());
        expect(whitelist2.length).toBe(3);

        expect(whitelistStrings2.indexOf(addresses[0].toString()) > -1).toBeTruthy();
        expect(whitelistStrings2.indexOf(addresses[1].toString()) > -1).toBeTruthy();
        expect(whitelistStrings2.indexOf(addresses[4].toString()) > -1).toBeTruthy();
        expect(await vestingWallet.getIsWhitelisted(addresses[0])).toBeTruthy();
        expect(await vestingWallet.getIsWhitelisted(addresses[1])).toBeTruthy();
        expect(await vestingWallet.getIsWhitelisted(addresses[4])).toBeTruthy();

        await checkLockupData();
    });

    // TOPUP

    async function topUp(sender: SandboxContract<TreasuryContract>) {
        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        // empty message

        const result = await vestingWallet.sendSimple(sender.getSender(), {
            value: toNano('1')
        });

        expect(result.transactions).toHaveTransaction({
            from: sender.address,
            to: vestingWallet.address,
            success: true,
        });
        expect(result.transactions.length).toBe(2);

        // text comment

        const result2 = await vestingWallet.sendSimple(sender.getSender(), {
            value: toNano('1'),
            comment: 'giftgiftgiftgiftgiftgift'
        });

        expect(result2.transactions).toHaveTransaction({
            from: sender.address,
            to: vestingWallet.address,
            success: true,
        });
        expect(result2.transactions.length).toBe(2);

        // empty text comment

        const result3 = await vestingWallet.sendOp(sender.getSender(), {
            value: toNano('1'),
            op: 0
        });

        expect(result3.transactions).toHaveTransaction({
            from: sender.address,
            to: vestingWallet.address,
            success: true,
        });
        expect(result3.transactions.length).toBe(2);

        // any OP

        const result4 = await vestingWallet.sendOp(sender.getSender(), {
            value: toNano('1'),
            op: 0xd6745240
        });

        expect(result4.transactions).toHaveTransaction({
            from: sender.address,
            to: vestingWallet.address,
            success: true,
        });
        expect(result4.transactions.length).toBe(2);

        //

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);

        await checkLockupData();
    }


    it('sender can topup', async () => {
        await topUp(vestingSender);
    });


    it('anyone can topup', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await topUp(notVestingSender);
    });

    it('owner can topup', async () => {
        await topUp(owner);
    });

    // locked amount

    it('get_unlocked_amount', async () => {
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME - 100)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + CLIFF_DURATION - 1)).toBe(toNano(123000n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + CLIFF_DURATION)).toBe(toNano(123000n - 123000n * 2n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 3 - 1)).toBe(toNano(123000n - 123000n * 2n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 3)).toBe(toNano(123000n - 123000n * 3n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 4 - 1)).toBe(toNano(123000n - 123000n * 3n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 4)).toBe(toNano(123000n - 123000n * 4n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 7 - 1)).toBe(toNano(123000n - 123000n * 6n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 7)).toBe(toNano(123000n - 123000n * 7n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 9 - 1)).toBe(toNano(123000n - 123000n * 8n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 9)).toBe(toNano(123000n - 123000n * 9n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 10 - 1)).toBe(toNano(123000n - 123000n * 9n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 10)).toBe(toNano(123000n - 123000n * 10n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 11 - 1)).toBe(toNano(123000n - 123000n * 10n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 11)).toBe(toNano(123000n - 123000n * 11n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 12 - 1)).toBe(toNano(123000n - 123000n * 11n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 12)).toBe(toNano(0n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + VESTING_TOTAL_DURATION)).toBe(toNano(0n));
    });

    it('get_unlocked_amount no cliff', async () => {
        const vestingWallet = blockchain.openContract(
            VestingWallet.createFromConfig(
                {
                    subWalletId: SUB_WALLET_ID,
                    publicKeyHex: ownerKeyPair.publicKey.toString('hex'),
                    vestingStartTime: VESTING_START_TIME,
                    vestingTotalDuration: VESTING_TOTAL_DURATION,
                    unlockPeriod: UNLOCK_PERIOD,
                    cliffDuration: 0,
                    vestingTotalAmount: VESTING_TOTAL_AMOUNT,
                    vestingSenderAddress: vestingSender.address,
                    ownerAddress: owner.address
                },
                code
            )
        );

        const deployer = await blockchain.treasury('deployer');
        const deployResult = await vestingWallet.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: vestingWallet.address,
            deploy: true,
            success: true,
        });

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME - 100)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD)).toBe(toNano(123000n - 123000n * 1n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + CLIFF_DURATION - 1)).toBe(toNano(123000n - 123000n * 1n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + CLIFF_DURATION)).toBe(toNano(123000n - 123000n * 2n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 3 - 1)).toBe(toNano(123000n - 123000n * 2n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 3)).toBe(toNano(123000n - 123000n * 3n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 4 - 1)).toBe(toNano(123000n - 123000n * 3n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 4)).toBe(toNano(123000n - 123000n * 4n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 7 - 1)).toBe(toNano(123000n - 123000n * 6n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 7)).toBe(toNano(123000n - 123000n * 7n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 9 - 1)).toBe(toNano(123000n - 123000n * 8n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 9)).toBe(toNano(123000n - 123000n * 9n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 10 - 1)).toBe(toNano(123000n - 123000n * 9n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 10)).toBe(toNano(123000n - 123000n * 10n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 11 - 1)).toBe(toNano(123000n - 123000n * 10n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 11)).toBe(toNano(123000n - 123000n * 11n / 12n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 12 - 1)).toBe(toNano(123000n - 123000n * 11n / 12n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 12)).toBe(toNano(0n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + VESTING_TOTAL_DURATION)).toBe(toNano(0n));
    });

    it('get_unlocked_amount unlock = duration', async () => {
        const vestingWallet = blockchain.openContract(
            VestingWallet.createFromConfig(
                {
                    subWalletId: SUB_WALLET_ID,
                    publicKeyHex: ownerKeyPair.publicKey.toString('hex'),
                    vestingStartTime: VESTING_START_TIME,
                    vestingTotalDuration: VESTING_TOTAL_DURATION,
                    unlockPeriod: VESTING_TOTAL_DURATION,
                    cliffDuration: 0,
                    vestingTotalAmount: VESTING_TOTAL_AMOUNT,
                    vestingSenderAddress: vestingSender.address,
                    ownerAddress: owner.address
                },
                code
            )
        );

        const deployer = await blockchain.treasury('deployer');
        const deployResult = await vestingWallet.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: vestingWallet.address,
            deploy: true,
            success: true,
        });

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME - 100)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + VESTING_TOTAL_DURATION / 2)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + VESTING_TOTAL_DURATION - 1)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + VESTING_TOTAL_DURATION)).toBe(toNano(0n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + VESTING_TOTAL_DURATION + 1)).toBe(toNano(0n));
    });


    it('get_unlocked_amount total_duration == unlock_period', async () => {
        const vestingWallet = blockchain.openContract(
            VestingWallet.createFromConfig(
                {
                    subWalletId: SUB_WALLET_ID,
                    publicKeyHex: ownerKeyPair.publicKey.toString('hex'),
                    vestingStartTime: VESTING_START_TIME,
                    vestingTotalDuration: VESTING_TOTAL_DURATION,
                    unlockPeriod: VESTING_TOTAL_DURATION,
                    cliffDuration: 0,
                    vestingTotalAmount: VESTING_TOTAL_AMOUNT,
                    vestingSenderAddress: vestingSender.address,
                    ownerAddress: owner.address
                },
                code
            )
        );

        const deployer = await blockchain.treasury('deployer');
        const deployResult = await vestingWallet.sendDeploy(deployer.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: vestingWallet.address,
            deploy: true,
            success: true,
        });


        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME - 100)).toBe(toNano(123000n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME)).toBe(toNano(123000n));
        for (let i = 0; i <= 11; i++) {
            expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * i)).toBe(toNano(123000n));
        }

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + UNLOCK_PERIOD * 12)).toBe(toNano(0n));

        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + VESTING_TOTAL_DURATION)).toBe(toNano(0n));
        expect(await vestingWallet.getLockedAmount(VESTING_START_TIME + VESTING_TOTAL_DURATION * 2)).toBe(toNano(0n));
    });

    async function transferSuccess(time: number, value: bigint) {
        blockchain.now = time;

        const notVestingSender = await blockchain.treasury('notVestingSender');

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const t = createWalletTransferV3({
            seqno: 0,
            sendMode: 0,
            walletId: 0,
            messages: [
                senderArgsToMessageRelaxed({
                    to: notVestingSender.address,
                    value: value,
                    bounce: true
                })
            ],
            secretKey: Buffer.from(new Uint8Array(64))
        });

        const result = await vestingWallet.sendInternalTransfer(owner.getSender(), {
            value: toNano('1'),
            queryId: 567,
            sendMode: 3,
            msg: t.beginParse().loadRef()
        });

        expect(result.transactions).toHaveTransaction({
            from: owner.address,
            to: vestingWallet.address,
            success: true
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: owner.address,
            body: beginCell().storeUint(Opcodes.send_response, 32).storeUint(567, 64).endCell()
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: notVestingSender.address,
            value: value,
        });
        expect(result.transactions.length).toBe(4);

        const lastTx: any = result.transactions[result.transactions.length - 1];
        expect(lastTx.inMessage.info.src.toString()).toBe(vestingWallet.address.toString());
        expect(lastTx.inMessage.info.dest.toString()).toBe(owner.address.toString());
        expect(lastTx.inMessage.info.value.coins).toBeLessThan(toNano('1'));

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);

        await checkLockupData();

        return result;
    }

    async function transferFail(time: number, value: bigint) {
        blockchain.now = time;

        const notVestingSender = await blockchain.treasury('notVestingSender');

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const t = createWalletTransferV3({
            seqno: 0,
            sendMode: SendMode.IGNORE_ERRORS + SendMode.PAY_GAS_SEPARATELY,
            walletId: 0,
            messages: [
                senderArgsToMessageRelaxed({
                    to: notVestingSender.address,
                    value: value,
                    bounce: true
                })
            ],
            secretKey: Buffer.from(new Uint8Array(64))
        });

        const result = await vestingWallet.sendInternalTransfer(owner.getSender(), {
            value: toNano('1'),
            queryId: 567,
            sendMode: 3,
            msg: t.beginParse().loadRef()
        });

        expect(result.transactions).toHaveTransaction({
            from: owner.address,
            to: vestingWallet.address,
            success: true
        });

        expect(result.transactions.length).toBe(3);

        const lastTx: any = result.transactions[result.transactions.length - 1];
        expect(lastTx.inMessage.info.src.toString()).toBe(vestingWallet.address.toString());
        expect(lastTx.inMessage.info.dest.toString()).toBe(owner.address.toString());
        expect(lastTx.inMessage.info.value.coins).toBeLessThan(toNano('1'));

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);

        await checkLockupData();
    }

    it('owner cant internal transfer', async () => {
        await transferFail(
            VESTING_START_TIME + UNLOCK_PERIOD,
            toNano(123000n * 1n / 12n)
        )
    });

    it('[bench] owner can internal 2/12 transfer', async () => {
        const res = await transferSuccess(
            VESTING_START_TIME + CLIFF_DURATION,
            toNano(123000n * 2n / 12n)
        )
        GAS_LOG.rememberGas("UNLOCK internal partial", res.transactions.slice(1));
    });

    it('owner cant internal 4/12 transfer', async () => {
        await transferFail(
            VESTING_START_TIME + UNLOCK_PERIOD * 4 - 1,
            toNano(123000n * 4n / 12n)
        )
    });

    it('owner can internal 4/12 transfer', async () => {
        await transferSuccess(
            VESTING_START_TIME + UNLOCK_PERIOD * 4,
            toNano(123000n * 4n / 12n)
        )
    });

    it('owner can internal 12/12 transfer', async () => {
        await transferSuccess(
            VESTING_START_TIME + VESTING_TOTAL_DURATION + 1,
            toNano(123000n)
        )
    });

    // INTERNAL SEND

    it('owner can internal transfer', async () => {
        blockchain.now = VESTING_START_TIME + VESTING_TOTAL_DURATION + 1;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const t = createWalletTransferV3({
            seqno: 0,
            sendMode: SendMode.IGNORE_ERRORS + SendMode.PAY_GAS_SEPARATELY,
            walletId: 0,
            messages: [
                senderArgsToMessageRelaxed({
                    to: vestingSender.address,
                    value: toNano('122999.9'),
                    bounce: true
                })
            ],
            secretKey: Buffer.from(new Uint8Array(64))
        });

        const result = await vestingWallet.sendInternalTransfer(owner.getSender(), {
            value: toNano('1'),
            queryId: 567,
            sendMode: 3,
            msg: t.beginParse().loadRef()
        });

        expect(result.transactions).toHaveTransaction({
            from: owner.address,
            to: vestingWallet.address,
            success: true
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: owner.address,
            body: beginCell().storeUint(Opcodes.send_response, 32).storeUint(567, 64).endCell()
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: vestingSender.address,
            value: toNano('122999.9'),
        });
        expect(result.transactions.length).toBe(4);

        const lastTx: any = result.transactions[result.transactions.length - 1];
        expect(lastTx.inMessage.info.src.toString()).toBe(vestingWallet.address.toString());
        expect(lastTx.inMessage.info.dest.toString()).toBe(owner.address.toString());
        expect(lastTx.inMessage.info.value.coins).toBeLessThan(toNano('1'));

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);

        await checkLockupData();
    });

    it('no restriction after vesting', async () => {
        blockchain.now = VESTING_START_TIME + VESTING_TOTAL_DURATION + 1;

        const notVestingSender = await blockchain.treasury('notVestingSender');

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const t = createWalletTransferV3({
            seqno: 0,
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            walletId: 0,
            messages: [
                senderArgsToMessageRelaxed({
                    to: notVestingSender.address,
                    value: toNano('122999.9'),
                    bounce: false,
                    body: beginCell().storeUint(0, 32).storeStringTail("y").endCell()
                })
            ],
            secretKey: Buffer.from(new Uint8Array(64))
        });

        const result = await vestingWallet.sendInternalTransfer(owner.getSender(), {
            value: toNano('1'),
            queryId: 567,
            sendMode: 3,
            msg: t.beginParse().loadRef()
        });

        const transferTx = findTransactionRequired(result.transactions, {
            from: owner.address,
            to: vestingWallet.address,
            success: true
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: owner.address,
            body: beginCell().storeUint(Opcodes.send_response, 32).storeUint(567, 64).endCell()
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: notVestingSender.address,
            value: toNano('122999.9'),
        });
        expect(result.transactions.length).toBe(4);

        const lastTx: any = result.transactions[result.transactions.length - 1];
        expect(lastTx.inMessage.info.src.toString()).toBe(vestingWallet.address.toString());
        expect(lastTx.inMessage.info.dest.toString()).toBe(owner.address.toString());
        expect(lastTx.inMessage.info.value.coins).toBeLessThan(toNano('1'));

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);

        await checkLockupData();
    });

    async function transferNotOwner(sender: SandboxContract<TreasuryContract>) {
        blockchain.now = VESTING_START_TIME + VESTING_TOTAL_DURATION + 1;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const t = createWalletTransferV3({
            seqno: 0,
            sendMode: SendMode.IGNORE_ERRORS + SendMode.PAY_GAS_SEPARATELY,
            walletId: 0,
            messages: [
                senderArgsToMessageRelaxed({
                    to: vestingSender.address,
                    value: 9n,
                    bounce: true
                })
            ],
            secretKey: Buffer.from(new Uint8Array(64))
        });

        const result = await vestingWallet.sendInternalTransfer(sender.getSender(), {
            value: toNano('1'),
            queryId: 567,
            sendMode: 3,
            msg: t.beginParse().loadRef()
        });

        expect(result.transactions).toHaveTransaction({
            from: sender.address,
            to: vestingWallet.address,
            success: true
        });
        expect(result.transactions.length).toBe(2);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);

        await checkLockupData();
    }

    it('not owner can not do internal transfer', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferNotOwner(notVestingSender);
    });

    it('vesting sender can not do internal transfer', async () => {
        await transferNotOwner(vestingSender);
    });

    // restrictions

    async function transferReject(exitCode: number, sender: SandboxContract<TreasuryContract>, to: Address, isWhitelist: boolean, sendMode: number, bounceable: boolean, hasStateInit: boolean, comment: String | number | undefined) {
        blockchain.now = VESTING_START_TIME + UNLOCK_PERIOD * 7;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        if (isWhitelist) {
            await vestingWallet.sendAddWhitelist(vestingSender.getSender(), {
                queryId: 111,
                value: toNano('1'),
                addresses: [to]
            });

            expect(await vestingWallet.getIsWhitelisted(to)).toBeTruthy();
        }

        const stateInit = hasStateInit ? {
            code, data: beginCell().endCell()
        } : undefined;

        let body: Cell | undefined = undefined;
        if (comment) {
            body = (typeof comment === 'string') ?
                beginCell().storeUint(0, 32).storeStringTail(comment as string).endCell() :
                beginCell().storeUint(comment as number, 32).storeUint(0x456, 64).endCell();
        }

        const t = createWalletTransferV3({
            seqno: 0,
            sendMode: sendMode,
            walletId: 0,
            messages: [
                senderArgsToMessageRelaxed({
                    to: to,
                    value: toNano('3'),
                    bounce: bounceable,
                    body: body,
                    init: stateInit
                })
            ],
            secretKey: Buffer.from(new Uint8Array(64))
        });

        const result = await vestingWallet.sendInternalTransfer(sender.getSender(), {
            value: toNano('1'),
            queryId: 567,
            sendMode: sendMode,
            msg: t.beginParse().loadRef()
        });

        expect(result.transactions).toHaveTransaction({
            from: sender.address,
            to: vestingWallet.address,
            success: false,
            exitCode: exitCode
        });
        expect(result.transactions.length).toBe(3);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(isWhitelist ? 1 : 0);

        if (isWhitelist) {
            expect(await vestingWallet.getIsWhitelisted(to)).toBeTruthy();
        }

        await checkLockupData();
    }

    async function transferAllow(time: number, sender: SandboxContract<TreasuryContract>, to: Address, isWhitelist: boolean, sendMode: number, bounceable: boolean, hasStateInit: boolean, comment: String | number | undefined) {
        blockchain.now = time;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        if (isWhitelist) {
            await vestingWallet.sendAddWhitelist(vestingSender.getSender(), {
                queryId: 111,
                value: toNano('1'),
                addresses: [to]
            });

            expect(await vestingWallet.getIsWhitelisted(to)).toBeTruthy();
        }

        const stateInit = hasStateInit ? {
            code, data: beginCell().endCell()
        } : undefined;

        let body: Cell | undefined = undefined;
        if (comment) {
            body = (typeof comment === 'string') ?
                beginCell().storeUint(0, 32).storeStringTail(comment as string).endCell() :
                beginCell().storeUint(comment as number, 32).storeUint(0x456, 64).endCell();
        }

        const t = createWalletTransferV3({
            seqno: 0,
            sendMode: sendMode,
            walletId: 0,
            messages: [
                senderArgsToMessageRelaxed({
                    to: to,
                    value: toNano('3'),
                    bounce: bounceable,
                    body: body,
                    init: stateInit
                })
            ],
            secretKey: Buffer.from(new Uint8Array(64))
        });

        const result = await vestingWallet.sendInternalTransfer(sender.getSender(), {
            value: toNano('1'),
            queryId: 567,
            sendMode: sendMode,
            msg: t.beginParse().loadRef()
        });

        expect(result.transactions).toHaveTransaction({
            from: owner.address,
            to: vestingWallet.address,
            success: true
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: owner.address,
            body: beginCell().storeUint(Opcodes.send_response, 32).storeUint(567, 64).endCell()
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: to,
            value: toNano('3'),
        });
        expect(result.transactions.length).toBe(4);

        const lastTx: any = result.transactions[result.transactions.length - 1];
        expect(lastTx.inMessage.info.src.toString()).toBe(vestingWallet.address.toString());
        expect(lastTx.inMessage.info.dest.toString()).toBe(owner.address.toString());
        expect(lastTx.inMessage.info.value.coins).toBeLessThan(toNano('1'));


        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(isWhitelist ? 1 : 0);

        if (isWhitelist) {
            expect(await vestingWallet.getIsWhitelisted(to)).toBeTruthy();
        }

        await checkLockupData();

        return result;
    }

    async function transferAllowElector(time: number, sender: SandboxContract<TreasuryContract>, to: Address, isWhitelist: boolean, sendMode: number, bounceable: boolean, hasStateInit: boolean, comment: String | number | undefined) {
        blockchain.now = time;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        if (isWhitelist) {
            await vestingWallet.sendAddWhitelist(vestingSender.getSender(), {
                queryId: 111,
                value: toNano('1'),
                addresses: [to]
            });

            expect(await vestingWallet.getIsWhitelisted(to)).toBeTruthy();
        }

        const stateInit = hasStateInit ? {
            code, data: beginCell().endCell()
        } : undefined;

        let body: Cell | undefined = undefined;
        if (comment) {
            body = (typeof comment === 'string') ?
                beginCell().storeUint(0, 32).storeStringTail(comment as string).endCell() :
                beginCell().storeUint(comment as number, 32).storeUint(0x456, 64).endCell();
        }

        const t = createWalletTransferV3({
            seqno: 0,
            sendMode: sendMode,
            walletId: 0,
            messages: [
                senderArgsToMessageRelaxed({
                    to: to,
                    value: toNano('3'),
                    bounce: bounceable,
                    body: body,
                    init: stateInit
                })
            ],
            secretKey: Buffer.from(new Uint8Array(64))
        });

        const result = await vestingWallet.sendInternalTransfer(sender.getSender(), {
            value: toNano('1'),
            queryId: 567,
            sendMode: sendMode,
            msg: t.beginParse().loadRef()
        });

        expect(result.transactions).toHaveTransaction({
            from: owner.address,
            to: vestingWallet.address,
            success: true
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: owner.address,
            body: beginCell().storeUint(Opcodes.send_response, 32).storeUint(567, 64).endCell()
        });

        expect(result.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: to,
            value: toNano('3'),
        });
        expect(result.transactions.length).toBe(5);

        const lastTx: any = result.transactions[result.transactions.length - 2];
        expect(lastTx.inMessage.info.src.toString()).toBe(vestingWallet.address.toString());
        expect(lastTx.inMessage.info.dest.toString()).toBe(owner.address.toString());
        expect(lastTx.inMessage.info.value.coins).toBeLessThan(toNano('1'));

        const bouncedTx: any = result.transactions[result.transactions.length - 1];
        expect(bouncedTx.inMessage.info.src.toString()).toBe(to.toString());
        expect(bouncedTx.inMessage.info.dest.toString()).toBe(vestingWallet.address.toString());

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(isWhitelist ? 1 : 0);

        if (isWhitelist) {
            expect(await vestingWallet.getIsWhitelisted(to)).toBeTruthy();
        }

        await checkLockupData();

        return result;
    }

    // after vesting

    it('if lock expired && to vestingSender - sendmode != 3, non-bounceable, state_init, bin comment allowed', async () => {
        await transferAllow(VESTING_START_TIME + VESTING_TOTAL_DURATION + 1, owner, vestingSender.address, false, 1, false, true, 0x567);
    });

    it('if lock expired && to vestingSender - sendmode != 3, non-bounceable, state_init, "y" allowed', async () => {
        await transferAllow(VESTING_START_TIME + VESTING_TOTAL_DURATION + 1, owner, vestingSender.address, false, 1, false, true, 'y');
    });

    it('if lock expired && to anyone - sendmode != 3, non-bounceable, state_init, bin comment allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + VESTING_TOTAL_DURATION + 1, owner, notVestingSender.address, false, 1, false, true, 0x567);
    });

    it('if lock expired && to anyone - sendmode != 3, non-bounceable, state_init, "y" allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + VESTING_TOTAL_DURATION + 1, owner, notVestingSender.address, false, 1, false, true, 'y');
    });

    it('if lock expired && to whitelist - sendmode != 3, non-bounceable, state_init, bin comment allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + VESTING_TOTAL_DURATION + 1, owner, notVestingSender.address, true, 1, false, true, 0x567);
    });

    it('if lock expired && to whitelist - sendmode != 3, non-bounceable, state_init, "y" allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + VESTING_TOTAL_DURATION + 1, owner, notVestingSender.address, true, 1, false, true, 'y');
    });

    // to anyone

    it('if locked && to anyone - senmode != 3 rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.send_mode_not_allowed, owner, notVestingSender.address, false, 1, false, true, 0x567);
    });

    it('if locked && to anyone - non-bounceable, state_init, bin comment allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, false, 3, false, true, 0x567);
    });

    it('if locked && to anyone - non-bounceable, state_init, "y" allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, false, 3, false, true, 'y');
    });

    // to vesting sender

    it('if locked && to vestingSender - sendmode != 3 rejected', async () => {
        await transferReject(ErrorCodes.send_mode_not_allowed, owner, vestingSender.address, false, 128, true, false, undefined);
    });

    it('if locked && to vestingSender - non-bounceable, state_init, bin comment allowed', async () => {
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, vestingSender.address, false, 3, false, true, 0x567);
    });

    it('[bench] if locked && to vestingSender - non-bounceable, state_init, "y" allowed', async () => {
        const res = await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, vestingSender.address, false, 3, false, true, 'y');
        GAS_LOG.rememberGas("INTERNAL to vesting sender", res.transactions.slice(1));
    });

    // to whitelist

    it('if locked && whitelist - sendmode != 3 rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.send_mode_not_allowed, owner, notVestingSender.address, true, 128, true, false, undefined);
    });

    it('if locked && whitelist - non-bounceable rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.non_bounceable_not_allowed, owner, notVestingSender.address, true, 3, false, false, undefined);
    });

    it('if locked && whitelist - stateInit rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.state_init_not_allowed, owner, notVestingSender.address, true, 3, true, true, undefined);
    });

    it('if locked && whitelist - bin comment rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.comment_not_allowed, owner, notVestingSender.address, true, 3, true, false, 0x567);
    });

    it('if locked && whitelist & not elector - new_stake rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.comment_not_allowed, owner, notVestingSender.address, true, 3, true, false, 0x4e73744b);
    });

    it('if locked && whitelist & not elector - recover_stake rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.comment_not_allowed, owner, notVestingSender.address, true, 3, true, false, 0x47657424);
    });

    // elector

    it('if locked && whitelist & elector - empty rejected', async () => {
        // await transferReject(9, owner, ELECTOR_ADDRESS, true, 3, true, false, undefined);
        // changed against FunC: now fails with proper error code, not "cell underflow"
        await transferReject(ErrorCodes.comment_not_allowed, owner, ELECTOR_ADDRESS, true, 3, true, false, undefined);
    });

    it('if locked && whitelist & elector - "d" rejected', async () => {
        await transferReject(ErrorCodes.comment_not_allowed, owner, ELECTOR_ADDRESS, true, 3, true, false, "d");
    });

    it('if locked && whitelist & elector - "0x567" rejected', async () => {
        await transferReject(ErrorCodes.comment_not_allowed, owner, ELECTOR_ADDRESS, true, 3, true, false, 0x567);
    });

    it('[bench] if locked && whitelist & elector - new_stake allowed', async () => {
        const res = await transferAllowElector(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, ELECTOR_ADDRESS, true, 3, true, false, Opcodes.elector_new_stake);
        GAS_LOG.rememberGas("INTERNAL to elector", res.transactions.slice(1));
    });

    it('if locked && whitelist & elector - recover_stake allowed', async () => {
        await transferAllowElector(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, ELECTOR_ADDRESS, true, 3, true, false, Opcodes.elector_recover_stake);
    });

    it('if locked && whitelist & elector - vote_for_complaint allowed', async () => {
        await transferAllowElector(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, ELECTOR_ADDRESS, true, 3, true, false, Opcodes.vote_for_complaint);
    });

    it('if locked && whitelist & elector - vote_for_proposal allowed', async () => {
        await transferAllowElector(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, ELECTOR_ADDRESS, true, 3, true, false, Opcodes.vote_for_proposal);
    });

    // config

    it('if locked && whitelist & config - empty rejected', async () => {
        // await transferReject(9, owner, CONFIG_ADDRESS, true, 3, true, false, undefined);
        // changed against FunC: now fails with proper error code, not "cell underflow"
        await transferReject(ErrorCodes.comment_not_allowed, owner, ELECTOR_ADDRESS, true, 3, true, false, undefined);
    });

    it('if locked && whitelist & config - "d" rejected', async () => {
        await transferReject(ErrorCodes.comment_not_allowed, owner, CONFIG_ADDRESS, true, 3, true, false, "d");
    });

    it('if locked && whitelist & config - "0x567" rejected', async () => {
        await transferReject(ErrorCodes.comment_not_allowed, owner, CONFIG_ADDRESS, true, 3, true, false, 0x567);
    });

    it('if locked && whitelist & config - new_stake rejected', async () => {
        await transferReject(ErrorCodes.comment_not_allowed, owner, CONFIG_ADDRESS, true, 3, true, false, Opcodes.elector_new_stake);
    });

    it('if locked && whitelist & config - recover_stake allowed', async () => {
        await transferReject(ErrorCodes.comment_not_allowed, owner, CONFIG_ADDRESS, true, 3, true, false, Opcodes.elector_recover_stake);
    });

    it('if locked && whitelist & config - vote_for_complaint allowed', async () => {
        await transferReject(ErrorCodes.comment_not_allowed, owner, CONFIG_ADDRESS, true, 3, true, false, Opcodes.vote_for_complaint);
    });

    it('if locked && whitelist & config - vote_for_proposal allowed', async () => {
        await transferAllowElector(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, CONFIG_ADDRESS, true, 3, true, false, Opcodes.vote_for_proposal);
    });

    //

    it('[bench] if locked && whitelist - 0x1000 allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        const res = await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, Opcodes.single_nominator_pool_withdraw);
        GAS_LOG.rememberGas("INTERNAL to single nominator", res.transactions.slice(1));
    });
    it('if locked && whitelist - 0x1001 allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, Opcodes.single_nominator_pool_change_validator);
    });
    it('if locked && whitelist - 0x47d54391 allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, Opcodes.ton_stakers_deposit);
    });
    it('if locked && whitelist - 0x595f07bc allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, Opcodes.jetton_burn);
    });

    it('if locked && whitelist - tonstakers vote allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, Opcodes.ton_stakers_vote);
    });

    it('if locked && whitelist - vote for complaint allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, Opcodes.vote_for_complaint);
    });

    it('if locked && whitelist - vote for proposal allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, Opcodes.vote_for_proposal);
    });

    it('if locked && whitelist - single-nominator send_raw_msg rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.comment_not_allowed, owner, notVestingSender.address, true, 3, true, false, 0x7702);
    });

    it('if locked && whitelist - single-nominator upgrade rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.comment_not_allowed, owner, notVestingSender.address, true, 3, true, false, 0x9903);
    });

    it('if locked && whitelist - new_stake rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.comment_not_allowed, owner, notVestingSender.address, true, 3, true, false, Opcodes.elector_new_stake);
    });

    it('if locked && whitelist - recover_stake rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.comment_not_allowed, owner, notVestingSender.address, true, 3, true, false, Opcodes.elector_recover_stake);
    });

    it('if locked && whitelist - "y" rejected', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferReject(ErrorCodes.symbols_not_allowed, owner, notVestingSender.address, true, 3, true, false, 'y');
    });

    it('if locked && whitelist - empty allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        const res = await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, undefined);
        let measureTx = findTransactionRequired(res.transactions, {
            on: vestingWallet.address,
            from: owner.address,
            aborted: false
        });
    });
    it('if locked && whitelist - "" allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, '');
    });
    it('[bench] if locked && whitelist - "d" allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        const res = await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, 'd');
        GAS_LOG.rememberGas("INTERNAL with comment", res.transactions.slice(1));
    });
    it('if locked && whitelist - "w" allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, 'w');
    });
    it('if locked && whitelist - "D" allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, 'D');
    });
    it('if locked && whitelist - "W" allowed', async () => {
        const notVestingSender = await blockchain.treasury('notVestingSender');
        await transferAllow(VESTING_START_TIME + UNLOCK_PERIOD * 7, owner, notVestingSender.address, true, 3, true, false, 'W');
    });

    // external

    it('external transfer from owner', async () => {
        // blockchain.now = time;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const transferResult = await vestingWallet.sendExternalTransfer({
            seqno: 0,
            secretKey: ownerKeyPair.secretKey,
            messages: [
                senderArgsToMessageRelaxed({
                    to: vestingSender.address,
                    value: toNano('122999.9'),
                    bounce: true,
                })
            ],
            sendMode: SendMode.PAY_GAS_SEPARATELY + SendMode.IGNORE_ERRORS,
            timeout: 60,
            subWalletId: SUB_WALLET_ID
        });

        expect(transferResult.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: vestingSender.address,
            value: toNano('122999.9'),
        })
        expect(transferResult.transactions.length).toBe(2);

        let measureTx = findTransactionRequired(transferResult.transactions, {
            on: vestingWallet.address,
            outMessagesCount: 1,
            aborted: false
        });

        await checkLockupData(1);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);
    });

    it('[bench] external transfer from owner2', async () => {
        blockchain.now = VESTING_START_TIME + VESTING_TOTAL_DURATION + 1;
        const notVestingSender = await blockchain.treasury('notVestingSender');

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const transferResult = await vestingWallet.sendExternalTransfer({
            seqno: 0,
            secretKey: ownerKeyPair.secretKey,
            messages: [
                senderArgsToMessageRelaxed({
                    to: notVestingSender.address,
                    value: toNano('122999.9'),
                    bounce: false,
                    body: beginCell().storeUint(0, 32).storeStringTail('y').endCell()
                })
            ],
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            timeout: 60,
            subWalletId: SUB_WALLET_ID
        });

        expect(transferResult.transactions).toHaveTransaction({
            from: vestingWallet.address,
            to: notVestingSender.address,
            value: toNano('122999.9'),
        })
        expect(transferResult.transactions.length).toBe(2);

        GAS_LOG.rememberGas("EXTERNAL transfer after unlock", transferResult.transactions);

        await checkLockupData(1);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);
    });

    it('external transfer deploy', async () => {
        // blockchain.now = time;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const transferResult = await vestingWallet.sendExternalTransfer({
            seqno: 0,
            secretKey: ownerKeyPair.secretKey,
            messages: [],
            sendMode: SendMode.PAY_GAS_SEPARATELY + SendMode.IGNORE_ERRORS,
            timeout: 60,
            subWalletId: SUB_WALLET_ID
        });

        expect(transferResult.transactions.length).toBe(1);

        await checkLockupData(1);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);
    });

    it('external transfer no balance and no ingnore errors', async () => {
        // blockchain.now = time;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        const transferResult = await vestingWallet.sendExternalTransfer({
            seqno: 0,
            secretKey: ownerKeyPair.secretKey,
            messages: [
                senderArgsToMessageRelaxed({
                    to: vestingSender.address,
                    value: toNano('50000000000'),
                    bounce: true
                })
            ],
            sendMode: SendMode.PAY_GAS_SEPARATELY,
            timeout: 60,
            subWalletId: SUB_WALLET_ID
        });

        expect(transferResult.transactions.length).toBe(1);

        await checkLockupData(1);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);
    });

    it('external - invalid signature', async () => {
        // blockchain.now = time;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        let wasError = false;

        try {
            const transferResult = await vestingWallet.sendExternalTransfer({
                seqno: 0,
                secretKey: notOwnerKeyPair.secretKey,
                messages: [
                    senderArgsToMessageRelaxed({
                        to: vestingSender.address,
                        value: toNano('2'),
                        bounce: true
                    })
                ],
                sendMode: SendMode.PAY_GAS_SEPARATELY + SendMode.IGNORE_ERRORS,
                timeout: 60,
                subWalletId: SUB_WALLET_ID
            });
        } catch (e) {
            wasError = true;
        }

        expect(wasError).toBeTruthy()

        await checkLockupData(0);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);
    });

    it('external - invalid seqno', async () => {
        // blockchain.now = time;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        let wasError = false;

        try {
            const transferResult = await vestingWallet.sendExternalTransfer({
                seqno: 123,
                secretKey: ownerKeyPair.secretKey,
                messages: [
                    senderArgsToMessageRelaxed({
                        to: vestingSender.address,
                        value: toNano('2'),
                        bounce: true
                    })
                ],
                sendMode: SendMode.PAY_GAS_SEPARATELY + SendMode.IGNORE_ERRORS,
                timeout: 60,
                subWalletId: SUB_WALLET_ID
            });
        } catch (e) {
            wasError = true;
        }

        expect(wasError).toBeTruthy()

        await checkLockupData(0);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);
    });

    it('external - invalid subwalletId', async () => {
        // blockchain.now = time;

        const whitelistBefore = await vestingWallet.getWhitelist();
        expect(whitelistBefore.length).toBe(0);

        let wasError = false;

        try {
            const transferResult = await vestingWallet.sendExternalTransfer({
                seqno: 0,
                secretKey: ownerKeyPair.secretKey,
                messages: [
                    senderArgsToMessageRelaxed({
                        to: vestingSender.address,
                        value: toNano('2'),
                        bounce: true
                    })
                ],
                sendMode: SendMode.PAY_GAS_SEPARATELY + SendMode.IGNORE_ERRORS,
                timeout: 60,
                subWalletId: SUB_WALLET_ID + 1
            });
        } catch (e) {
            wasError = true;
        }

        expect(wasError).toBeTruthy()

        await checkLockupData(0);

        const whitelist = await vestingWallet.getWhitelist();
        expect(whitelist.length).toBe(0);
    });


});
