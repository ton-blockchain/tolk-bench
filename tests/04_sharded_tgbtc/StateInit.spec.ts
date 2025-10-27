import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Cell, toNano, beginCell, Address, Dictionary, storeStateInit } from '@ton/core';
import { jettonContentToCell, JettonMinter } from '../../wrappers/04_sharded_tgbtc/JettonMinter';
import { JettonWallet } from '../../wrappers/04_sharded_tgbtc/JettonWallet';
import '@ton/test-utils';
import { collectCellStats } from './gasUtils';
import { Op, Errors } from '../../wrappers/04_sharded_tgbtc/JettonConstants';
import { findTransactionRequired } from '@ton/test-utils';
import { activateTVM12, myCompile } from "../my-compile";

let blockchain: Blockchain;
let deployer: SandboxContract<TreasuryContract>;
let jettonMinter:SandboxContract<JettonMinter>;
let minter_code: Cell;
let wallet_code: Cell;
let jwallet_code_raw: Cell;
let jwallet_code: Cell;
let userWallet: (address: Address) => Promise<SandboxContract<JettonWallet>>;

const storageDuration= 5 * 365 * 24 * 3600;

const numericFolder = '04_sharded_tgbtc';

let actualConstantsInGasTolk = {
    STORAGE_SIZE_MaxWallet_bits:        0n,
    STORAGE_SIZE_MaxWallet_cells:       0n,
    STORAGE_SIZE_InitStateWallet_bits:  0n,
    STORAGE_SIZE_InitStateWallet_cells: 0n,
}

function printActualStorageConstants() {
    let s = `
// these storage constants should be in \`fees-management.tolk\` ${numericFolder}:

const STORAGE_SIZE_MaxWallet_bits         = ${actualConstantsInGasTolk.STORAGE_SIZE_MaxWallet_bits}
const STORAGE_SIZE_MaxWallet_cells        = ${actualConstantsInGasTolk.STORAGE_SIZE_MaxWallet_cells}
const STORAGE_SIZE_InitStateWallet_bits   = ${actualConstantsInGasTolk.STORAGE_SIZE_InitStateWallet_bits}
const STORAGE_SIZE_InitStateWallet_cells  = ${actualConstantsInGasTolk.STORAGE_SIZE_InitStateWallet_cells}
`;
    // console.log(s)          // commented out: they never change, actually
}


describe(numericFolder + ' StateInit', () => {
    beforeAll(async () => {
        blockchain = await Blockchain.create();
        activateTVM12(blockchain);
        deployer   = await blockchain.treasury('deployer');
        jwallet_code_raw = await myCompile(numericFolder, 'JettonWallet');
        minter_code    = await myCompile(numericFolder, 'JettonMinter');

        //jwallet_code is library
        const _libs = Dictionary.empty(Dictionary.Keys.BigUint(256), Dictionary.Values.Cell());
        _libs.set(BigInt(`0x${jwallet_code_raw.hash().toString('hex')}`), jwallet_code_raw);
        const libs = beginCell().storeDictDirect(_libs).endCell();
        blockchain.libs = libs;
        let lib_prep = beginCell().storeUint(2,8).storeBuffer(jwallet_code_raw.hash()).endCell();
        jwallet_code = new Cell({ exotic:true, bits: lib_prep.bits, refs:lib_prep.refs});

        // console.log('jetton minter code hash = ', minter_code.hash().toString('hex'));
        // console.log('jetton wallet code hash = ', jwallet_code.hash().toString('hex'));

        jettonMinter   = blockchain.openContract(
                   JettonMinter.createFromConfig(
                     {
                       admin: deployer.address,
                       wallet_code: jwallet_code,
                       jetton_content: jettonContentToCell({uri: "https://ton.org/"})
                     },
                     minter_code));

        userWallet = async (address:Address) => blockchain.openContract(
                          JettonWallet.createFromAddress(
                            await jettonMinter.getWalletAddress(address)
                          )
                     );

    });
    afterAll(() => {
        printActualStorageConstants();
    });

    it('should deploy', async () => {

        //await blockchain.setVerbosityForAddress(jettonMinter.address, {blockchainLogs:true, vmLogs: 'vm_logs'});
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
            inMessageBounced: true
        });
    });
    it('should mint max jetton walue', async () => {
        const maxValue = (2n ** 120n) - 1n;
        const deployerWallet = await userWallet(deployer.address);
        let res = await jettonMinter.sendMint(deployer.getSender(),
                                                deployer.address,
                                                maxValue,
                                                null, deployer.address, null);
        const transferTx = findTransactionRequired(res.transactions,{
            on: deployerWallet.address,
            op: Op.internal_transfer,
            initCode: jwallet_code,
            success: true,
        });

        const inMsg = transferTx.inMessage!;

        if(inMsg.info.type !== 'internal') {
            throw new Error("No way");
        }

        expect(res.transactions).toHaveTransaction({
            on: deployer.address,
            op: Op.excesses,
            aborted: false
        });

        const curBalance = await deployerWallet.getJettonBalance();
        expect(curBalance).toEqual(maxValue);
        const smc   = await blockchain.getContract(deployerWallet.address);
        if(smc.accountState === undefined)
            throw new Error("Can't access wallet account state");
        if(smc.accountState.type !== "active")
            throw new Error("Wallet account is not active");
        if(smc.account.account === undefined || smc.account.account === null)
            throw new Error("Can't access wallet account!");
        const storageStats = smc.account.account.storageStats.used;
        actualConstantsInGasTolk.STORAGE_SIZE_MaxWallet_bits = storageStats.bits;
        actualConstantsInGasTolk.STORAGE_SIZE_MaxWallet_cells = storageStats.cells;
        // console.log("Jetton wallet max storage stats:", smc.account.account.storageStats.used);
        const state = inMsg.init!;
        const stateCell = beginCell().store(storeStateInit(state)).endCell();
        const initStateStats = collectCellStats(stateCell, []);
        actualConstantsInGasTolk.STORAGE_SIZE_InitStateWallet_bits = initStateStats.bits;
        actualConstantsInGasTolk.STORAGE_SIZE_InitStateWallet_cells = initStateStats.cells;
        // console.log("State init stats:", collectCellStats(stateCell, []));

        blockchain.now = transferTx.now + storageDuration + 1;

        // Going to fail, but will trigger storage fee
        res = await deployer.send({
            to: deployerWallet.address,
            value: 0n,
        });

        expect(smc.account.account.storageStats.duePayment).toBeNull();
    });
});

