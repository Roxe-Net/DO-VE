// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IROC.sol";
import "./interfaces/IRoUSD.sol";

// This contract can be owned by Foundation, Dev, or investors.
contract Holder is Ownable {

    address public reserve;
    IROC public roc;
    IRoUSD public roUSD;
    string public name;

    address public delegatee;

    constructor(address _reserve, IROC _roc, IRoUSD _roUSD, string memory _name) public {
        reserve = _reserve;
        roc = _roc;
        roUSD = _roUSD;
        name = _name;

        roc.approve(reserve, type(uint256).max);
    }

    function delegate(address _delegatee) external onlyOwner {
        roc.delegate(_delegatee);
    }

    function withdrawRoUSD() external onlyOwner {
        uint256 balance = roUSD.balanceOf(address(this));
        roUSD.transfer(msg.sender, balance);
    }

    function withdrawROC(uint256 _amount) external {
        require(msg.sender == reserve, "only reserve can call");

        roc.transfer(msg.sender, _amount);
    }
}
