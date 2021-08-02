// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IDO.sol";
import "./interfaces/IHolder.sol";
import "./interfaces/ILayerManager.sol";
import "./interfaces/IROC.sol";
import "./interfaces/IRoUSD.sol";
import "./uniswapv2/interfaces/IUniswapV2Router02.sol";
import "./uniswapv2/interfaces/IUniswapV2Pair.sol";

// This contract is owned by Timelock.
contract Reserve is Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public router;
    IUniswapV2Pair public roUSDDOPair;

    IROC public rocToken;
    IDO public doToken;
    IRoUSD public roUSDToken;

    struct HolderInfo {
        IHolder holder;
        uint256 share;  // a number from 1 (0.01%) to 10000 (100%)
    }

    HolderInfo[] public holderInfoArray;
    uint256 constant HOLDER_SHARE_BASE = 10000;

    uint256 public earlyPrice = 5e16;  // 0.05
    uint256 public price;  // Unset, 1e17 means 0.1
    uint256 public sold;  // amount of sold ROC
    uint256 public soldInPreviousLayers;
    uint256 public cost;  // amound of received roUSD

    ILayerManager public layerManager;

    uint256 public reserveRatio = 800000;  // 0.8

    uint256 public inflationThreshold = 1030000;  // 1.03
    uint256 public deflationThreshold = 970000;  // 0.97

    uint256 public inflationTarget = 1010000;  // 1.01
    uint256 public deflationTarget = 990000;  // 0.99

    // ind means inflation and deflation
    uint256 public indIncentive = 1000;  // 0.1%
    uint256 public indIncentiveLimit = 100e18;  // 100 DO
    uint256 public indStep = 3000;  // 0.3%
    uint256 public indWindow = 1 hours;
    uint256 public indGap = 1 minutes;

    uint256 public inflationUntil = 0;
    uint256 public deflationUntil = 0;
    uint256 public inflationLast = 0;
    uint256 public deflationLast = 0;

    uint256 constant RATIO_BASE = 1e6;
    uint256 constant PRICE_BASE = 1e18;  // 1 roUSD

    struct Loan {
        uint128 createdAt;
        uint128 updatedAt;
        uint256 rocAmount;
        uint256 doAmount;
    }

    mapping(address => Loan[]) public loanMap;

    constructor(IROC _roc, IDO _do, IRoUSD _roUSD) public {
        rocToken = _roc;
        doToken = _do;
        roUSDToken = _roUSD;
    }

    // Call this function in the beginning.
    function setInitialSoldAndCost(uint256 _sold, uint256 _cost) external onlyOwner {
        require(sold == 0 && cost == 0, "Can only set once");
        sold = _sold;
        soldInPreviousLayers = _sold;
        cost = _cost;
    }

    function setEarlyPrice(uint256 _earlyPrice) external onlyOwner {
        require(price == 0, "Price should not be set");
        earlyPrice = _earlyPrice;
    }

    // Please only call this function after 1 year.
    function setInitialPrice(uint256 _price) external onlyOwner {
        require(price == 0, "Can only set once");
        require(price >= earlyPrice, "Must be larger than early price");
        price = _price;
    }

    function setHolderInfoArray(IHolder[] calldata _holders, uint256[] calldata _shares) external onlyOwner {
        require(_holders.length == _shares.length);

        delete holderInfoArray;
        for (uint256 i = 0; i < _holders.length; ++i) {
            HolderInfo memory info;
            info.holder = _holders[i];
            info.share = _shares[i];
            holderInfoArray.push(info);
        }
    }

    function setLayerManager(ILayerManager _layerManager) external onlyOwner {
        layerManager = _layerManager;
    }

    function setRouter(IUniswapV2Router02 _router) external onlyOwner {
        router = _router;
    }

    function setRoUSDDOPair(IUniswapV2Pair _roUSDDOPair) external onlyOwner {
        roUSDDOPair = _roUSDDOPair;
    }

    function setReserveRatio(uint256 _reserveRatio) external onlyOwner {
        reserveRatio = _reserveRatio;
    }

    function setInflationThreshold(uint256 _inflationThreshold) external onlyOwner {
        inflationThreshold = _inflationThreshold;
    }

    function setDeflationThreshold(uint256 _deflationThreshold) external onlyOwner {
        deflationThreshold = _deflationThreshold;
    }

    function setInflationTarget(uint256 _inflationTarget) external onlyOwner {
        inflationTarget = _inflationTarget;
    }

    function setDeflationTarget(uint256 _deflationTarget) external onlyOwner {
        deflationTarget = _deflationTarget;
    }

    function setIndIncentive(uint256 _indIncentive) external onlyOwner {
        indIncentive = _indIncentive;
    }

    function setIndIncentiveLimit(uint256 _indIncentiveLimit) external onlyOwner {
        indIncentiveLimit = _indIncentiveLimit;
    }

    function setIndStep(uint256 _indStep) external onlyOwner {
        indStep = _indStep;
    }

    function setIndWindow(uint256 _indWindow) external onlyOwner {
        indWindow = _indWindow;
    }

    function setIndGap(uint256 _indGap) external onlyOwner {
        indGap = _indGap;
    }

    function _checkReserveRatio() private view {
        uint256 doSupply = doToken.totalSupply();
        uint256 roUSDBalance = roUSDToken.balanceOf(address(this));

        require(doSupply.mul(reserveRatio) <= roUSDBalance.mul(RATIO_BASE),
                "Reserve: NOT_ENOUGH_ROUSD");
    }

    function getReserves() private view returns (uint256 reserveDo, uint256 reserveRoUSD) {
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1,) = roUSDDOPair.getReserves();
        if (roUSDDOPair.token0() == address(doToken)) {
            reserveDo = uint256(reserve0);
            reserveRoUSD = uint256(reserve1);
        } else {
            reserveDo = uint256(reserve1);
            reserveRoUSD = uint256(reserve0);
        }
    }

    function canInflate() public view returns(bool) {
        (uint256 reserveDo, uint256 reserveRoUSD) = getReserves();
        return reserveRoUSD.mul(RATIO_BASE) > reserveDo.mul(inflationThreshold) ||
            reserveRoUSD.mul(RATIO_BASE) > reserveDo.mul(inflationTarget) && now < inflationUntil;
    }

    function canDeflate() public view returns(bool) {
        (uint256 reserveDo, uint256 reserveRoUSD) = getReserves();
        return reserveRoUSD.mul(RATIO_BASE) < reserveDo.mul(deflationThreshold) ||
            reserveRoUSD.mul(RATIO_BASE) < reserveDo.mul(deflationTarget) && now < deflationUntil;
    }

    function isInTargetPrice() public view returns(bool) {
        (uint256 reserveDo, uint256 reserveRoUSD) = getReserves();
        return reserveRoUSD.mul(RATIO_BASE) <= reserveDo.mul(inflationTarget) &&
            reserveRoUSD.mul(RATIO_BASE) >= reserveDo.mul(deflationTarget);
    }

    function inflate(uint256 _deadline) external {
        require(canInflate(),
                "Reserve: not ready to inflate");

        if (now >= inflationUntil) {
            inflationUntil = now + indWindow;
        }

        require(now >= inflationLast + indGap, "Reserve: wait for the gap");
        inflationLast = now;

        (uint256 reserveDo, uint256 reserveRoUSD) = getReserves();

        // Mint the amount of do to swap (with some math).
        uint256 amountOfDoToInflate = reserveDo.mul(indStep).div(RATIO_BASE);
        doToken.mint(address(this), amountOfDoToInflate);

        uint256 incentive = amountOfDoToInflate.mul(indIncentive).div(RATIO_BASE);
        incentive = incentive > indIncentiveLimit ? indIncentiveLimit : incentive;

        // Mint some extra do as incentive.
        doToken.mint(msg.sender, incentive);

        address[] memory path = new address[](2);
        path[0] = address(doToken);
        path[1] = address(roUSDToken);

        // Now swap.
        doToken.approve(address(router), amountOfDoToInflate);
        router.swapExactTokensForTokens(
            amountOfDoToInflate,
            0,
            path,
            address(this),
            _deadline);

        // Make sure the ratio is still good.
        _checkReserveRatio();
    }

    function deflate(uint256 _deadline) external {
        require(canDeflate(),
                "Reserve: not ready to deflate");

        if (now >= deflationUntil) {
            deflationUntil = now + indWindow;
        }

        require(now >= deflationLast + indGap, "Reserve: wait for the gap");
        deflationLast = now;

        (uint256 reserveDo, uint256 reserveRoUSD) = getReserves();

        uint256 balanceOfRoUSD = roUSDToken.balanceOf(address(this));

        // Calculate the amount of roUSD to swap (with some math).
        uint256 amountRoUSDToSwap = reserveRoUSD.mul(indStep).div(RATIO_BASE);

        // amountRoUSDToSwap should be smaller than or equal to balance.
        amountRoUSDToSwap = amountRoUSDToSwap <= balanceOfRoUSD ?
            amountRoUSDToSwap : balanceOfRoUSD;

        address[] memory path = new address[](2);
        path[0] = address(roUSDToken);
        path[1] = address(doToken);

        // Now swap.
        roUSDToken.approve(address(router), amountRoUSDToSwap);
        uint256[] memory amounts;
        amounts = router.swapExactTokensForTokens(
           amountRoUSDToSwap,
           0,
           path,
           address(this),
           _deadline);

        // Now send out incentive and burn the rest.
        uint256 incentive = amounts[amounts.length - 1].mul(indIncentive).div(RATIO_BASE);
        incentive = incentive > indIncentiveLimit ? indIncentiveLimit : incentive;

        doToken.transfer(msg.sender, incentive);
        doToken.burn(amounts[amounts.length - 1].sub(incentive));

        // Make sure the ratio is still good.
        _checkReserveRatio();
    }

    function withdrawRoUSD(uint256 _amount) external onlyOwner {
        roUSDToken.transfer(msg.sender, _amount);

        // Make sure the ratio is still good.
        _checkReserveRatio();
    }

    function purchaseExactAmountOfROCWithRoUSD(
        uint256 _amountOfROC,
        uint256 _maxAmountOfRoUSD,
        uint256 _deadline
    ) external returns (uint256) {
        require(now < _deadline, "Reserve: deadline");

        uint256 amountOfRoUSD;
        (amountOfRoUSD, price, sold, soldInPreviousLayers) = estimateRoUSDAmountFromROC(_amountOfROC);
        cost = cost.add(amountOfRoUSD);

        require(amountOfRoUSD <= _maxAmountOfRoUSD, "Reserve: EXCESSIVE_AMOUNT");

        uint256 i;

        // 50% of the ROC should be from holders.
        for (i = 0; i < holderInfoArray.length; ++i) {
            uint256 amountFromHolder = _amountOfROC.div(2).mul(holderInfoArray[i].share).div(HOLDER_SHARE_BASE);
            rocToken.transferFrom(address(holderInfoArray[i].holder), address(this), amountFromHolder);
        }

        rocToken.transfer(msg.sender, _amountOfROC);
        roUSDToken.transferFrom(msg.sender, address(this), amountOfRoUSD);

        // 50% roUSD goes to holders.
        for (i = 0; i < holderInfoArray.length; ++i) {
            uint256 amountToHolder = amountOfRoUSD.div(2).mul(holderInfoArray[i].share).div(HOLDER_SHARE_BASE);
            roUSDToken.transfer(address(holderInfoArray[i].holder), amountToHolder);
        }

        return amountOfRoUSD;
    }

    function purchaseROCWithExactAmountOfRoUSD(
        uint256 _amountOfRoUSD,
        uint256 _minAmountOfROC,
        uint256 _deadline
    ) external returns (uint256) {
        require(now < _deadline, "Reserve: deadline");

        uint256 amountOfROC;
        (amountOfROC, price, sold, soldInPreviousLayers) = estimateROCAmountFromRoUSD(_amountOfRoUSD);
        cost = cost.add(_amountOfRoUSD);

        require(amountOfROC >= _minAmountOfROC, "Reserve: INCESSIVE_AMOUNT");

        uint256 i;

        // 50% of the ROC should be from holders.
        for (i = 0; i < holderInfoArray.length; ++i) {
            uint256 amountFromHolder = amountOfROC.div(2).mul(holderInfoArray[i].share).div(HOLDER_SHARE_BASE);
            rocToken.transferFrom(address(holderInfoArray[i].holder), address(this), amountFromHolder);
        }

        rocToken.transfer(msg.sender, amountOfROC);
        roUSDToken.transferFrom(msg.sender, address(this), _amountOfRoUSD);

        // 50% roUSD goes to holders.
        for (i = 0; i < holderInfoArray.length; ++i) {
            uint256 amountToHolder = _amountOfRoUSD.div(2).mul(holderInfoArray[i].share).div(HOLDER_SHARE_BASE);
            roUSDToken.transfer(address(holderInfoArray[i].holder), amountToHolder);
        }

        return amountOfROC;
    }

    function estimateRoUSDAmountFromROC(
        uint256 _amountOfROC
    ) public view returns(uint256, uint256, uint256, uint256) {
        require(price > 0, "price must be initialized");

        uint256 mPrice = price;
        uint256 mSold = sold;
        uint256 mSoldInPreviousLayers = soldInPreviousLayers;

        uint256 amountOfRoUSD = 0;
        uint256 remainingInLayer = layerManager.getAmountPerLayer(mSold).add(soldInPreviousLayers).sub(mSold);

        while (_amountOfROC > 0) {
            if (_amountOfROC < remainingInLayer) {
                amountOfRoUSD = amountOfRoUSD.add(_amountOfROC.mul(mPrice).div(PRICE_BASE));
                mSold = mSold.add(_amountOfROC);
                _amountOfROC = 0;
            } else {
                amountOfRoUSD = amountOfRoUSD.add(remainingInLayer.mul(mPrice).div(PRICE_BASE));
                _amountOfROC = _amountOfROC.sub(remainingInLayer);
                mPrice = mPrice.add(layerManager.getPriceIncrementPerLayer(mSold));

                // Updates mSold and mSoldInPreviousLayers.
                mSoldInPreviousLayers = mSoldInPreviousLayers.add(layerManager.getAmountPerLayer(mSold));
                mSold = mSold.add(remainingInLayer);

                // Move to a new layer.
                remainingInLayer = layerManager.getAmountPerLayer(mSold);
            }
        }

        return (amountOfRoUSD, mPrice, mSold, mSoldInPreviousLayers);
    }

    function estimateROCAmountFromRoUSD(
        uint256 _amountOfRoUSD
    ) public view returns(uint256, uint256, uint256, uint256) {
        require(price > 0, "price must be initialized");

        uint256 mPrice = price;
        uint256 mSold = sold;
        uint256 mSoldInPreviousLayers = soldInPreviousLayers;

        uint256 amountOfROC = 0;
        uint256 remainingInLayer = layerManager.getAmountPerLayer(mSold).add(soldInPreviousLayers).sub(mSold);

        while (_amountOfRoUSD > 0) {
            uint256 amountEstimate = _amountOfRoUSD.mul(PRICE_BASE).div(mPrice);

            if (amountEstimate < remainingInLayer) {
                amountOfROC = amountOfROC.add(amountEstimate);
                mSold = mSold.add(amountEstimate);
                _amountOfRoUSD = 0;
            } else {
                amountOfROC = amountOfROC.add(remainingInLayer);
                _amountOfRoUSD = _amountOfRoUSD.sub(remainingInLayer.mul(mPrice).div(PRICE_BASE));
                mPrice = mPrice.add(layerManager.getPriceIncrementPerLayer(mSold));

                // Updates mSold and mSoldInPreviousLayers.
                mSoldInPreviousLayers = mSoldInPreviousLayers.add(layerManager.getAmountPerLayer(mSold));
                mSold = mSold.add(remainingInLayer);

                // Move to a new layer.
                remainingInLayer = layerManager.getAmountPerLayer(mSold);
            }
        }

        return (amountOfROC, mPrice, mSold, mSoldInPreviousLayers);
    }

    function getAveragePriceOfROC() public view returns(uint256) {
        if (price == 0) {
            return earlyPrice;
        } else {
            return cost.mul(PRICE_BASE).div(sold);
        }
    }

    function mintExactAmountOfDO(
        uint256 _amountOfDo,
        uint256 _maxAmountOfROC,
        uint256 _deadline
    ) external returns(uint256) {
        require(now < _deadline, "Reserve: deadline");

        uint256 averagePriceOfROC = getAveragePriceOfROC();
        uint256 amountOfROC = _amountOfDo.mul(2).mul(PRICE_BASE).div(averagePriceOfROC);  // 2 times over-collateralized

        require(amountOfROC <= _maxAmountOfROC, "Reserve: EXCESSIVE_AMOUNT");

        rocToken.transferFrom(msg.sender, address(this), amountOfROC);
        doToken.mint(msg.sender, _amountOfDo);

        Loan memory loan;
        loan.createdAt = uint128(now);
        loan.updatedAt = uint128(now);
        loan.rocAmount = amountOfROC;
        loan.doAmount = _amountOfDo;
        loanMap[msg.sender].push(loan);

        _checkReserveRatio();

        return amountOfROC;
    }

    function mintDOWithExactAmountOfROC(
        uint256 _amountOfROC,
        uint256 _minAmountOfDo,
        uint256 _deadline
    ) external returns(uint256) {
        require(now < _deadline, "Reserve: deadline");

        uint256 averagePriceOfROC = getAveragePriceOfROC();
        uint256 amountOfDo = _amountOfROC.mul(averagePriceOfROC).div(PRICE_BASE).div(2);  // 2 times over-collateralized

        require(amountOfDo >= _minAmountOfDo, "Reserve: INCESSIVE_AMOUNT");

        rocToken.transferFrom(msg.sender, address(this), _amountOfROC);
        doToken.mint(msg.sender, amountOfDo);

        Loan memory loan;
        loan.createdAt = uint128(now);
        loan.updatedAt = uint128(now);
        loan.rocAmount = _amountOfROC;
        loan.doAmount = amountOfDo;
        loanMap[msg.sender].push(loan);

        _checkReserveRatio();

        return amountOfDo;
    }

    function redeemROC(uint256 _index) external {
        Loan storage loan = loanMap[msg.sender][_index];
        loan.updatedAt = uint128(now);

        rocToken.transfer(msg.sender, loan.rocAmount);
        loan.rocAmount = 0;

        doToken.burnFrom(msg.sender, loan.doAmount);
        loan.doAmount = 0;
    }
}
