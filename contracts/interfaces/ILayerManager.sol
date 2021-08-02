// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface ILayerManager {
    function getAmountPerLayer(uint256 _soldAmount) external pure returns(uint256);
    function getPriceIncrementPerLayer(uint256 _soldAmount) external pure returns(uint256);
}
