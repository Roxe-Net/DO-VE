const { expectRevert, time } = require('@openzeppelin/test-helpers');
const ethers = require('ethers');

const Holder = artifacts.require('Holder');
const UniswapV2Factory = artifacts.require('UniswapV2Factory');
const UniswapV2Pair = artifacts.require('UniswapV2Pair');
const UniswapV2Router02 = artifacts.require('UniswapV2Router02');
const DO = artifacts.require('DO');
const Reserve = artifacts.require('Reserve');
const ROC = artifacts.require('ROC');
const RoUSD = artifacts.require('RoUSD');
const Timelock = artifacts.require('Timelock');

function encodeParameters(types, values) {
    const abi = new ethers.utils.AbiCoder();
    return abi.encode(types, values);
}

function appendZeroes(value, count) {
    var result = value.toString();
    for (var i = 0; i < count; ++i) {
        result += '0';
    }
    return result;
}

contract('Reserve', ([alice, bob, feeToSetter, wETH]) => {
    beforeEach(async () => {
        this.doToken = await DO.new({ from: alice });
        this.rocToken = await ROC.new({ from: alice });
        this.roUSDToken = await RoUSD.new({ from: alice });

        this.reserve = await Reserve.new(
            this.rocToken.address,
            this.doToken.address,
            this.roUSDToken.address, { from: alice });

        this.holder0 = await Holder.new(
            this.reserve.address, this.rocToken.address, this.roUSDToken.address, "Holder0", { from: alice });
        this.holder1 = await Holder.new(
            this.reserve.address, this.rocToken.address, this.roUSDToken.address, "Holder1", { from: alice });
        this.holder2 = await Holder.new(
            this.reserve.address, this.rocToken.address, this.roUSDToken.address, "Holder2", { from: alice });

        await this.reserve.setHolderInfoArray(
            [this.holder0.address, this.holder1.address, this.holder2.address],
            [2000, 5000, 3000], { from: alice });


        const factory = await UniswapV2Factory.new(feeToSetter, { from: alice });
        await factory.createPair(this.doToken.address, this.roUSDToken.address, { from: alice });
        const pairAddress = await factory.getPair(this.doToken.address, this.roUSDToken.address, { from: alice });
        this.pair = await UniswapV2Pair.at(pairAddress);
        this.router = await UniswapV2Router02.new(factory.address, wETH, { from: alice });

        await this.reserve.setRouter(this.router.address, { from: alice });
        await this.reserve.setRoUSDDOPair(this.pair.address, { from: alice });

        // Let bob have 1M roUSD.
        await this.roUSDToken.setIssuer(alice, { from: alice });
        await this.roUSDToken.mint(bob, appendZeroes(1, 24), { from: alice });

        // Create 8B ROC and send 4B to reserve and 4B to holders.
        await this.rocToken.setIssuer(alice, { from: alice });
        await this.rocToken.mint(alice, appendZeroes(8, 27), { from: alice });
        await this.rocToken.transfer(this.reserve.address, appendZeroes(4, 27), { from: alice });
        await this.rocToken.transfer(this.holder0.address, appendZeroes(8, 26), { from: alice });
        await this.rocToken.transfer(this.holder1.address, appendZeroes(2, 27), { from: alice });
        await this.rocToken.transfer(this.holder2.address, appendZeroes(12, 26), { from: alice });

        this.timelock = await Timelock.new(bob, '259200', { from: alice });

        await this.doToken.transferOwnership(this.reserve.address, { from: alice });
        await this.rocToken.transferOwnership(this.timelock.address, { from: alice });
        await this.reserve.transferOwnership(this.timelock.address, { from: alice });
    });

    it('purchase roc and mint', async () => {
        await this.reserve.setInitialSoldAndCost(0, 0, {from: alice});
        await this.reserve.setInitialPrice(appendZeroes(1, 17), {from: alice});

        // Assume bob buys 60K ROC.
        const rocAmount0 = appendZeroes(6, 22);
        const result0 = await this.reserve.estimateRoUSDAmountFromROC(rocAmount0, { from: bob });
        const roUSDAmount0 = result0[0];

        assert.equal(roUSDAmount0.valueOf(), 6010 * 1e18);

        await this.roUSDToken.approve(this.reserve.address, roUSDAmount0, { from: bob });

        const now0 = await time.latest().valueOf();
        await this.reserve.purchaseExactAmountOfROCWithRoUSD(rocAmount0, roUSDAmount0, now0 + 60, { from: bob });

        const sold0 = await this.reserve.sold();
        assert.equal(sold0.valueOf(), 60000 * 1e18);

        const price0 = await this.reserve.price();
        assert.equal(price0.valueOf(), 101 * 1e15);  // 0.101 roUSD

        // Now bob spends 10K roUSD.
        const roUSDAmount1 = appendZeroes(1, 22);
        const result1 = await this.reserve.estimateROCAmountFromRoUSD(roUSDAmount1, { from: bob });
        const rocAmount1 = result1[0];

        assert.equal(rocAmount1.valueOf(), 98349514563106796100000);

        await this.roUSDToken.approve(this.reserve.address, roUSDAmount1, { from: bob });

        const now1 = await time.latest().valueOf();
        await this.reserve.purchaseROCWithExactAmountOfRoUSD(roUSDAmount1, rocAmount1, now1 + 60, { from: bob });

        // Before minting DO, check the average price.
        const sold1 = await this.reserve.sold();
        const cost1 = await this.reserve.cost();
        const averagePrice1 = await this.reserve.getAveragePriceOfROC();

        assert.equal(sold1.valueOf(), 158349514563106796100000);
        assert.equal(cost1.valueOf(), 16010 * 1e18);
        assert.equal(averagePrice1.valueOf(), 101105456774984670);  // Approxmately 0.101 roUSD

        const now2 = await time.latest().valueOf();

        // Now mint with 1000 ROC.
        const rocAmount2 = appendZeroes(1, 21);  // 1000 ROC
        await this.rocToken.approve(this.reserve.address, rocAmount2, { from: bob });
        await this.reserve.mintDOWithExactAmountOfROC(rocAmount2, 50e18, now2 + 60, { from: bob });

        const doBalance2 = await this.doToken.balanceOf(bob, { from: bob });
        // Bob should have 1000 * 0.101105456774984670 / 2 DO.
        assert.equal(doBalance2.valueOf(), 50552728387492330000);  // Approximately 50.55 DO

        const loan3 = await this.reserve.loanMap(bob, 0, { from: bob });
        assert.equal(loan3[2].valueOf(), 1000e18);
        assert.equal(loan3[3].valueOf(), 50552728387492330000);

        const now3 = await time.latest().valueOf();

        // Now mint 60 DO.
        const doAmount3 = appendZeroes(6, 19);  // 60 DO
        // 2000 ROC is more then enough.
        await this.rocToken.approve(this.reserve.address, appendZeroes(2, 21), { from: bob });
        await this.reserve.mintExactAmountOfDO(doAmount3, 2000e18, now3 + 60, { from: bob });

        // Before redeeming, check Bob's balance.
        const doBalance3 = await this.doToken.balanceOf(bob, { from: bob });
        assert.equal(doBalance3.valueOf(), 110552728387492330000);  // approximately 110.55 DO

        const roUSDBalance3 = await this.roUSDToken.balanceOf(bob, { from: bob });
        assert.equal(roUSDBalance3.valueOf(), 983990 * 1e18);  // After spending 16010 roUSD.

        const rocBalance3 = await this.rocToken.balanceOf(bob, { from: bob });
        assert.equal(rocBalance3.valueOf(), 156162635003608200000000);  // Approximately 156162 ROC

        // Now redeem.
        await this.doToken.approve(this.reserve.address, doBalance3, { from: bob });
        await this.reserve.redeemROC(0, { from: bob });
        await this.reserve.redeemROC(1, { from: bob });

        // Check again.
        const loan4 = await this.reserve.loanMap(bob, 0, { from: bob });
        assert.equal(loan4[2].valueOf(), 0);
        assert.equal(loan4[3].valueOf(), 0);

        const doBalance4 = await this.doToken.balanceOf(bob, { from: bob });
        assert.equal(doBalance4.valueOf(), 0);

        const roUSDBalance4 = await this.roUSDToken.balanceOf(bob, { from: bob });
        assert.equal(roUSDBalance4.valueOf(), 983990 * 1e18);

        const rocBalance4 = await this.rocToken.balanceOf(bob, { from: bob });
        assert.equal(rocBalance4.valueOf(), 158349514563106796100000);
    });

    it('inflate and deflate', async () => {
        await this.reserve.setInitialSoldAndCost(0, 0, {from: alice});
        await this.reserve.setInitialPrice(appendZeroes(1, 17), {from: alice});

        // Bob buys 1M ROC.
        const rocAmount0 = appendZeroes(1, 24);
        const result0 = await this.reserve.estimateRoUSDAmountFromROC(rocAmount0, { from: bob });
        const roUSDAmount0 = result0[0];
        await this.roUSDToken.approve(this.reserve.address, roUSDAmount0, { from: bob });

        const now0 = await time.latest().valueOf();
        await this.reserve.purchaseExactAmountOfROCWithRoUSD(rocAmount0, roUSDAmount0, now0 + 60, { from: bob });

        // Mint 2K DO, enough for this test.
        const doAmount1 = appendZeroes(2, 21);
        await this.rocToken.approve(this.reserve.address, rocAmount0, { from: bob });
        await this.reserve.mintExactAmountOfDO(doAmount1, { from: bob });

        // Add liquidity of 1K DO and 1K roUSD.
        const doAmount2 = appendZeroes(1, 21);
        const roUSDAmount2 = appendZeroes(1, 21);

        await this.doToken.approve(this.router.address, doAmount2, { from: bob });
        await this.roUSDToken.approve(this.router.address, roUSDAmount2, { from: bob });
        const now2 = await time.latest().valueOf();
        await this.router.addLiquidity(
            this.doToken.address,
            this.roUSDToken.address,
            doAmount2,
            roUSDAmount2,
            doAmount2,
            roUSDAmount2,
            bob,
            now2 + 60,
            { from: bob });

        // Inflate or deflate should fail because price is within range.
        const now3 = await time.latest().valueOf();
        await expectRevert(
            this.reserve.inflate(now3 + 60, { from: bob }),
            "Reserve: not ready to inflate"
        );
        const now4 = await time.latest().valueOf();
        await expectRevert(
            this.reserve.deflate(now4 + 60, { from: bob }),
            "Reserve: not ready to deflate"
        );

        // Change price to be larger than 1.03 so that we can inflate
        await this.roUSDToken.transfer(this.pair.address, appendZeroes(31, 18), { from: bob });
        await this.pair.sync({ from: bob });
        assert.equal((await this.reserve.canInflate()), true);
    
        // Inflate at most 7 times, we will be in good range.
        for (let i = 0; i < 7; ++i) {
            if (await this.reserve.canInflate()) {
                const now5 = await time.latest().valueOf();
                await this.reserve.inflate(now5 + 60);
            }

            // wait 1 minute
            await time.increase(time.duration.minutes(1));
        }

        assert.equal((await this.reserve.isInTargetPrice()), true);

        // Change price to be less than 0.97 so that we can deflate
        const result = await this.pair.getReserves();
        const reserveRoUSD =
            (await this.pair.token0()) == this.roUSDToken.address ? result[0].valueOf() : result[1].valueOf();
        const reserveDO =
            (await this.pair.token0()) == this.doToken.address ? result[0].valueOf() : result[1].valueOf();

        await this.doToken.transfer(this.pair.address, (reserveRoUSD / 0.969 - reserveDO).toString(), { from: bob });
        await this.pair.sync({ from: bob });
        assert.equal((await this.reserve.canDeflate()), true);

        // Deflate at most 7 times, we will be in good range.
        for (let i = 0; i < 7; ++i) {
            if (await this.reserve.canDeflate()) {
                const now6 = await time.latest().valueOf();
                await this.reserve.deflate(now6 + 60);
            }

            // wait 1 minute
            await time.increase(time.duration.minutes(1));
        }

        assert.equal((await this.reserve.isInTargetPrice()), true);
    });
});
