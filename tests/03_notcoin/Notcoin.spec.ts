import {
    Blockchain,
    SandboxContract,
    TreasuryContract,
    internal,
    BlockchainSnapshot,
    SendMessageResult,
    BlockchainTransaction,
} from '@ton/sandbox';
import {
    Cell,
    toNano,
    beginCell,
    Address,
    Transaction,
    storeAccountStorage,
    Dictionary,
    storeMessage,
    fromNano,
    DictionaryValue,
} from '@ton/core';
import { JettonWallet } from '../../wrappers/03_notcoin/JettonWallet';
import { jettonContentToCell, JettonMinter, JettonMinterContent } from '../../wrappers/03_notcoin/JettonMinter';
import '@ton/test-utils';
import { findTransactionRequired } from '@ton/test-utils';
import { randomAddress, getRandomTon, differentAddress, getRandomInt } from './utils';
import { Op, Errors } from '../../wrappers/03_notcoin/JettonConstants';
import {
    calcStorageFee,
    collectCellStats,
    computeFwdFees,
    computeFwdFeesVerbose,
    FullFees,
    GasPrices,
    getGasPrices,
    getMsgPrices,
    getStoragePrices,
    computedGeneric,
    storageGeneric,
    MsgPrices,
    setGasPrice,
    setMsgPrices,
    setStoragePrices,
    StorageStats,
    StorageValue,
    computeGasFee,
} from './gasUtils';
import { sha256 } from '@ton/crypto';
import { activateTVM11, myCompile } from "../my-compile";
import { GasLogAndSave } from '../gas-logger';

/*
   These tests check compliance with the TEP-74 and TEP-89,
   but also checks some implementation details.
   If you want to keep only TEP-74 and TEP-89 compliance tests,
   you need to remove/modify the following tests:
     mint tests (since minting is not covered by standard)
     exit_codes
     prove pathway
*/

//jetton params

let send_gas_fee: bigint;
let send_fwd_fee: bigint;
let receive_gas_fee: bigint;
let burn_gas_fee: bigint;
let burn_notification_fee: bigint;
let min_tons_for_storage: bigint;

const numericFolder = '03_notcoin';

let actualConstantsInGasTolk = {
    GAS_CONSUMPTION_JettonTransfer:   0n,       // are assigned on tests run
    GAS_CONSUMPTION_JettonReceive:    0n,       // and also exist in fees-management.tolk (embedded into a contract)
    GAS_CONSUMPTION_BurnRequest:      0n,       // they are expected be equal
    GAS_CONSUMPTION_BurnNotification: 0n,       // (otherwise, tests fail)
}

function printActualGasConstants() {
    let s = `
// these gas constants should be in \`fees-management.tolk\` ${numericFolder}:

const GAS_CONSUMPTION_JettonTransfer    = ${actualConstantsInGasTolk.GAS_CONSUMPTION_JettonTransfer}
const GAS_CONSUMPTION_JettonReceive     = ${actualConstantsInGasTolk.GAS_CONSUMPTION_JettonReceive}
const GAS_CONSUMPTION_BurnRequest       = ${actualConstantsInGasTolk.GAS_CONSUMPTION_BurnRequest}
const GAS_CONSUMPTION_BurnNotification  = ${actualConstantsInGasTolk.GAS_CONSUMPTION_BurnNotification}
`;
    console.log(s)      // when tests fail, probably fees-management.tolk should be updated
}

