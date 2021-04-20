// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint8);
}

// This contract should be owned by a custodian account.
contract RoUSD is ERC20, Ownable {

    using SafeERC20 for IERC20WithDecimals;

    mapping(address => bool) public issuerMap;
    mapping(address => bool) public trustedMap;

    constructor() ERC20("roUSD", "roUSD") public  {
    }

    modifier onlyIssuer() {
        require(issuerMap[msg.sender], "The caller does not have issuer role privileges");
        _;
    }

    function setIssuer(address _issuer, bool _isIssuer) external onlyOwner {
        issuerMap[_issuer] = _isIssuer;
    }

    function setTrustedToken(address _token, bool _isTrustedToken) external onlyOwner {
        trustedMap[_token] = _isTrustedToken;
    }

    function deposit(address _token, uint256 _amount) external {
        require(trustedMap[_token], "RoUSD: token not trusted");

        IERC20WithDecimals(_token).safeTransferFrom(_msgSender(), address(this), _amount);

        uint256 adjustedAmount;
        if (decimals() > IERC20WithDecimals(_token).decimals()) {
          adjustedAmount = _amount * (10 ** uint256(decimals() - IERC20WithDecimals(_token).decimals()));
        } else {
          adjustedAmount = _amount / (10 ** uint256(IERC20WithDecimals(_token).decimals() - decimals()));
        }

        _mint(_msgSender(), adjustedAmount);
    }

    function withdraw(address _token, uint256 _amount) external {
        require(trustedMap[_token], "RoUSD: token not trusted");

        IERC20WithDecimals(_token).safeTransfer(_msgSender(), _amount);

        uint256 adjustedAmount;
        if (decimals() > IERC20WithDecimals(_token).decimals()) {
          adjustedAmount = _amount * (10 ** uint256(decimals() - IERC20WithDecimals(_token).decimals()));
        } else {
          adjustedAmount = _amount / (10 ** uint256(IERC20WithDecimals(_token).decimals() - decimals()));
        }

        _burn(_msgSender(), adjustedAmount);
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by an issuer.
    function mint(address _to, uint256 _amount) external onlyIssuer {
        _mint(_to, _amount);
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) public {
        uint256 decreasedAllowance = allowance(account, _msgSender()).sub(amount, "RoUSD: burn amount exceeds allowance");

        _approve(account, _msgSender(), decreasedAllowance);
        _burn(account, amount);
    }
}
