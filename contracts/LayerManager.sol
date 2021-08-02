// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/ILayerManager.sol";

contract LayerManager is ILayerManager {

    function getAmountPerLayer(uint256 _soldAmount) public override pure returns(uint256) {
        uint256 sum = 0;
        uint256 amount;
        for (amount = 1000e18; amount < 10000e18; amount += 500e18) {
            sum += amount * 10 * 2;
            if (sum >= _soldAmount) {
                return amount;
            }
        }

        for (amount = 10000e18; amount < 45000e18; amount += 1000e18) {
            sum += amount * 10 * 2;
            if (sum >= _soldAmount) {
                return amount;
            }
        }

        amount = 45000e18;
        sum += amount * 9 * 2;
        if (sum >= _soldAmount) {
            return amount;
        }

        amount = 50000e18;
        return amount;
    }

    function getPriceIncrementPerLayer(uint256 _soldAmount) public override pure returns(uint256) {
        if (_soldAmount < 540000e18) {
            return 1e16;  // 0.01 roUSD
        } else if (_soldAmount < 1890000e18) {
            return 2e16;  // 0.02 roUSD
        } else if (_soldAmount < 4790000e18) {
            return 3e16;  // 0.03 roUSD
        } else if (_soldAmount < 9690000e18) {
            return 4e16;  // 0.04 roUSD
        } else if (_soldAmount < 16590000e18) {
            return 5e16;  // 0.05 roUSD
        } else {
            return 6e16;  // 0.06 roUSD
        }
    }
}
