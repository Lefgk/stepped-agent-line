// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFiatToken {
    function masterMinter() external view returns (address);
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address to, uint256 amount) external returns (bool);
}

/// @dev Fund real Circle USDC on a fork. Tries `deal` first; if the balance doesn't move,
///      impersonates the USDC masterMinter and mints.
abstract contract FundUsdc is Test {
    function fundUsdc(address token, address to, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(to);
        try this.tryDeal(token, to, before + amount) {
            if (IERC20(token).balanceOf(to) >= before + amount) return;
        } catch {}

        address minterController = IFiatToken(token).masterMinter();
        vm.prank(minterController);
        IFiatToken(token).configureMinter(address(this), type(uint256).max);
        IFiatToken(token).mint(to, amount);
        require(IERC20(token).balanceOf(to) >= before + amount, "fundUsdc: mint failed");
    }

    function tryDeal(address token, address to, uint256 total) external {
        deal(token, to, total, true);
    }
}
