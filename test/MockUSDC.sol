// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only stand-in for USDC. Never deployed to a real network.
/// @dev Matches real USDC where it matters: 6 decimals, not 18.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @dev Open mint — fine here, catastrophic anywhere real.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
