import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { Address, beginCell, Cell, comment, SendMode, toNano } from '@ton/core';
import { NFTCollection } from '../../wrappers/02_nft/NFTCollection';
import '@ton/test-utils';
import { randomAddress } from '@ton/test-utils';
import { NFTItem } from '../../wrappers/02_nft/NFTItem';
import { activateTVM11, myCompile } from "../my-compile";
import { GasLogAndSave } from '../gas-logger';

const numericFolder = '02_nft';

describe(numericFolder, () => {
    let GAS_LOG = new GasLogAndSave(numericFolder);
    let nftItemCode: Cell;
    let nftCollectionCode: Cell;

    let blockchain: Blockchain;
    let owner: SandboxContract<TreasuryContract>;
    let nftCollection: SandboxContract<NFTCollection>;

    const royaltyParams = {
        numerator: 16,
        denominator: 2,
        royaltyAddress: randomAddress(),
    };

    async function nftFixture(nftOwnerAddress: Address) {
        const { nextItemIndex } = await nftCollection.getCollectionData();
        const nftDeployResult = await nftCollection.sendDeployNft(owner.getSender(), {
            to: nftOwnerAddress,
            index: nextItemIndex,
            value: toNano('0.05')
        });

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            success: true
        });

        const nftAddress = await nftCollection.getNftAddressByIndex(nextItemIndex);

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: nftCollection.address,
            to: nftAddress,
            deploy: true,
            success: true
        });

        return blockchain.openContract(NFTItem.createFromAddress(nftAddress));
    }

    beforeAll(async () => {
        nftItemCode = await myCompile(numericFolder, 'NFTItem');
        nftCollectionCode = await myCompile(numericFolder, 'NFTCollection');
        GAS_LOG.rememberBocSize("nft-item", nftItemCode);
        GAS_LOG.rememberBocSize("nft-collection", nftCollectionCode);
    });
    afterAll(() => {
        GAS_LOG.saveCurrentRunAfterAll();
    })

    describe('NFTCollection', () => {

    beforeAll(async () => {
        blockchain = await Blockchain.create();
        activateTVM11(blockchain);
        owner = await blockchain.treasury('owner');

        nftCollection = blockchain.openContract(
            NFTCollection.createFromConfig(
                {
                    nftItemCode,
                    ownerAddress: owner.address,
                    royaltyParams,
                },
                nftCollectionCode,
            ),
        );

        const deployResult = await nftCollection.sendDeploy(owner.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            deploy: true,
            success: true,
        });
    })

    it('should report royalty params', async () => {
        const randomTreasury = await blockchain.treasury('random-treasury');

        const queryId = 42;
        const result = await nftCollection.sendGetRoyaltyParams(randomTreasury.getSender(), {
            value: toNano('0.05'),
            queryId,
        });

        expect(result.transactions).toHaveTransaction({
            from: randomTreasury.address,
            to: nftCollection.address,
            op: 0x693d3950,
            success: true,
        });

        expect(result.transactions).toHaveTransaction({
            from: nftCollection.address,
            to: randomTreasury.address,
            op: 0xa8cb00ad,
            inMessageBounceable: false,
            body: beginCell()
                .storeUint(0xa8cb00ad, 32)
                .storeUint(queryId, 64)
                .storeSlice(NFTCollection.buildRoyaltyParams(royaltyParams).beginParse())
                .endCell(),
        });
    });

    it.each([1, 2, 3, 0x42])('should not allow any other opcode not from owner', async (opcode) => {
        const randomTreasury = await blockchain.treasury('random-treasury');

        const queryId = 42;
        const result = await randomTreasury.send({
            to: nftCollection.address,
            sendMode: SendMode.CARRY_ALL_REMAINING_BALANCE,
            value: toNano('0.05'),
            body: beginCell().storeUint(opcode, 32).storeUint(queryId, 64).endCell(),
        });

        expect(result.transactions).toHaveTransaction({
            from: randomTreasury.address,
            to: nftCollection.address,
            op: opcode,
            success: false,
            // exitCode: 401,       // this changed against FunC: on invalid opcode, we always return 0xFFFF
            exitCode: opcode === 0x042 ? 0xFFFF : 401,
        });
    });

    it('[bench] should deploy nft', async () => {
        const { nextItemIndex } = await nftCollection.getCollectionData();
        const nftOwnerAddress = randomAddress();

        const content = beginCell().storeStringTail('Content').endCell();
        const nftDeployResult = await nftCollection.sendDeployNft(owner.getSender(), {
            to: nftOwnerAddress,
            index: nextItemIndex,
            value: toNano('0.05'),
            content,
        });

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            op: 1,
            success: true,
        });

        const nftAddress = await nftCollection.getNftAddressByIndex(nextItemIndex);

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: nftCollection.address,
            to: nftAddress,
            initCode: nftItemCode,
            deploy: true,
            success: true,
        });

        const nftItem = blockchain.openContract(NFTItem.createFromAddress(nftAddress));

        const data = await nftItem.getNftData();
        expect(data.init).toBeTruthy();
        expect(data.index).toBe(nextItemIndex);
        expect(data.ownerAddress).toEqualAddress(nftOwnerAddress);
        expect(data.collectionAddress).toEqualAddress(nftCollection.address);
        expect(data.individualContent?.equals(content)).toBeTruthy();

        GAS_LOG.rememberGas("DEPLOY nft", nftDeployResult.transactions.slice(1));
    });

    it('should not deploy nft with invalid item index', async () => {
        const { nextItemIndex } = await nftCollection.getCollectionData();

        const nftDeployResult = await nftCollection.sendDeployNft(owner.getSender(), {
            to: owner.address,
            index: nextItemIndex + 1,
            value: toNano('0.05'),
        });

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            op: 1,
            success: false,
            exitCode: 402,
        });
    });

    it('should increment item index if last', async () => {
        const { nextItemIndex } = await nftCollection.getCollectionData();

        const nftDeployResult = await nftCollection.sendDeployNft(owner.getSender(), {
            to: owner.address,
            index: nextItemIndex,
            value: toNano('0.05'),
        });

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            op: 1,
            success: true,
        });

        const { nextItemIndex: newNextItemIndex } = await nftCollection.getCollectionData();
        expect(newNextItemIndex).toBe(nextItemIndex + 1);
    });

    it('should not increment item index if not last', async () => {
        const { nextItemIndex } = await nftCollection.getCollectionData();

        // deploy in case no nfts were deployed before
        await nftCollection.sendDeployNft(owner.getSender(), {
            to: owner.address,
            index: nextItemIndex,
            value: toNano('0.05'),
        });

        const { nextItemIndex: newNextItemIndex } = await nftCollection.getCollectionData();
        expect(newNextItemIndex).toBe(nextItemIndex + 1);

        // deploy in case no nfts were deployed before
        const nftDeployResult = await nftCollection.sendDeployNft(owner.getSender(), {
            to: owner.address,
            index: 0,
            value: toNano('0.05'),
        });

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            op: 1,
            success: true,
        });

        const { nextItemIndex: newNextItemIndexAfterSecondDeploy } = await nftCollection.getCollectionData();
        expect(newNextItemIndex).toBe(newNextItemIndexAfterSecondDeploy);
    });

    it('should deploy some nfts via batch deploy', async () => {
        const { nextItemIndex } = await nftCollection.getCollectionData();
        const nftOwnerAddress = randomAddress();

        const content = beginCell().storeStringTail('Content').endCell();
        const indexes = [nextItemIndex, nextItemIndex + 1, nextItemIndex + 2];
        const nftDeployResult = await nftCollection.sendBatchDeployNFT(owner.getSender(), {
            items: indexes.map((index) => ({
                to: nftOwnerAddress,
                index,
                content,
            })),
            value: toNano('0.05'),
        });

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            op: 2,
            success: true,
        });

        for (const index of indexes) {
            const nftAddress = await nftCollection.getNftAddressByIndex(index);

            expect(nftDeployResult.transactions).toHaveTransaction({
                from: nftCollection.address,
                to: nftAddress,
                initCode: nftItemCode,
                deploy: true,
                success: true,
            });

            const nftItem = blockchain.openContract(NFTItem.createFromAddress(nftAddress));

            const data = await nftItem.getNftData();
            expect(data.init).toBeTruthy();
            expect(data.index).toBe(index);
            expect(data.ownerAddress).toEqualAddress(nftOwnerAddress);
            expect(data.collectionAddress).toEqualAddress(nftCollection.address);
            expect(data.individualContent?.equals(content)).toBeTruthy();
        }
    });

    // due to gas limits even if limit on contract is 250, around 110 nfts is max to deploy
    it('[bench] should deploy 100 nfts via batch deploy', async () => {
        // use a dedicated collection here, with its own init state, for measurements
        let nftCollection = blockchain.openContract(
            NFTCollection.createFromConfig({
                    content: beginCell()
                        .storeRef(beginCell().storeStringTail("collectionContent").endCell())
                        .storeRef(beginCell().storeStringTail("common").endCell())
                        .endCell(),
                    nftItemCode: nftItemCode,
                    ownerAddress: owner.address,
                    nextItemIndex: 1,
                    royaltyParams: {
                        numerator: 100,
                        denominator: 1,
                        royaltyAddress: owner.address,
                    },
                },
                nftCollectionCode,
            ),
        );
        await nftCollection.sendDeploy(owner.getSender(), toNano('0.05'));

        const nftOwnerAddress = owner.address;
        const indexes = Array.from({ length: 100 }).map((_, i) => 1 + i);
        const nftDeployResult = await nftCollection.sendBatchDeployNFT(owner.getSender(), {
            items: indexes.map((index) => ({
                to: nftOwnerAddress,
                index: index,
                content: beginCell().endCell(),
            })),
            value: toNano('200'),
        });

        expect(nftDeployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            op: 2,
            success: true,
        });

        for (const index of indexes) {
            const nftAddress = await nftCollection.getNftAddressByIndex(index);

            expect(nftDeployResult.transactions).toHaveTransaction({
                from: nftCollection.address,
                to: nftAddress,
                initCode: nftItemCode,
                deploy: true,
                success: true,
            });

            const nftItem = blockchain.openContract(NFTItem.createFromAddress(nftAddress));

            const data = await nftItem.getNftData();
            expect(data.init).toBeTruthy();
            expect(data.index).toBe(index);
            expect(data.ownerAddress).toEqualAddress(nftOwnerAddress);
            expect(data.collectionAddress).toEqualAddress(nftCollection.address);
        }

        GAS_LOG.rememberGas("BATCH deploy nft", nftDeployResult.transactions.slice(1));
    });

    // due to gas limits even if limit on contract is 250, around 110 nfts is max to deploy
    it('should change owner', async () => {
        const { ownerAddress: oldOwnerAddress } = await nftCollection.getCollectionData();
        const newOwner = await blockchain.treasury('new-owner');

        const result = await nftCollection.sendChangeOwner(owner.getSender(), {
            value: toNano('0.05'),
            newOwner: newOwner.address,
        });

        expect(result.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            op: 3,
            success: true,
        });

        const { ownerAddress: newOwnerAddress } = await nftCollection.getCollectionData();

        expect(oldOwnerAddress).not.toEqualAddress(newOwnerAddress);
        expect(newOwnerAddress).toEqualAddress(newOwner.address);
    });
    });


    describe('NFTItem', () => {

    beforeAll(async () => {
        blockchain = await Blockchain.create();
        activateTVM11(blockchain);
        owner = await blockchain.treasury('owner');

        nftCollection = blockchain.openContract(
            NFTCollection.createFromConfig(
                {
                    nftItemCode,
                    ownerAddress: owner.address,
                    royaltyParams,
                },
                nftCollectionCode,
            ),
        );

        const deployResult = await nftCollection.sendDeploy(owner.getSender(), toNano('0.05'));

        expect(deployResult.transactions).toHaveTransaction({
            from: owner.address,
            to: nftCollection.address,
            deploy: true,
            success: true,
        });
    })


    it('should transfer ownership', async () => {
        const nftOwner = await blockchain.treasury('nft-owner');
        const nftReceiverAddress = randomAddress();

        const nftItem = await nftFixture(nftOwner.address);

        const { ownerAddress: ownerBeforeTransfer } = await nftItem.getNftData();

        expect(ownerBeforeTransfer).toEqualAddress(nftOwner.address);

        const result = await nftItem.sendTransferOwnership(nftOwner.getSender(), {
            value: toNano('0.05'),
            to: nftReceiverAddress
        });

        expect(result.transactions).toHaveTransaction({
            from: ownerBeforeTransfer!,
            to: nftItem.address,
            op: 0x5fcc3d14,
            success: true
        });

        expect(result.transactions).not.toHaveTransaction({
            from: nftItem.address,
            to: nftReceiverAddress
        });

        const { ownerAddress: ownerAfterTransfer } = await nftItem.getNftData();

        expect(ownerAfterTransfer).toEqualAddress(nftReceiverAddress);
    });

    it('should transfer ownership and return excesses', async () => {
        const nftOwner = await blockchain.treasury('nft-owner');
        const nftReceiverAddress = randomAddress();
        const excessesAddress = randomAddress();

        const nftItem = await nftFixture(nftOwner.address);

        const { ownerAddress: ownerBeforeTransfer } = await nftItem.getNftData();
        expect(ownerBeforeTransfer).toEqualAddress(nftOwner.address);

        const result = await nftItem.sendTransferOwnership(nftOwner.getSender(), {
            value: toNano('0.05'),
            to: nftReceiverAddress,
            responseTo: excessesAddress,
        });

        expect(result.transactions).toHaveTransaction({
            from: ownerBeforeTransfer!,
            to: nftItem.address,
            op: 0x5fcc3d14,
            success: true
        });

        expect(result.transactions).toHaveTransaction({
            from: nftItem.address,
            to: excessesAddress,
            inMessageBounceable: false,
            op: 0xd53276db,
        });

        const { ownerAddress: ownerAfterTransfer } = await nftItem.getNftData();
        expect(ownerAfterTransfer).toEqualAddress(nftReceiverAddress);
    });

    it('should transfer ownership with notification cell', async () => {
        const nftOwner = await blockchain.treasury('nft-owner');
        const nftReceiverAddress = randomAddress();

        const nftItem = await nftFixture(nftOwner.address);

        const { ownerAddress: ownerBeforeTransfer } = await nftItem.getNftData();

        expect(ownerBeforeTransfer).toEqualAddress(nftOwner.address);

        const forwardAmount = toNano('0.0042');
        const forwardBody = comment('Hello!');
        const queryId = 42;

        const result = await nftItem.sendTransferOwnership(nftOwner.getSender(), {
            queryId,
            value: toNano('0.05'),
            to: nftReceiverAddress,
            forwardAmount,
            forwardBody
        });

        expect(result.transactions).toHaveTransaction({
            from: nftOwner.address,
            to: nftItem.address,
            op: 0x5fcc3d14,
            success: true
        });

        expect(result.transactions).toHaveTransaction({
            from: nftItem.address,
            to: nftReceiverAddress,
            value: forwardAmount,
            op: 0x05138d91,
            inMessageBounceable: false,
            body: beginCell()
                .storeUint(0x05138d91, 32)
                .storeUint(queryId, 64)
                .storeAddress(ownerBeforeTransfer)
                .storeBit(1)
                .storeRef(forwardBody)
                .endCell()
        });

        const { ownerAddress: ownerAfterTransfer } = await nftItem.getNftData();

        expect(ownerAfterTransfer).toEqualAddress(nftReceiverAddress);
    });

    it('[bench] should transfer ownership with notification slice', async () => {
        const nftOwner = await blockchain.treasury('nft-owner');
        let notOwner: SandboxContract<TreasuryContract>;
        notOwner = await blockchain.treasury("notOwner");
        const nftReceiverAddress = notOwner.address;

        const nftItem = await nftFixture(nftOwner.address);

        const { ownerAddress: ownerBeforeTransfer } = await nftItem.getNftData();

        expect(ownerBeforeTransfer).toEqualAddress(nftOwner.address);

        const forwardAmount = 0n;//toNano('0.0042');
        const forwardBody = comment('Hello!').beginParse();
        const queryId = 42;

        const result = await nftItem.sendTransferOwnership(nftOwner.getSender(), {
            queryId,
            value: toNano('0.05'),
            to: nftReceiverAddress,
            responseTo: owner.address,
            forwardAmount,
            forwardBody
        });

        expect(result.transactions).toHaveTransaction({
            from: nftOwner.address,
            to: nftItem.address,
            op: 0x5fcc3d14,
            success: true
        });

        // expect(result.transactions).toHaveTransaction({
        //     from: nftItem.address,
        //     to: nftReceiverAddress,
        //     value: forwardAmount,        // for measurements, it's 0
        //     op: 0x05138d91,
        //     body: beginCell()
        //         .storeUint(0x05138d91, 32)
        //         .storeUint(queryId, 64)
        //         .storeAddress(ownerBeforeTransfer)
        //         .storeBit(0)
        //         .storeSlice(forwardBody)
        //         .endCell()
        // });

        const { ownerAddress: ownerAfterTransfer } = await nftItem.getNftData();

        expect(ownerAfterTransfer).toEqualAddress(nftReceiverAddress);
        GAS_LOG.rememberGas("TRANSFER nft", result.transactions.slice(1));
    });

    it('should not transfer ownership not from owner', async () => {
        const nftOwner = await blockchain.treasury('nft-owner');
        const notOwner = await blockchain.treasury('not-owner');
        const nftReceiverAddress = randomAddress();

        const nftItem = await nftFixture(nftOwner.address);

        const { ownerAddress: ownerBeforeTransfer } = await nftItem.getNftData();

        expect(ownerBeforeTransfer).toEqualAddress(nftOwner.address);

        const result = await nftItem.sendTransferOwnership(notOwner.getSender(), {
            value: toNano('0.05'),
            to: nftReceiverAddress
        });

        expect(result.transactions).toHaveTransaction({
            from: notOwner.address,
            to: nftItem.address,
            op: 0x5fcc3d14,
            success: false,
            exitCode: 401
        });

        const { ownerAddress: ownerAfterTransfer } = await nftItem.getNftData();

        expect(ownerAfterTransfer).toEqualAddress(ownerBeforeTransfer!);
    });

    it.each([
        // beginCell().storeUint(1, 1),     // commented out: in FunC it failed with 9 (cell underflow), now it fails with 0xFFFF (invalid opcode)
        beginCell().storeUint(0x5fcc3d14, 32),
        beginCell().storeUint(0x5fcc3d14, 32).storeUint(42, 64),
        beginCell().storeUint(0x5fcc3d14, 32).storeUint(42, 64).storeAddress(randomAddress()),
        beginCell()
            .storeUint(0x5fcc3d14, 32)
            .storeUint(42, 64)
            .storeAddress(randomAddress())
            .storeAddress(randomAddress()),
        beginCell()
            .storeUint(0x5fcc3d14, 32)
            .storeUint(42, 64)
            .storeAddress(randomAddress())
            .storeAddress(randomAddress()),
        beginCell()
            .storeUint(0x5fcc3d14, 32)
            .storeUint(42, 64)
            .storeAddress(randomAddress())
            .storeAddress(randomAddress())
            .storeMaybeRef(null)
    ])('should fail with incomplete transfer body', async (body) => {
        const nftOwner = await blockchain.treasury('nft-owner');

        const nftItem = await nftFixture(nftOwner.address);

        const { ownerAddress: ownerBeforeTransfer } = await nftItem.getNftData();
        expect(ownerBeforeTransfer).toEqualAddress(nftOwner.address);

        const result = await nftOwner.send({
            value: toNano('0.05'),
            to: nftItem.address,
            body: body.endCell()
        });

        expect(result.transactions).toHaveTransaction({
            from: nftOwner.address,
            to: nftItem.address,
            body: body.endCell(),
            success: false,
            exitCode: 9 // Cell underflow
        });

        const { ownerAddress: ownerAfterTransfer } = await nftItem.getNftData();

        expect(ownerAfterTransfer).toEqualAddress(ownerBeforeTransfer!);
    });

    it('should fail with no fwd payload provided', async () => {
        const body = beginCell()
            .storeUint(0x5fcc3d14, 32)
            .storeUint(42, 64)
            .storeAddress(randomAddress())
            .storeAddress(randomAddress())
            .storeMaybeRef(null)
            .storeCoins(999)
            .endCell();

        const nftOwner = await blockchain.treasury('nft-owner');
        const nftItem = await nftFixture(nftOwner.address);

        const { ownerAddress: ownerBeforeTransfer } = await nftItem.getNftData();
        expect(ownerBeforeTransfer).toEqualAddress(nftOwner.address);

        const result = await nftOwner.send({
            value: toNano('0.05'),
            to: nftItem.address,
            body: body
        });

        expect(result.transactions).toHaveTransaction({
            from: nftOwner.address,
            to: nftItem.address,
            body: body,
            success: false,
            exitCode: 708 // No forward payload provided
        });

        const { ownerAddress: ownerAfterTransfer } = await nftItem.getNftData();

        expect(ownerAfterTransfer).toEqualAddress(ownerBeforeTransfer!);
    });

    it('should fail when receiver in different workchain', async () => {
        const workchain = -1;
        const nftOwner = await blockchain.treasury('nft-owner');
        const nftReceiverAddress = randomAddress(workchain);

        const nftItem = await nftFixture(nftOwner.address);

        const result = await nftItem.sendTransferOwnership(nftOwner.getSender(), {
            value: toNano('0.05'),
            to: nftReceiverAddress
        });

        expect(result.transactions).toHaveTransaction({
            from: nftOwner.address,
            to: nftItem.address,
            op: 0x5fcc3d14,
            success: false,
            exitCode: 333
        });
    });

    it('should fail when response address in different workchain', async () => {
        const workchain = -1;
        const nftOwner = await blockchain.treasury('nft-owner');
        const nftReceiverAddress = randomAddress();
        const responseTo = randomAddress(workchain);

        const nftItem = await nftFixture(nftOwner.address);

        const result = await nftItem.sendTransferOwnership(nftOwner.getSender(), {
            value: toNano('0.05'),
            to: nftReceiverAddress,
            responseTo,
        });

        expect(result.transactions).toHaveTransaction({
            from: nftOwner.address,
            to: nftItem.address,
            op: 0x5fcc3d14,
            success: false,
            exitCode: 333
        });
    });

    it('[bench] should get static data', async () => {
        const nftOwner = await blockchain.treasury('nft-owner');
        const randomTreasury = await blockchain.treasury('random-treasury');

        const nftItem = await nftFixture(nftOwner.address);

        const queryId = 42;

        const { collectionAddress, index } = await nftItem.getNftData();
        const result = await nftItem.sendGetStaticData(randomTreasury.getSender(), {
            value: toNano('0.05'),
            queryId
        });

        expect(result.transactions).toHaveTransaction({
            from: randomTreasury.address,
            to: nftItem.address,
            op: 0x2fcb26a2,
            success: true
        });

        expect(result.transactions).toHaveTransaction({
            from: nftItem.address,
            to: randomTreasury.address,
            inMessageBounceable: false,
            body: beginCell()
                .storeUint(0x8b771735, 32)
                .storeUint(queryId, 64)
                .storeUint(index, 256)
                .storeAddress(collectionAddress)
                .endCell(),
            value: (v) => Boolean(v && v >= toNano('0.045')),
        });

        GAS_LOG.rememberGas("GET static data", result.transactions.slice(1));
    });

    it('should fail when op not on list', async () => {
        const nftOwner = await blockchain.treasury('nft-owner');
        const randomTreasury = await blockchain.treasury('random-treasury');

        const nftItem = await nftFixture(nftOwner.address);

        const queryId = 42;

        const result = await randomTreasury.send({
            to: nftItem.address,
            value: toNano('0.05'),
            body: beginCell().storeUint(0x123459, 32).storeUint(queryId, 64).endCell(),
        });

        expect(result.transactions).toHaveTransaction({
            from: randomTreasury.address,
            to: nftItem.address,
            success: false,
            exitCode: 0xffff,
        });
    });
    });

});