describe(numericFolder, () => {
    let GAS_LOG = new GasLogAndSave(numericFolder);
    let jwallet_code_raw = new Cell(); // true code
    let jwallet_code = new Cell(); // library cell with reference to jwallet_code_raw
    let minter_code = new Cell();
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let notDeployer: SandboxContract<TreasuryContract>;
    let jettonMinter: SandboxContract<JettonMinter>;
    let userWallet: (address: Address) => Promise<SandboxContract<JettonWallet>>;
    let walletStats: StorageStats;
    let msgPrices: MsgPrices;
    let gasPrices: GasPrices;
    let storagePrices: StorageValue;
    let storageDuration: number;
    let stateInitStats: StorageStats;
    let defaultOverhead: bigint;
    let defaultContent: JettonMinterContent;

    let printTxGasStats: (name: string, trans: Transaction) => bigint;
    let estimateBodyFee: (body: Cell, force_ref: boolean, prices?: MsgPrices) => FullFees;
    let estimateBurnFwd: (prices?: MsgPrices) => bigint;
    let forwardOverhead: (prices: MsgPrices, stats: StorageStats) => bigint;
    let estimateTransferFwd: (
        amount: bigint,
        fwd_amount: bigint,
        fwd_payload: Cell | null,
        custom_payload: Cell | null,
        prices?: MsgPrices,
    ) => bigint;
    let calcSendFees: (
        send_fee: bigint,
        recv_fee: bigint,
        fwd_fee: bigint,
        fwd_amount: bigint,
        storage_fee: bigint,
        state_init?: bigint,
    ) => bigint;
    let testBurnFees: (
        fees: bigint,
        to: Address,
        amount: bigint,
        exp: number,
        custom: Cell | null,
        prices?: MsgPrices,
    ) => Promise<Array<BlockchainTransaction>>;
    let testSendFees: (
        fees: bigint,
        fwd_amount: bigint,
        fwd: Cell | null,
        custom: Cell | null,
        exp: boolean,
    ) => Promise<void>;

    beforeAll(async () => {
        jwallet_code_raw = await myCompile(numericFolder, 'JettonWallet');
        minter_code = await myCompile(numericFolder, 'JettonMinter');
        GAS_LOG.rememberBocSize('minter', minter_code);
        GAS_LOG.rememberBocSize('wallet', jwallet_code_raw);
        blockchain = await Blockchain.create();
        activateTVM11(blockchain);
        blockchain.now = Math.floor(Date.now() / 1000);
        deployer = await blockchain.treasury('deployer');
        notDeployer = await blockchain.treasury('notDeployer');
        walletStats = new StorageStats(1033, 3);
        msgPrices = getMsgPrices(blockchain.config, 0);
        gasPrices = getGasPrices(blockchain.config, 0);
        storagePrices = getStoragePrices(blockchain.config);
        storageDuration = 5 * 365 * 24 * 3600;
        stateInitStats = new StorageStats(931, 3);
        defaultContent = {
            uri: 'https://some_stablecoin.org/meta.json',
        };

        //jwallet_code is library
        const _libs = Dictionary.empty(Dictionary.Keys.BigUint(256), Dictionary.Values.Cell());
        _libs.set(BigInt(`0x${jwallet_code_raw.hash().toString('hex')}`), jwallet_code_raw);
        const libs = beginCell().storeDictDirect(_libs).endCell();
        blockchain.libs = libs;
        let lib_prep = beginCell().storeUint(2, 8).storeBuffer(jwallet_code_raw.hash()).endCell();
        jwallet_code = new Cell({ exotic: true, bits: lib_prep.bits, refs: lib_prep.refs });

        jettonMinter = blockchain.openContract(
            JettonMinter.createFromConfig(
                {
                    admin: deployer.address,
                    wallet_code: jwallet_code,
                    jetton_content: jettonContentToCell(defaultContent),
                },
                minter_code,
            ),
        );
        userWallet = async (address: Address) =>
            blockchain.openContract(JettonWallet.createFromAddress(await jettonMinter.getWalletAddress(address)));

        printTxGasStats = (name, transaction) => {
            const txComputed = computedGeneric(transaction);
            // console.log(`${name} used ${txComputed.gasUsed} gas`);
            // console.log(`${name} gas cost: ${txComputed.gasFees}`);
            return txComputed.gasFees;
        };

        estimateBodyFee = (body, force_ref, prices) => {
            const curPrice = prices || msgPrices;
            const mockAddr = new Address(0, Buffer.alloc(32, 'A'));
            const testMsg = internal({
                from: mockAddr,
                to: mockAddr,
                value: toNano('1'),
                body,
            });
            const packed = beginCell()
                .store(storeMessage(testMsg, { forceRef: force_ref }))
                .endCell();
            const stats = collectCellStats(packed, [], true);
            return computeFwdFeesVerbose(prices || msgPrices, stats.cells, stats.bits);
        };
        estimateBurnFwd = (prices) => {
            const curPrices = prices || msgPrices;
            return computeFwdFees(curPrices, 1n, 754n);
        };
        forwardOverhead = (prices, stats) => {
            // Meh, kinda lazy way of doing that, but tests are bloated enough already
            return computeFwdFees(prices, stats.cells, stats.bits) - prices.lumpPrice;
        };
        estimateTransferFwd = (jetton_amount, fwd_amount, fwd_payload, custom_payload, prices) => {
            // Purpose is to account for the first biggest one fwd fee.
            // So, we use fwd_amount here only for body calculation

            const mockFrom = randomAddress(0);
            const mockTo = randomAddress(0);

            const body = JettonWallet.transferMessage(
                jetton_amount,
                mockTo,
                mockFrom,
                custom_payload,
                fwd_amount,
                fwd_payload,
            );

            const curPrices = prices || msgPrices;
            const feesRes = estimateBodyFee(body, true, curPrices);
            const reverse = (feesRes.remaining * 65536n) / (65536n - curPrices.firstFrac);
            expect(reverse).toBeGreaterThanOrEqual(feesRes.total);
            return reverse;
        };

        calcSendFees = (send, recv, fwd, fwd_amount, storage, state_init) => {
            const overhead = state_init || defaultOverhead;
            const fwdTotal = fwd_amount + (fwd_amount > 0n ? fwd * 2n : fwd) + overhead;
            const execute = send + recv;
            return fwdTotal + send + recv + storage + 1n;
        };

        testBurnFees = async (fees, to, amount, exp, custom_payload, prices) => {
            const burnWallet = await userWallet(deployer.address);
            let initialJettonBalance = await burnWallet.getJettonBalance();
            let initialTotalSupply = await jettonMinter.getTotalSupply();
            let burnTxs: Array<BlockchainTransaction> = [];
            const burnBody = JettonWallet.burnMessage(amount, to, custom_payload);
            const burnSender = blockchain.sender(deployer.address);
            const sendRes = await blockchain.sendMessage(
                internal({
                    from: deployer.address,
                    to: burnWallet.address,
                    value: fees,
                    forwardFee: estimateBodyFee(burnBody, false, prices || msgPrices).remaining,
                    body: burnBody,
                }),
            );
            if (exp == 0) {
                burnTxs.push(
                    findTransactionRequired(sendRes.transactions, {
                        on: burnWallet.address,
                        from: deployer.address,
                        op: Op.burn,
                        success: true,
                    }),
                );
                // We expect burn to succeed, but no excess
                burnTxs.push(
                    findTransactionRequired(sendRes.transactions, {
                        on: jettonMinter.address,
                        from: burnWallet.address,
                        op: Op.burn_notification,
                        success: true,
                    })!,
                );

                expect(await burnWallet.getJettonBalance()).toEqual(initialJettonBalance - amount);
                expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply - amount);
            } else {
                expect(sendRes.transactions).toHaveTransaction({
                    on: burnWallet.address,
                    from: deployer.address,
                    op: Op.burn,
                    success: false,
                    exitCode: exp,
                });
                expect(sendRes.transactions).not.toHaveTransaction({
                    on: jettonMinter.address,
                    from: burnWallet.address,
                    op: Op.burn_notification,
                });
                expect(await burnWallet.getJettonBalance()).toEqual(initialJettonBalance);
                expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply);
            }

            return burnTxs;
        };
        testSendFees = async (fees, fwd_amount, fwd_payload, custom_payload, exp) => {
            const deployerJettonWallet = await userWallet(deployer.address);
            let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
            const someUserAddr = randomAddress(0);
            const someWallet = await userWallet(someUserAddr);

            let jettonAmount = 1n;
            const sendResult = await deployerJettonWallet.sendTransfer(
                deployer.getSender(),
                fees,
                jettonAmount,
                someUserAddr,
                deployer.address,
                custom_payload,
                fwd_amount,
                fwd_payload,
            );

            if (exp) {
                expect(sendResult.transactions).toHaveTransaction({
                    on: someWallet.address,
                    op: Op.internal_transfer,
                    success: true,
                });
                if (fwd_amount > 0n) {
                    expect(sendResult.transactions).toHaveTransaction({
                        on: someUserAddr,
                        from: someWallet.address,
                        op: Op.transfer_notification,
                        body: (x) => {
                            if (fwd_payload === null) {
                                return true;
                            }
                            return x!.beginParse().preloadRef().equals(fwd_payload);
                        },
                        // We do not test for success, because receiving contract would be uninitialized
                    });
                }
                expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance - jettonAmount);
                expect(await someWallet.getJettonBalance()).toEqual(jettonAmount);
            } else {
                expect(sendResult.transactions).toHaveTransaction({
                    on: deployerJettonWallet.address,
                    from: deployer.address,
                    op: Op.transfer,
                    aborted: true,
                    success: false,
                    exitCode: Errors.not_enough_gas,
                });
                expect(sendResult.transactions).not.toHaveTransaction({
                    on: someWallet.address,
                });
            }
        };

        defaultOverhead = forwardOverhead(msgPrices, stateInitStats);
    });
    afterAll(() => {
        GAS_LOG.saveCurrentRunAfterAll();
        printActualGasConstants();
    });

    // implementation detail
    it('[bench] should deploy', async () => {
        const deployResult = await jettonMinter.sendDeploy(deployer.getSender(), toNano('10'));

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: jettonMinter.address,
            deploy: true,
        });
        // Make sure it didn't bounce
        expect(deployResult.transactions).not.toHaveTransaction({
            on: deployer.address,
            from: jettonMinter.address,
            inMessageBounced: true,
        });
    });
    // implementation detail
    it('[bench] minter admin should be able to mint jettons', async () => {
        // can mint from deployer
        let initialTotalSupply = await jettonMinter.getTotalSupply();
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = toNano('1000.23');
        const mintResult = await jettonMinter.sendMint(
            deployer.getSender(),
            deployer.address,
            initialJettonBalance,
            null,
            null,
            null,
            toNano('0.05'),
            toNano('1'),
        );

        const mintTx = findTransactionRequired(mintResult.transactions, {
            from: jettonMinter.address,
            to: deployerJettonWallet.address,
            deploy: true,
            success: true,
        });
        GAS_LOG.rememberGas('MINT jettons by admin', mintResult.transactions.slice(1));

        printTxGasStats('Mint transaction:', mintTx);
        /*
         * No excess in this jetton
        expect(mintResult.transactions).toHaveTransaction({ // excesses
            from: deployerJettonWallet.address,
            to: jettonMinter.address
        });
        */

        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance);
        expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply + initialJettonBalance);
        initialTotalSupply += initialJettonBalance;
        // can mint from deployer again
        let additionalJettonBalance = toNano('2.31');
        await jettonMinter.sendMint(
            deployer.getSender(),
            deployer.address,
            additionalJettonBalance,
            null,
            null,
            null,
            toNano('0.05'),
            toNano('1'),
        );
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance + additionalJettonBalance);
        expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply + additionalJettonBalance);
        initialTotalSupply += additionalJettonBalance;
        // can mint to other address
        let otherJettonBalance = toNano('3.12');
        await jettonMinter.sendMint(
            deployer.getSender(),
            notDeployer.address,
            otherJettonBalance,
            null,
            null,
            null,
            toNano('0.05'),
            toNano('1'),
        );
        const notDeployerJettonWallet = await userWallet(notDeployer.address);
        expect(await notDeployerJettonWallet.getJettonBalance()).toEqual(otherJettonBalance);
        expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply + otherJettonBalance);
    });

    // implementation detail
    it('not a minter admin should not be able to mint jettons', async () => {
        let initialTotalSupply = await jettonMinter.getTotalSupply();
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        const unAuthMintResult = await jettonMinter.sendMint(
            notDeployer.getSender(),
            deployer.address,
            toNano('777'),
            null,
            null,
            null,
            toNano('0.05'),
            toNano('1'),
        );

        expect(unAuthMintResult.transactions).toHaveTransaction({
            from: notDeployer.address,
            to: jettonMinter.address,
            aborted: true,
            exitCode: Errors.not_owner, // error::unauthorized_mint_request
        });
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance);
        expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply);
    });

    it('minter admin can change admin', async () => {
        const adminBefore = await jettonMinter.getAdminAddress();
        expect(adminBefore).toEqualAddress(deployer.address);
        let res = await jettonMinter.sendChangeAdmin(deployer.getSender(), notDeployer.address);
        expect(res.transactions).toHaveTransaction({
            from: deployer.address,
            on: jettonMinter.address,
            success: true,
        });

        res = await jettonMinter.sendClaimAdmin(notDeployer.getSender());

        expect(res.transactions).toHaveTransaction({
            from: notDeployer.address,
            on: jettonMinter.address,
            success: true,
        });

        const adminAfter = await jettonMinter.getAdminAddress();
        expect(adminAfter).toEqualAddress(notDeployer.address);
        await jettonMinter.sendChangeAdmin(notDeployer.getSender(), deployer.address);
        await jettonMinter.sendClaimAdmin(deployer.getSender());
        expect(await jettonMinter.getAdminAddress()).toEqualAddress(deployer.address);
    });
    it('not a minter admin can not change admin', async () => {
        const adminBefore = await jettonMinter.getAdminAddress();
        expect(adminBefore).toEqualAddress(deployer.address);
        let changeAdmin = await jettonMinter.sendChangeAdmin(notDeployer.getSender(), notDeployer.address);
        expect(await jettonMinter.getAdminAddress()).toEqualAddress(deployer.address);
        expect(changeAdmin.transactions).toHaveTransaction({
            from: notDeployer.address,
            on: jettonMinter.address,
            aborted: true,
            exitCode: Errors.not_owner, // error::unauthorized_change_admin_request
        });
    });
    it('only address specified in change admin action should be able to claim admin', async () => {
        const adminBefore = await jettonMinter.getAdminAddress();
        expect(adminBefore).toEqualAddress(deployer.address);
        let changeAdmin = await jettonMinter.sendChangeAdmin(deployer.getSender(), notDeployer.address);
        expect(changeAdmin.transactions).toHaveTransaction({
            from: deployer.address,
            on: jettonMinter.address,
            success: true,
        });

        // At this point transfer_admin is set to notDeployer.address
        const sneaky = differentAddress(notDeployer.address);
        changeAdmin = await jettonMinter.sendClaimAdmin(blockchain.sender(sneaky));
        expect(changeAdmin.transactions).toHaveTransaction({
            from: sneaky,
            on: jettonMinter.address,
            success: false,
            aborted: true,
        });
    });
    it('not admin should not be able to drop admin', async () => {
        const adminBefore = await jettonMinter.getAdminAddress();
        expect(adminBefore).toEqualAddress(deployer.address);

        const dropAdmin = await jettonMinter.sendDropAdmin(notDeployer.getSender());
        expect(dropAdmin.transactions).toHaveTransaction({
            on: jettonMinter.address,
            from: notDeployer.address,
            aborted: true,
        });

        expect(await jettonMinter.getAdminAddress()).toEqualAddress(adminBefore!);
    });
    it('minter admin should be able to drop admin', async () => {
        const prev = blockchain.snapshot();
        const adminBefore = await jettonMinter.getAdminAddress();
        expect(adminBefore).toEqualAddress(deployer.address);

        try {
            const dropAdmin = await jettonMinter.sendDropAdmin(deployer.getSender());
            expect(dropAdmin.transactions).toHaveTransaction({
                on: jettonMinter.address,
                from: deployer.address,
                op: Op.drop_admin,
                aborted: false,
            });
            expect(await jettonMinter.getAdminAddress()).toBe(null);
        } finally {
            await blockchain.loadFrom(prev);
        }
    });

    describe('Content tests', () => {
        let newContent: JettonMinterContent = {
            uri: `https://some_super_l${Buffer.alloc(200, '0')}ng_stable.org/`,
        };
        const snakeString: DictionaryValue<string> = {
            serialize: function (src, builder) {
                builder.storeUint(0, 8).storeStringTail(src);
            },
            parse: function (src) {
                let outStr = src.loadStringTail();
                if (outStr.charCodeAt(0) !== 0) {
                    throw new Error('No snake prefix');
                }
                return outStr.substr(1);
            },
        };
        const loadContent = (data: Cell) => {
            const ds = data.beginParse();
            expect(ds.loadUint(8)).toEqual(0);
            const content = ds.loadDict(Dictionary.Keys.Buffer(32), snakeString);
            expect(ds.remainingBits == 0 && ds.remainingRefs == 0).toBe(true);
            return content;
        };

        it('minter admin can change content', async () => {
            const oldContent = loadContent(await jettonMinter.getContent());
            expect(oldContent.get(await sha256('uri'))! === defaultContent.uri).toBe(true);
            //expect(oldContent.get(await sha256('decimals'))! === "6").toBe(true);
            let changeContent = await jettonMinter.sendChangeContent(deployer.getSender(), newContent);
            expect(changeContent.transactions).toHaveTransaction({
                on: jettonMinter.address,
                from: deployer.address,
                op: Op.change_metadata_url,
                success: true,
            });
            let contentUpd = loadContent(await jettonMinter.getContent());
            expect(contentUpd.get(await sha256('uri'))! == newContent.uri).toBe(true);
            // Update back;
            changeContent = await jettonMinter.sendChangeContent(deployer.getSender(), defaultContent);
            contentUpd = loadContent(await jettonMinter.getContent());
            expect(oldContent.get(await sha256('uri'))! === defaultContent.uri).toBe(true);
            //expect(oldContent.get(await sha256('decimals'))! === "6").toBe(true);
        });
        it('not a minter admin can not change content', async () => {
            const oldContent = loadContent(await jettonMinter.getContent());
            let changeContent = await jettonMinter.sendChangeContent(notDeployer.getSender(), newContent);
            expect(oldContent.get(await sha256('uri'))).toEqual(defaultContent.uri);
            //expect(oldContent.get(await sha256('decimals'))).toEqual("6");

            expect(changeContent.transactions).toHaveTransaction({
                from: notDeployer.address,
                to: jettonMinter.address,
                aborted: true,
                exitCode: Errors.not_owner,
            });
        });
    });

    it('storage stats', async () => {
        const prev = blockchain.snapshot();

        const deployerJettonWallet = await userWallet(deployer.address);
        const smc = await blockchain.getContract(deployerJettonWallet.address);
        const actualStats = collectCellStats(
            beginCell().store(storeAccountStorage(smc.account.account!.storage)).endCell(),
            [],
        );
        expect(walletStats.cells).toBeGreaterThanOrEqual(actualStats.cells);
        expect(walletStats.bits).toBeGreaterThanOrEqual(actualStats.bits);
        blockchain.now = blockchain.now! + storageDuration;
        const res = await deployerJettonWallet.sendBurn(deployer.getSender(), toNano('1'), 0n, null, null);
        const storagePhase = storageGeneric(res.transactions[1]);
        // min_tons_for_storage = storagePhase.storageFeesCollected;
        min_tons_for_storage = calcStorageFee(storagePrices, walletStats, BigInt(storageDuration));
        await blockchain.loadFrom(prev);
    });
    it('wallet owner should be able to send jettons', async () => {
        const prev = blockchain.snapshot();
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        let initialTotalSupply = await jettonMinter.getTotalSupply();
        const notDeployerJettonWallet = await userWallet(notDeployer.address);
        const balanceBefore = (await blockchain.getContract(notDeployerJettonWallet.address)).balance;
        let initialJettonBalance2 = await notDeployerJettonWallet.getJettonBalance();
        let sentAmount = toNano('0.5');
        let forwardAmount = toNano('0.05');
        const sendResult = await deployerJettonWallet.sendTransfer(
            deployer.getSender(),
            toNano('0.17'), //tons
            sentAmount,
            notDeployer.address,
            deployer.address,
            null,
            forwardAmount,
            null,
        );
        expect(sendResult.transactions).toHaveTransaction({
            //excesses
            on: deployer.address,
            from: notDeployerJettonWallet.address,
            op: Op.excesses,
            success: true,
        });

        expect(sendResult.transactions).toHaveTransaction({
            //notification
            from: notDeployerJettonWallet.address,
            to: notDeployer.address,
            value: forwardAmount,
        });

        const balanceAfter = (await blockchain.getContract(notDeployerJettonWallet.address)).balance;
        // Make sure we're not draining balance
        expect(balanceAfter).toBeGreaterThanOrEqual(balanceBefore);
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance - sentAmount);
        //sent amount should be unlocked after unlock time
        expect(await notDeployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance2 + sentAmount);
        expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply);
        await blockchain.loadFrom(prev);
    });

    it('not wallet owner should not be able to send jettons', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        let initialTotalSupply = await jettonMinter.getTotalSupply();
        const notDeployerJettonWallet = await userWallet(notDeployer.address);
        let initialJettonBalance2 = await notDeployerJettonWallet.getJettonBalance();
        let sentAmount = toNano('0.5');
        const sendResult = await deployerJettonWallet.sendTransfer(
            notDeployer.getSender(),
            toNano('0.1'), //tons
            sentAmount,
            notDeployer.address,
            deployer.address,
            null,
            toNano('0.05'),
            null,
        );
        expect(sendResult.transactions).toHaveTransaction({
            from: notDeployer.address,
            to: deployerJettonWallet.address,
            aborted: true,
            exitCode: Errors.not_owner, //error::unauthorized_transfer
        });
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance);
        expect(await notDeployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance2);
        expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply);
    });

    it('impossible to send too much jettons', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        const notDeployerJettonWallet = await userWallet(notDeployer.address);
        let initialJettonBalance2 = await notDeployerJettonWallet.getJettonBalance();
        let sentAmount = initialJettonBalance + 1n;
        let forwardAmount = toNano('0.05');
        const sendResult = await deployerJettonWallet.sendTransfer(
            deployer.getSender(),
            toNano('0.1'), //tons
            sentAmount,
            notDeployer.address,
            deployer.address,
            null,
            forwardAmount,
            null,
        );
        expect(sendResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: deployerJettonWallet.address,
            aborted: true,
            exitCode: Errors.balance_error, //error::not_enough_jettons
        });
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance);
        expect(await notDeployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance2);
    });

    describe('Malformed transfer', () => {
        let sendTransferPayload: (from: Address, to: Address, payload: Cell) => Promise<SendMessageResult>;
        let assertFailTransfer: <T extends Transaction>(
            from: Address,
            to: Address,
            txs: Array<T>,
            codes: Array<number>,
        ) => void;
        beforeAll(() => {
            sendTransferPayload = async (from, to, payload) => {
                return await blockchain.sendMessage(
                    internal({
                        from,
                        to,
                        body: payload,
                        value: toNano('1'),
                    }),
                );
            };
            assertFailTransfer = (from, to, txs, codes) => {
                expect(txs).toHaveTransaction({
                    on: to,
                    from,
                    aborted: true,
                    success: false,
                    exitCode: (c) => codes.includes(c!),
                });
                expect(txs).not.toHaveTransaction({
                    from: to,
                    op: Op.internal_transfer,
                });
            };
        });
        it('malfored custom payload', async () => {
            const deployerJettonWallet = await userWallet(deployer.address);
            const notDeployerJettonWallet = await userWallet(notDeployer.address);

            let sentAmount = toNano('0.5');
            let forwardPayload = beginCell().storeUint(getRandomInt(100000, 200000), 128).endCell();
            let customPayload = beginCell().storeUint(getRandomInt(100000, 200000), 128).endCell();

            let forwardTail = beginCell().storeCoins(toNano('0.05')).storeMaybeRef(forwardPayload);
            const msgTemplate = beginCell()
                .storeUint(0xf8a7ea5, 32)
                .storeUint(0, 64) // op, queryId
                .storeCoins(sentAmount)
                .storeAddress(notDeployer.address)
                .storeAddress(deployer.address);
            let testPayload = beginCell().storeBuilder(msgTemplate).storeBit(true).storeBuilder(forwardTail).endCell();

            let errCodes = [9, Errors.invalid_mesage];
            let res = await sendTransferPayload(deployer.address, deployerJettonWallet.address, testPayload);
            assertFailTransfer(deployer.address, deployerJettonWallet.address, res.transactions, errCodes);

            testPayload = beginCell()
                .storeBuilder(msgTemplate)
                .storeBit(false)
                .storeRef(customPayload)
                .storeBuilder(forwardTail)
                .endCell();
            res = await sendTransferPayload(deployer.address, deployerJettonWallet.address, testPayload);
            assertFailTransfer(deployer.address, deployerJettonWallet.address, res.transactions, errCodes);
            // Now self test that we didnt screw the payloads ourselves
            testPayload = beginCell()
                .storeBuilder(msgTemplate)
                .storeBit(true)
                .storeRef(customPayload)
                .storeBuilder(forwardTail)
                .endCell();

            res = await sendTransferPayload(deployer.address, deployerJettonWallet.address, testPayload);

            expect(res.transactions).toHaveTransaction({
                on: deployerJettonWallet.address,
                from: deployer.address,
                op: Op.transfer,
                success: true,
            });
        });
        it('malformed forward payload', async () => {
            const deployerJettonWallet = await userWallet(deployer.address);
            const notDeployerJettonWallet = await userWallet(notDeployer.address);

            let sentAmount = toNano('0.5');
            let forwardAmount = getRandomTon(0.01, 0.05); // toNano('0.05');
            let forwardPayload = beginCell().storeUint(0x1234567890abcdefn, 128).endCell();
            let msgTemplate = beginCell()
                .storeUint(0xf8a7ea5, 32)
                .storeUint(0, 64) // op, queryId
                .storeCoins(sentAmount)
                .storeAddress(notDeployer.address)
                .storeAddress(deployer.address)
                .storeMaybeRef(null)
                .storeCoins(toNano('0.05')); // No forward payload indication
            let errCodes = [9, Errors.invalid_mesage];
            let res = await sendTransferPayload(deployer.address, deployerJettonWallet.address, msgTemplate.endCell());

            assertFailTransfer(deployer.address, deployerJettonWallet.address, res.transactions, errCodes);

            // Now test that we can't send message without payload if either flag is set
            let testPayload = beginCell().storeBuilder(msgTemplate).storeBit(true).endCell();
            res = await sendTransferPayload(deployer.address, deployerJettonWallet.address, testPayload);

            assertFailTransfer(deployer.address, deployerJettonWallet.address, res.transactions, errCodes);
            // Now valid payload
            testPayload = beginCell().storeBuilder(msgTemplate).storeBit(true).storeRef(forwardPayload).endCell();

            res = await sendTransferPayload(deployer.address, deployerJettonWallet.address, testPayload);

            expect(res.transactions).toHaveTransaction({
                from: deployer.address,
                to: deployerJettonWallet.address,
                op: Op.transfer,
                success: true,
            });
        });
    });

    it('[bench] correctly sends forward_payload', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        const notDeployerJettonWallet = await userWallet(notDeployer.address);
        let initialJettonBalance2 = await notDeployerJettonWallet.getJettonBalance();
        let sentAmount = toNano('0.5');
        let forwardAmount = toNano('0.05');
        let forwardPayload = beginCell().storeUint(0x1234567890abcdefn, 128).endCell();
        // Make sure payload is different, so cell load is charged for each individual payload.
        let customPayload = beginCell().storeUint(0xfedcba0987654321n, 128).endCell();
        // Let's use this case for fees calculation
        // Put the forward payload into custom payload, to make sure maximum possible gas used during computation
        const sendResult = await deployerJettonWallet.sendTransfer(
            deployer.getSender(),
            toNano('0.17'), //tons
            sentAmount,
            notDeployer.address,
            deployer.address,
            customPayload,
            forwardAmount,
            forwardPayload,
        );
        GAS_LOG.rememberGas('TRANSFER with forward_amount', sendResult.transactions.slice(1));
        expect(sendResult.transactions).toHaveTransaction({
            //excesses
            from: notDeployerJettonWallet.address,
            to: deployer.address,
        });
        /*
        transfer_notification#7362d09c query_id:uint64 amount:(VarUInteger 16)
                                      sender:MsgAddress forward_payload:(Either Cell ^Cell)
                                      = InternalMsgBody;
        */
        expect(sendResult.transactions).toHaveTransaction({
            //notification
            from: notDeployerJettonWallet.address,
            to: notDeployer.address,
            value: forwardAmount,
            body: beginCell()
                .storeUint(Op.transfer_notification, 32)
                .storeUint(0, 64) //default queryId
                .storeCoins(sentAmount)
                .storeAddress(deployer.address)
                .storeUint(1, 1)
                .storeRef(forwardPayload)
                .endCell(),
        });
        const transferTx = findTransactionRequired(sendResult.transactions, {
            on: deployerJettonWallet.address,
            from: deployer.address,
            op: Op.transfer,
            success: true,
        });
        send_gas_fee = printTxGasStats('Jetton transfer', transferTx);
        actualConstantsInGasTolk.GAS_CONSUMPTION_JettonTransfer = computedGeneric(transferTx).gasUsed;
        // let mockGas = computeGasFee(gasPrices, 10065n);
        // expect(mockGas).toBeGreaterThanOrEqual(send_gas_fee);
        // send_gas_fee = mockGas;

        const receiveTx = findTransactionRequired(sendResult.transactions, {
            on: notDeployerJettonWallet.address,
            from: deployerJettonWallet.address,
            op: Op.internal_transfer,
            success: true,
        });
        receive_gas_fee = printTxGasStats('Receive jetton', receiveTx);
        actualConstantsInGasTolk.GAS_CONSUMPTION_JettonReceive = computedGeneric(receiveTx).gasUsed;
        // mockGas = computeGasFee(gasPrices, 10435n);
        // expect(mockGas).toBeGreaterThanOrEqual(receive_gas_fee);
        // receive_gas_fee = mockGas;

        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance - sentAmount);
        expect(await notDeployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance2 + sentAmount);
    });

    it('no forward_ton_amount - no forward', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        const notDeployerJettonWallet = await userWallet(notDeployer.address);
        let initialJettonBalance2 = await notDeployerJettonWallet.getJettonBalance();
        let sentAmount = toNano('0.5');
        let forwardAmount = 0n;
        let forwardPayload = beginCell().storeUint(0x1234567890abcdefn, 128).endCell();
        const sendResult = await deployerJettonWallet.sendTransfer(
            deployer.getSender(),
            toNano('0.1'), //tons
            sentAmount,
            notDeployer.address,
            deployer.address,
            null,
            forwardAmount,
            forwardPayload,
        );
        expect(sendResult.transactions).toHaveTransaction({
            //excesses
            from: notDeployerJettonWallet.address,
            to: deployer.address,
        });

        expect(sendResult.transactions).not.toHaveTransaction({
            //no notification
            from: notDeployerJettonWallet.address,
            to: notDeployer.address,
        });
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance - sentAmount);
        expect(await notDeployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance2 + sentAmount);
    });


    it('[bench] transfer (with other params to get desired initial FunC gas)', async () => {
        const deployerJettonWalletNotcoin = await userWallet(deployer.address);
        const mintResult = await jettonMinter.sendMint(
            deployer.getSender(),
            deployer.address,
            toNano(100000),
            null,
            null,
            null,
            toNano('0.05'),
            toNano('1'),
        );

        expect(mintResult.transactions).toHaveTransaction({
            from: jettonMinter.address,
            to: deployerJettonWalletNotcoin.address,
            success: true,
            endStatus: 'active',
        });

        const someAddress = Address.parse('EQD__________________________________________0vo');

        const sendResult = await deployerJettonWalletNotcoin.sendTransfer(
            deployer.getSender(),
            toNano(1),
            1n,
            someAddress,
            deployer.address,
            null,
            0n,
            null,
        );

        expect(sendResult.transactions).not.toHaveTransaction({
            success: false,
        });

        expect(sendResult.transactions).toHaveTransaction({
            from: deployerJettonWalletNotcoin.address,
            success: true,
            exitCode: 0,
        });

        GAS_LOG.rememberGas('TRANSFER no forward_amount', sendResult.transactions.slice(1));
    });

    it('check revert on not enough tons for forward', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        await deployer.send({ value: toNano('1'), bounce: false, to: deployerJettonWallet.address });
        let sentAmount = toNano('0.1');
        let forwardAmount = toNano('0.3');
        let forwardPayload = beginCell().storeUint(0x1234567890abcdefn, 128).endCell();
        const sendResult = await deployerJettonWallet.sendTransfer(
            deployer.getSender(),
            forwardAmount, // not enough tons, no tons for gas
            sentAmount,
            notDeployer.address,
            deployer.address,
            null,
            forwardAmount,
            forwardPayload,
        );
        expect(sendResult.transactions).toHaveTransaction({
            from: deployer.address,
            on: deployerJettonWallet.address,
            aborted: true,
            exitCode: Errors.not_enough_gas, //error::not_enough_tons
        });
        // Make sure value bounced
        expect(sendResult.transactions).toHaveTransaction({
            from: deployerJettonWallet.address,
            on: deployer.address,
            inMessageBounced: true,
            success: true,
        });

        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance);
    });

    describe('Transfer dynamic fees', () => {
        // implementation detail
        it('works with minimal ton amount', async () => {
            // No forward_amount and forward_
            let jettonAmount = 1n;
            let forwardAmount = 0n;
            let minFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, null, null);
            /*
                         forward_ton_amount +
                         fwd_count * fwd_fee +
                         (2 * gas_consumption + min_tons_for_storage));
            */
            let minimalFee = calcSendFees(
                send_gas_fee,
                receive_gas_fee,
                minFwdFee,
                forwardAmount,
                min_tons_for_storage,
            );
            // Off by one should faile
            await testSendFees(minimalFee - 1n, forwardAmount, null, null, false);
            // Now should succeed
            await testSendFees(minimalFee, forwardAmount, null, null, true);
        });
        it('forward_payload should impact transfer fees', async () => {
            let jettonAmount = 1n;
            let forwardAmount = 0n;
            let forwardPayload = beginCell().storeUint(0x123456789abcdef, 128).endCell();

            // We estimate without forward payload
            let minFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, null, null);
            let minimalFee = calcSendFees(
                send_gas_fee,
                receive_gas_fee,
                minFwdFee,
                forwardAmount,
                min_tons_for_storage,
            );
            // Should fail
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, false);
            // We should re-estimate now
            minFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, forwardPayload, null);
            minimalFee = calcSendFees(send_gas_fee, receive_gas_fee, minFwdFee, forwardAmount, min_tons_for_storage);
            // Add succeed
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);
            // Now let's see if increase in size would impact fee.
            forwardPayload = beginCell()
                .storeUint(getRandomInt(100000, 200000), 128)
                .storeRef(forwardPayload)
                .endCell();
            // Should fail now
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, false);

            minFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, forwardPayload, null);
            minimalFee = calcSendFees(send_gas_fee, receive_gas_fee, minFwdFee, forwardAmount, min_tons_for_storage);
            // And succeed again, after updating calculations
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);
            // Custom payload impacts fee, because forwardAmount is calculated based on inMsg fwdFee field
            /*
            const customPayload = beginCell().storeUint(getRandomInt(100000, 200000), 128).endCell();
            await testSendFees(minimalFee, forwardAmount, forwardPayload, customPayload, true);
            */
        });
        it('forward amount > 0 should account for forward fee twice', async () => {
            let jettonAmount = 1n;
            let forwardAmount = toNano('0.05');
            let forwardPayload = beginCell().storeUint(0x123456789abcdef, 128).endCell();

            let minFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, forwardPayload, null);
            // We estimate without forward amount
            let minimalFee = calcSendFees(send_gas_fee, receive_gas_fee, minFwdFee, 0n, min_tons_for_storage);
            // Should fail
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, false);
            // Adding forward fee once more + forwardAmount should end up in successfull transfer
            minimalFee += minFwdFee + forwardAmount;
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);
            // Make sure this is actual edge value and not just excessive amount
            // Off by one should fail
            await testSendFees(minimalFee - 1n, forwardAmount, forwardPayload, null, false);
        });
        it('forward fees should be calculated using actual config values', async () => {
            let jettonAmount = 1n;
            let forwardAmount = toNano('0.05');
            let forwardPayload = beginCell().storeUint(0x123456789abcdef, 128).endCell();

            let minFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, forwardPayload, null);
            // We estimate everything correctly
            let minimalFee = calcSendFees(
                send_gas_fee,
                receive_gas_fee,
                minFwdFee,
                forwardAmount,
                min_tons_for_storage,
            );
            // Results in the successfull transfer
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);

            const oldConfig = blockchain.config;
            const newPrices: MsgPrices = {
                ...msgPrices,
                bitPrice: msgPrices.bitPrice * 10n,
                cellPrice: msgPrices.cellPrice * 10n,
            };
            blockchain.setConfig(setMsgPrices(blockchain.config, newPrices, 0));

            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, false);

            const newFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, forwardPayload, null, newPrices);

            minimalFee += (newFwdFee - minFwdFee) * 2n + defaultOverhead * 9n;

            /*
             * We can't do it like this anymore, because change in forward prices
             * also may change rounding in reverse fee calculation
            // Delta is 18 times old fee because oldFee x 2 is already accounted
            // for two forward
            const newOverhead = forwardOverhead(newPrices, stateInitStats);
            minimalFee += (minFwdFee - msgPrices.lumpPrice) * 18n + defaultOverhead * 9n;
            */
            // Should succeed now
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);
            // Testing edge
            await testSendFees(minimalFee - 1n, forwardAmount, forwardPayload, null, false);
            // Rolling config back
            blockchain.setConfig(oldConfig);
        });
        it('gas fees for transfer should be calculated from actual config', async () => {
            let jettonAmount = 1n;
            let forwardAmount = toNano('0.05');
            let forwardPayload = beginCell().storeUint(0x123456789abcdef, 128).endCell();

            let minFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, forwardPayload, null);
            // We estimate everything correctly
            let minimalFee = calcSendFees(
                send_gas_fee,
                receive_gas_fee,
                minFwdFee,
                forwardAmount,
                min_tons_for_storage,
            );
            // Results in the successfull transfer
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);
            const oldConfig = blockchain.config;
            blockchain.setConfig(
                setGasPrice(
                    oldConfig,
                    {
                        ...gasPrices,
                        gas_price: gasPrices.gas_price * 3n,
                    },
                    0,
                ),
            );
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, false);
            // add gas delta
            minimalFee +=
                (send_gas_fee - gasPrices.flat_gas_price) * 2n + (receive_gas_fee - gasPrices.flat_gas_price) * 2n;
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);
            // Test edge
            await testSendFees(minimalFee - 1n, forwardAmount, forwardPayload, null, false);
            blockchain.setConfig(oldConfig);
        });
        it('storage fee for transfer should be calculated from actual config', async () => {
            let jettonAmount = 1n;
            let forwardAmount = toNano('0.05');
            let forwardPayload = beginCell().storeUint(0x123456789abcdef, 128).endCell();

            let minFwdFee = estimateTransferFwd(jettonAmount, forwardAmount, forwardPayload, null);
            // We estimate everything correctly
            let minimalFee = calcSendFees(
                send_gas_fee,
                receive_gas_fee,
                minFwdFee,
                forwardAmount,
                min_tons_for_storage,
            );
            // Results in the successfull transfer
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);

            const oldConfig = blockchain.config;
            const newPrices = {
                ...storagePrices,
                bit_price_ps: storagePrices.bit_price_ps * 10n,
                cell_price_ps: storagePrices.cell_price_ps * 10n,
            };

            blockchain.setConfig(setStoragePrices(oldConfig, newPrices));

            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, false);

            const newStorageFee = calcStorageFee(newPrices, walletStats, BigInt(5 * 365 * 24 * 3600));
            minimalFee += newStorageFee - min_tons_for_storage;
            await testSendFees(minimalFee, forwardAmount, forwardPayload, null, true);
            // Tet edge
            await testSendFees(minimalFee - 1n, forwardAmount, forwardPayload, null, false);
            blockchain.setConfig(oldConfig);
        });
    });

    // implementation detail
    it('wallet does not accept internal_transfer not from wallet', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        /*
          internal_transfer  query_id:uint64 amount:(VarUInteger 16) from:MsgAddress
                             response_address:MsgAddress
                             forward_ton_amount:(VarUInteger 16)
                             forward_payload:(Either Cell ^Cell)
                             = InternalMsgBody;
        */
        let internalTransfer = beginCell()
            .storeUint(0x178d4519, 32)
            .storeUint(0, 64) //default queryId
            .storeCoins(toNano('0.01'))
            .storeAddress(deployer.address)
            .storeAddress(deployer.address)
            .storeCoins(toNano('0.05'))
            .storeUint(0, 1)
            .endCell();
        const sendResult = await blockchain.sendMessage(
            internal({
                from: notDeployer.address,
                to: deployerJettonWallet.address,
                body: internalTransfer,
                value: toNano('0.3'),
            }),
        );
        expect(sendResult.transactions).toHaveTransaction({
            from: notDeployer.address,
            to: deployerJettonWallet.address,
            aborted: true,
            exitCode: Errors.not_valid_wallet, //error::unauthorized_incoming_transfer
        });
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance);
    });

    // Yeah, you got that right
    // Wallet owner should not be able to burn it's jettons
    it('[bench] wallet owner should be able to burn jettons', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        let initialTotalSupply = await jettonMinter.getTotalSupply();
        let burnAmount = toNano('0.01');
        const sendResult = await deployerJettonWallet.sendBurn(
            deployer.getSender(),
            toNano('0.1'), // ton amount
            burnAmount,
            deployer.address,
            null,
        ); // amount, response address, custom payload
        GAS_LOG.rememberGas('BURN jettons', sendResult.transactions.slice(1));
        expect(sendResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: deployerJettonWallet.address,
            aborted: false,
        });
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance - burnAmount);
        expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply - burnAmount);

        const actualSent = printTxGasStats('Burn transaction', sendResult.transactions[1]);
        actualConstantsInGasTolk.GAS_CONSUMPTION_BurnRequest = computedGeneric(sendResult.transactions[1]).gasUsed;
        const actualRecv = printTxGasStats('Burn notification transaction', sendResult.transactions[2]);
        actualConstantsInGasTolk.GAS_CONSUMPTION_BurnNotification = computedGeneric(sendResult.transactions[2]).gasUsed;
        burn_gas_fee          = actualSent;
        burn_notification_fee = actualRecv;
        /*
        burn_gas_fee = computeGasFee(gasPrices, 5891n);
        burn_notification_fee = computeGasFee(gasPrices, 6757n);
        expect(burn_gas_fee).toBeGreaterThanOrEqual(actualSent);
        expect(burn_notification_fee).toBeGreaterThanOrEqual(actualRecv);
         */
    });

    it('not wallet owner should not be able to burn jettons', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        let initialTotalSupply = await jettonMinter.getTotalSupply();
        let burnAmount = toNano('0.01');
        const sendResult = await deployerJettonWallet.sendBurn(
            notDeployer.getSender(),
            toNano('0.1'), // ton amount
            burnAmount,
            deployer.address,
            null,
        ); // amount, response address, custom payload
        expect(sendResult.transactions).toHaveTransaction({
            from: notDeployer.address,
            to: deployerJettonWallet.address,
            aborted: true,
            exitCode: Errors.not_owner, //error::unauthorized_transfer
        });
        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance);
        expect(await jettonMinter.getTotalSupply()).toEqual(initialTotalSupply);
    });

    it('wallet owner can not burn more jettons than it has', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        let initialTotalSupply = await jettonMinter.getTotalSupply();
        let burnAmount = initialJettonBalance + 1n;
        let msgValue = toNano('1');
        await testBurnFees(msgValue, deployer.address, burnAmount, Errors.balance_error, null);
    });

    describe('Burn dynamic fees', () => {
        it('minimal burn message fee', async () => {
            let burnAmount = toNano('0.01');
            const burnFwd = estimateBurnFwd();
            let minimalFee = burnFwd + burn_gas_fee + burn_notification_fee + 1n;

            // Off by one
            await testBurnFees(minimalFee - 1n, deployer.address, burnAmount, Errors.not_enough_gas, null);
            // Now should succeed
            await testBurnFees(minimalFee, deployer.address, burnAmount, 0, null);
        });
        // Now custom payload does impacf forward fee, because it is calculated from input message fwdFee
        it('burn custom payload should not impact fees', async () => {
            let burnAmount = toNano('0.01');
            const customPayload = beginCell().storeUint(getRandomInt(1000, 2000), 256).endCell();
            const burnFwd = estimateBurnFwd();
            let minimalFee = burnFwd + burn_gas_fee + burn_notification_fee + 1n;
            await testBurnFees(minimalFee, deployer.address, burnAmount, 0, customPayload);
        });
        it('burn forward fee should be calculated from actual config values', async () => {
            let burnAmount = toNano('0.01');
            let burnFwd = estimateBurnFwd();
            let minimalFee = burnFwd + burn_gas_fee + burn_notification_fee + 1n;
            // Succeeds initally

            await testBurnFees(minimalFee, deployer.address, burnAmount, 0, null);

            const oldConfig = blockchain.config;
            const newPrices: MsgPrices = {
                ...msgPrices,
                bitPrice: msgPrices.bitPrice * 10n,
                cellPrice: msgPrices.cellPrice * 10n,
            };
            blockchain.setConfig(setMsgPrices(blockchain.config, newPrices, 0));
            // Now fail
            await testBurnFees(minimalFee, deployer.address, burnAmount, Errors.not_enough_gas, null, newPrices);
            const newFwd = estimateBurnFwd(newPrices);
            minimalFee += newFwd - burnFwd;
            // Success again
            await testBurnFees(minimalFee, deployer.address, burnAmount, 0, null, newPrices);
            // Check edge
            await testBurnFees(minimalFee - 1n, deployer.address, burnAmount, Errors.not_enough_gas, null, newPrices);
            blockchain.setConfig(oldConfig);
        });
        it('burn gas fees should be calculated from actual config values', async () => {
            let burnAmount = toNano('0.01');
            const burnFwd = estimateBurnFwd();
            let minimalFee = burnFwd + burn_gas_fee + burn_notification_fee + 1n;
            // Succeeds initally
            await testBurnFees(minimalFee, deployer.address, burnAmount, 0, null);
            const oldConfig = blockchain.config;
            blockchain.setConfig(
                setGasPrice(
                    oldConfig,
                    {
                        ...gasPrices,
                        gas_price: gasPrices.gas_price * 130n / 100n
                    },
                    0,
                ),
            );
            await testBurnFees(minimalFee, deployer.address, burnAmount, Errors.not_enough_gas, null);

            minimalFee +=
                (burn_gas_fee - gasPrices.flat_gas_price) / 10n * 3n +
                (burn_notification_fee - gasPrices.flat_gas_price) / 10n * 3n;

            await testBurnFees(minimalFee, deployer.address, burnAmount, 0, null);
            // Verify edge
            await testBurnFees(minimalFee - 1n, deployer.address, burnAmount, Errors.not_enough_gas, null);
            blockchain.setConfig(oldConfig);
        });
    });

    it('minter should only accept burn messages from jetton wallets', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        const burnAmount = toNano('1');
        const burnNotification = (amount: bigint, addr: Address) => {
            return beginCell()
                .storeUint(Op.burn_notification, 32)
                .storeUint(0, 64)
                .storeCoins(amount)
                .storeAddress(addr)
                .storeAddress(deployer.address)
                .endCell();
        };

        let res = await blockchain.sendMessage(
            internal({
                from: deployerJettonWallet.address,
                to: jettonMinter.address,
                body: burnNotification(burnAmount, randomAddress(0)),
                value: toNano('0.1'),
            }),
        );

        expect(res.transactions).toHaveTransaction({
            from: deployerJettonWallet.address,
            to: jettonMinter.address,
            aborted: true,
            exitCode: Errors.not_valid_wallet, // Unauthorized burn
        });

        res = await blockchain.sendMessage(
            internal({
                from: deployerJettonWallet.address,
                to: jettonMinter.address,
                body: burnNotification(burnAmount, deployer.address),
                value: toNano('0.1'),
            }),
        );

        expect(res.transactions).toHaveTransaction({
            from: deployerJettonWallet.address,
            to: jettonMinter.address,
            success: true,
        });
    });

    // TEP-89
    it('[bench] report correct discovery address', async () => {
        let discoveryResult = await jettonMinter.sendDiscovery(deployer.getSender(), deployer.address, true);
        GAS_LOG.rememberGas('DISCOVER with include_address', discoveryResult.transactions.slice(1));
        /*
          take_wallet_address#d1735400 query_id:uint64 wallet_address:MsgAddress owner_address:(Maybe ^MsgAddress) = InternalMsgBody;
        */
        const deployerJettonWallet = await userWallet(deployer.address);

        const discoveryTx = findTransactionRequired(discoveryResult.transactions, {
            from: jettonMinter.address,
            to: deployer.address,
            body: beginCell()
                .storeUint(Op.take_wallet_address, 32)
                .storeUint(0, 64)
                .storeAddress(deployerJettonWallet.address)
                .storeUint(1, 1)
                .storeRef(beginCell().storeAddress(deployer.address).endCell())
                .endCell(),
        });

        printTxGasStats('Discovery transaction', discoveryTx);

        discoveryResult = await jettonMinter.sendDiscovery(deployer.getSender(), notDeployer.address, true);
        const notDeployerJettonWallet = await userWallet(notDeployer.address);
        expect(discoveryResult.transactions).toHaveTransaction({
            from: jettonMinter.address,
            to: deployer.address,
            body: beginCell()
                .storeUint(Op.take_wallet_address, 32)
                .storeUint(0, 64)
                .storeAddress(notDeployerJettonWallet.address)
                .storeUint(1, 1)
                .storeRef(beginCell().storeAddress(notDeployer.address).endCell())
                .endCell(),
        });

        // do not include owner address
        discoveryResult = await jettonMinter.sendDiscovery(deployer.getSender(), notDeployer.address, false);
        GAS_LOG.rememberGas('DISCOVER no include_address', discoveryResult.transactions.slice(1));
        expect(discoveryResult.transactions).toHaveTransaction({
            from: jettonMinter.address,
            to: deployer.address,
            body: beginCell()
                .storeUint(Op.take_wallet_address, 32)
                .storeUint(0, 64)
                .storeAddress(notDeployerJettonWallet.address)
                .storeUint(0, 1)
                .endCell(),
        });
    });

    // it.skip('Minimal discovery fee', ...);

    it('Correctly handles not valid address in discovery', async () => {
        const badAddr = randomAddress(-1);
        let discoveryResult = await jettonMinter.sendDiscovery(deployer.getSender(), badAddr, false);

        expect(discoveryResult.transactions).toHaveTransaction({
            from: jettonMinter.address,
            to: deployer.address,
            body: beginCell()
                .storeUint(Op.take_wallet_address, 32)
                .storeUint(0, 64)
                .storeUint(0, 2) // addr_none
                .storeUint(0, 1)
                .endCell(),
        });

        // Include address should still be available

        discoveryResult = await jettonMinter.sendDiscovery(deployer.getSender(), badAddr, true); // Include addr

        expect(discoveryResult.transactions).toHaveTransaction({
            from: jettonMinter.address,
            to: deployer.address,
            body: beginCell()
                .storeUint(Op.take_wallet_address, 32)
                .storeUint(0, 64)
                .storeUint(0, 2) // addr_none
                .storeUint(1, 1)
                .storeRef(beginCell().storeAddress(badAddr).endCell())
                .endCell(),
        });
    });

    // This test consume a lot of time: 18 sec
    // and is needed only for measuring ton accruing
    /*it('jettonWallet can process 250 transfer', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let initialJettonBalance = await deployerJettonWallet.getJettonBalance();
        const notDeployerJettonWallet = await userWallet(notDeployer.address);
        let initialJettonBalance2 = await notDeployerJettonWallet.getJettonBalance();
        let sentAmount = 1n, count = 250n;
        let forwardAmount = toNano('0.05');
        let sendResult: any;
        let payload = beginCell()
                          .storeUint(0x12345678, 32).storeUint(0x87654321, 32)
                          .storeRef(beginCell().storeUint(0x12345678, 32).storeUint(0x87654321, 108).endCell())
                          .storeRef(beginCell().storeUint(0x12345671, 32).storeUint(0x87654321, 240).endCell())
                          .storeRef(beginCell().storeUint(0x12345672, 32).storeUint(0x87654321, 77)
                                               .storeRef(beginCell().endCell())
                                               .storeRef(beginCell().storeUint(0x1245671, 91).storeUint(0x87654321, 32).endCell())
                                               .storeRef(beginCell().storeUint(0x2245671, 180).storeUint(0x87654321, 32).endCell())
                                               .storeRef(beginCell().storeUint(0x8245671, 255).storeUint(0x87654321, 32).endCell())
                                    .endCell())
                      .endCell();
        let initialBalance =(await blockchain.getContract(deployerJettonWallet.address)).balance;
        let initialBalance2 = (await blockchain.getContract(notDeployerJettonWallet.address)).balance;
        for(let i = 0; i < count; i++) {
            sendResult = await deployerJettonWallet.sendTransferMessage(deployer.getSender(), toNano('0.1'), //tons
                   sentAmount, notDeployer.address,
                   deployer.address, null, forwardAmount, payload);
        }
        // last chain was successful
        expect(sendResult.transactions).toHaveTransaction({ //excesses
            from: notDeployerJettonWallet.address,
            to: deployer.address,
        });
        expect(sendResult.transactions).toHaveTransaction({ //notification
            from: notDeployerJettonWallet.address,
            to: notDeployer.address,
            value: forwardAmount
        });

        expect(await deployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance - sentAmount*count);
        expect(await notDeployerJettonWallet.getJettonBalance()).toEqual(initialJettonBalance2 + sentAmount*count);

        let finalBalance =(await blockchain.getContract(deployerJettonWallet.address)).balance;
        let finalBalance2 = (await blockchain.getContract(notDeployerJettonWallet.address)).balance;

        // if it is not true, it's ok but gas_consumption constant is too high
        // and excesses of TONs will be accrued on wallet
        expect(finalBalance).toBeLessThan(initialBalance + toNano('0.001'));
        expect(finalBalance2).toBeLessThan(initialBalance2 + toNano('0.001'));
        expect(finalBalance).toBeGreaterThan(initialBalance - toNano('0.001'));
        expect(finalBalance2).toBeGreaterThan(initialBalance2 - toNano('0.001'));

    });
    */
    // implementation detail
    it('can not send to masterchain', async () => {
        const deployerJettonWallet = await userWallet(deployer.address);
        let sentAmount = toNano('0.5');
        let forwardAmount = toNano('0.05');
        const sendResult = await deployerJettonWallet.sendTransfer(
            deployer.getSender(),
            toNano('0.1'), //tons
            sentAmount,
            Address.parse('Ef8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAU'),
            deployer.address,
            null,
            forwardAmount,
            null,
        );
        expect(sendResult.transactions).toHaveTransaction({
            //excesses
            from: deployer.address,
            to: deployerJettonWallet.address,
            aborted: true,
            exitCode: Errors.wrong_workchain, //error::wrong_workchain
        });
    });

    describe('Remove governance', () => {
        // Idea is to check that previous governance functionality is removed completely
        let testPayload: (payload: Cell, from: Address, to: Address, code: number) => Promise<SendMessageResult>;
        beforeAll(() => {
            testPayload = async (payload, from, to, code) => {
                const res = await blockchain.sendMessage(
                    internal({
                        from,
                        to,
                        body: payload,
                        value: toNano('1'),
                    }),
                );
                expect(res.transactions).toHaveTransaction({
                    on: to,
                    from,
                    aborted: code !== 0,
                    exitCode: code,
                });

                return res;
            };
        });
        it('minter should not be able to force burn tokens', async () => {
            const notDeployerWallet = await userWallet(notDeployer.address);

            const burnMessage = JettonWallet.burnMessage(1n, null, null);
            const balanceBefore = await notDeployerWallet.getJettonBalance();
            expect(balanceBefore).toBeGreaterThan(0n);

            const res = await testPayload(
                burnMessage,
                jettonMinter.address,
                notDeployerWallet.address,
                Errors.not_owner,
            );
            expect(res.transactions).not.toHaveTransaction({
                on: jettonMinter.address,
                from: notDeployerWallet.address,
                inMessageBounced: false,
            });

            expect(await notDeployerWallet.getJettonBalance()).toEqual(balanceBefore);

            // Self check
            await testPayload(burnMessage, notDeployer.address, notDeployerWallet.address, 0);
            expect(await notDeployerWallet.getJettonBalance()).toEqual(balanceBefore - 1n);
        });
        it('minter should not be able to force transfer tokens', async () => {
            const testAddr = randomAddress();
            const testJetton = await userWallet(testAddr);
            const notDeployerWallet = await userWallet(notDeployer.address);
            const balanceBefore = await notDeployerWallet.getJettonBalance();
            expect(balanceBefore).toBeGreaterThan(0n);

            const transferMsg = JettonWallet.transferMessage(1n, testAddr, notDeployer.address, null, 0n, null);

            let res = await testPayload(transferMsg, jettonMinter.address, notDeployerWallet.address, Errors.not_owner);
            expect(await notDeployerWallet.getJettonBalance()).toEqual(balanceBefore);
            expect(res.transactions).not.toHaveTransaction({
                on: testJetton.address,
                from: notDeployerWallet.address,
            });
            // Self check
            await testPayload(transferMsg, notDeployer.address, notDeployerWallet.address, 0);
            expect(await notDeployerWallet.getJettonBalance()).toEqual(balanceBefore - 1n);
            expect(await testJetton.getJettonBalance()).toBe(1n);
        });
    });

    describe('Bounces', () => {
        it('minter should restore supply on internal_transfer bounce', async () => {
            const deployerJettonWallet = await userWallet(deployer.address);
            const mintAmount = BigInt(getRandomInt(1000, 2000));
            const mintMsg = JettonMinter.mintMessage(
                deployer.address,
                mintAmount,
                null,
                null,
                null,
                toNano('0.1'),
                toNano('0.3'),
            );

            const supplyBefore = await jettonMinter.getTotalSupply();
            const minterSmc = await blockchain.getContract(jettonMinter.address);

            // Sending message but only processing first step of tx chain
            let res = await minterSmc.receiveMessage(
                internal({
                    from: deployer.address,
                    to: jettonMinter.address,
                    body: mintMsg,
                    value: toNano('1'),
                }),
            );

            expect(res.outMessagesCount).toEqual(1);
            const outMsgSc = res.outMessages.get(0)!.body.beginParse();
            expect(outMsgSc.preloadUint(32)).toEqual(Op.internal_transfer);
            expect(await jettonMinter.getTotalSupply()).toEqual(supplyBefore + mintAmount);

            await minterSmc.receiveMessage(
                internal({
                    from: deployerJettonWallet.address,
                    to: jettonMinter.address,
                    bounced: true,
                    body: beginCell().storeUint(0xffffffff, 32).storeSlice(outMsgSc).endCell(),
                    value: toNano('0.95'),
                }),
            );

            // Supply should change back
            expect(await jettonMinter.getTotalSupply()).toEqual(supplyBefore);
        });
        it('wallet should restore balance on internal_transfer bounce', async () => {
            const deployerJettonWallet = await userWallet(deployer.address);
            const notDeployerJettonWallet = await userWallet(notDeployer.address);
            const balanceBefore = await deployerJettonWallet.getJettonBalance();
            const txAmount = BigInt(getRandomInt(100, 200));
            const transferMsg = JettonWallet.transferMessage(
                txAmount,
                notDeployer.address,
                deployer.address,
                null,
                0n,
                null,
            );

            const walletSmc = await blockchain.getContract(deployerJettonWallet.address);

            const res = await walletSmc.receiveMessage(
                internal({
                    from: deployer.address,
                    to: deployerJettonWallet.address,
                    body: transferMsg,
                    value: toNano('1'),
                }),
            );

            expect(res.outMessagesCount).toEqual(1);

            const outMsgSc = res.outMessages.get(0)!.body.beginParse();
            expect(outMsgSc.preloadUint(32)).toEqual(Op.internal_transfer);

            expect(await deployerJettonWallet.getJettonBalance()).toEqual(balanceBefore - txAmount);

            await walletSmc.receiveMessage(
                internal({
                    from: notDeployerJettonWallet.address,
                    to: walletSmc.address,
                    bounced: true,
                    body: beginCell().storeUint(0xffffffff, 32).storeSlice(outMsgSc).endCell(),
                    value: toNano('0.95'),
                }),
            );

            // Balance should roll back
            expect(await deployerJettonWallet.getJettonBalance()).toEqual(balanceBefore);
        });
        it('wallet should restore balance on burn_notification bounce', async () => {
            const deployerJettonWallet = await userWallet(deployer.address);
            const balanceBefore = await deployerJettonWallet.getJettonBalance();
            const burnAmount = BigInt(getRandomInt(100, 200));

            const burnMsg = JettonWallet.burnMessage(burnAmount, deployer.address, null);

            const walletSmc = await blockchain.getContract(deployerJettonWallet.address);

            const res = await walletSmc.receiveMessage(
                internal({
                    from: deployer.address,
                    to: deployerJettonWallet.address,
                    body: burnMsg,
                    value: toNano('1'),
                }),
            );

            expect(res.outMessagesCount).toEqual(1);

            const outMsgSc = res.outMessages.get(0)!.body.beginParse();
            expect(outMsgSc.preloadUint(32)).toEqual(Op.burn_notification);

            expect(await deployerJettonWallet.getJettonBalance()).toEqual(balanceBefore - burnAmount);

            await walletSmc.receiveMessage(
                internal({
                    from: jettonMinter.address,
                    to: walletSmc.address,
                    bounced: true,
                    body: beginCell().storeUint(0xffffffff, 32).storeSlice(outMsgSc).endCell(),
                    value: toNano('0.95'),
                }),
            );

            // Balance should roll back
            expect(await deployerJettonWallet.getJettonBalance()).toEqual(balanceBefore);
        });
    });

    describe('Upgrade', () => {
        let prevState: BlockchainSnapshot;

        let getContractData: (address: Address) => Promise<Cell>;
        let getContractCode: (smc: Address) => Promise<Cell>;
        beforeAll(() => {
            prevState = blockchain.snapshot();
            getContractData = async (address: Address) => {
                const smc = await blockchain.getContract(address);
                if (!smc.account.account) throw 'Account not found';
                if (smc.account.account.storage.state.type != 'active')
                    throw 'Atempting to get data on inactive account';
                if (!smc.account.account.storage.state.state.data) throw 'Data is not present';
                return smc.account.account.storage.state.state.data;
            };
            getContractCode = async (address: Address) => {
                const smc = await blockchain.getContract(address);
                if (!smc.account.account) throw 'Account not found';
                if (smc.account.account.storage.state.type != 'active')
                    throw 'Atempting to get code on inactive account';
                if (!smc.account.account.storage.state.state.code) throw 'Code is not present';
                return smc.account.account.storage.state.state.code;
            };
        });

        afterAll(async () => await blockchain.loadFrom(prevState));

        it('not admin should not be able to upgrade minter', async () => {
            const codeCell = beginCell()
                .storeUint(getRandomInt(1000, (1 << 32) - 1), 32)
                .endCell();
            const dataCell = beginCell()
                .storeUint(getRandomInt(1000, (1 << 32) - 1), 32)
                .endCell();

            const codeBefore = await getContractCode(jettonMinter.address);
            const dataBefore = await getContractData(jettonMinter.address);

            const notAdmin = differentAddress(deployer.address);

            const res = await jettonMinter.sendUpgrade(blockchain.sender(notAdmin), codeCell, dataCell);

            expect(res.transactions).toHaveTransaction({
                on: jettonMinter.address,
                from: notAdmin,
                success: false,
                aborted: true,
            });

            // Excessive due to transaction is aborted, but still
            expect(await getContractCode(jettonMinter.address)).toEqualCell(codeBefore);
            expect(await getContractData(jettonMinter.address)).toEqualCell(dataBefore);
        });
        it('admin should be able to upgrade minter code and data', async () => {
            const codeCell = beginCell()
                .storeUint(getRandomInt(1000, (1 << 32) - 1), 32)
                .endCell();
            const dataCell = beginCell()
                .storeUint(getRandomInt(1000, (1 << 32) - 1), 32)
                .endCell();

            const res = await jettonMinter.sendUpgrade(deployer.getSender(), codeCell, dataCell);
            expect(res.transactions).toHaveTransaction({
                on: jettonMinter.address,
                from: deployer.address,
                op: Op.upgrade,
                success: true,
            });

            expect(await getContractCode(jettonMinter.address)).toEqualCell(codeCell);
            expect(await getContractData(jettonMinter.address)).toEqualCell(dataCell);
        });
    });

    // deleted (was `it.skip`)
    // - 'owner can withdraw excesses'
    // - 'not owner can not withdraw excesses'
    // - 'owner can withdraw jettons owned by JettonWallet'
    // - 'not owner can not withdraw jettons owned by JettonWallet'
});
