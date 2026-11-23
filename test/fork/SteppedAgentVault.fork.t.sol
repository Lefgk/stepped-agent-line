// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SteppedAgentVault} from "../../src/SteppedAgentVault.sol";
import {SteppedAgentVaultFactory} from "../../src/SteppedAgentVaultFactory.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";
import {FundUsdc} from "../FundUsdc.sol";

/// @dev Runs against a fork of a live chain using the chain's real Circle USDC.
///      Either run `forge test --fork-url <rpc>` (only the matching chain's suite runs), or set
///      MAINNET_FORK_RPC / BASE_FORK_RPC (e.g. a local `anvil --fork-url`). Otherwise skipped.
abstract contract ForkBase is FundUsdc {
    SteppedAgentVaultFactory factory;
    SteppedAgentVault vault;
    IERC20Metadata usdc;
    address owner = makeAddr("fork-owner");
    address agent = makeAddr("fork-agent");
    address shop = makeAddr("fork-shop");
    address stranger = makeAddr("fork-stranger");
    bool active;

    uint128 constant STARTER = 100e6;
    uint128 constant STEP = 50e6;
    uint128 constant MAX_CAP = 250e6;
    uint64 constant TERM = 30 days;
    uint64 constant GRACE = 3 days;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already running on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return; // no fork configured -> tests skip
            vm.createSelectFork(rpc);
        } else {
            return; // running on a different chain's fork -> skip
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
        usdc = IERC20Metadata(DeployConfig.get(block.chainid).usdc);

        factory = new SteppedAgentVaultFactory(address(usdc));
        vm.prank(owner);
        vault = SteppedAgentVault(factory.createVault());

        fundUsdc(address(usdc), owner, 10_000e6);
        vm.startPrank(owner);
        IERC20(address(usdc)).approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_realUsdcMetadata() public onFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertGt(address(usdc).code.length, 0);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_fork_onTimeRepayStepsCapWithRealUsdc() public onFork {
        uint256 vault0 = usdc.balanceOf(address(vault));
        vm.prank(agent);
        vault.borrow(shop, 60e6, "a");
        assertEq(usdc.balanceOf(shop), 60e6);
        assertEq(vault.amountDue(agent), 60e6);
        assertEq(usdc.balanceOf(address(vault)) + vault.amountDue(agent), vault0);

        fundUsdc(address(usdc), agent, 300e6);
        vm.startPrank(agent);
        IERC20(address(usdc)).approve(address(vault), type(uint256).max);
        vault.repay(agent, 60e6);
        vm.stopPrank();

        assertEq(vault.amountDue(agent), 0);
        assertEq(vault.getLine(agent).currentCap, STARTER + STEP);
        assertEq(vault.creditHistory(agent).onTimeCount, 1);
        assertEq(vault.creditHistory(agent).currentTier, 1);
        assertLe(vault.getLine(agent).currentCap, MAX_CAP);
        assertEq(usdc.balanceOf(address(vault)), vault0);

        vm.warp(block.timestamp + 30 days); // audit H-1: one step per term
        vm.prank(agent);
        vault.borrow(shop, STARTER + STEP, "full");
        vm.prank(agent);
        vault.repay(agent, STARTER + STEP);
        assertEq(vault.getLine(agent).currentCap, STARTER + 2 * STEP);
    }

    function test_fork_defaultFreezesAndFundsConserved() public onFork {
        uint256 vault0 = usdc.balanceOf(address(vault));
        vm.prank(agent);
        vault.borrow(shop, 20e6, "e");

        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert();
        vault.borrow(shop, 1e6, "p");

        fundUsdc(address(usdc), stranger, 50e6);
        vm.startPrank(stranger);
        IERC20(address(usdc)).approve(address(vault), type(uint256).max);
        vault.repay(agent, 20e6);
        vm.stopPrank();
        assertEq(vault.amountDue(agent), 0);
        assertEq(usdc.balanceOf(address(vault)), vault0);

        vm.prank(owner);
        vault.unpause();
        vm.prank(agent);
        vault.borrow(shop, 30e6, "again");

        vm.warp(block.timestamp + TERM + GRACE + 1);
        vault.markDefault(agent);
        assertTrue(vault.getLine(agent).frozen);
        assertEq(vault.creditHistory(agent).defaultCount, 1);
        assertEq(vault.availableCredit(agent), 0);

        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.LineFrozen.selector);
        vault.borrow(shop, 1, "blocked");

        vm.prank(owner);
        vault.revokeAgent(agent);
        uint256 leftover = usdc.balanceOf(address(vault));
        uint256 before = usdc.balanceOf(owner);
        vm.prank(owner);
        vault.withdraw(owner, leftover);
        assertEq(usdc.balanceOf(owner), before + leftover);
        assertEq(leftover + vault.amountDue(agent), vault0);
    }

    function testFuzz_fork_capNeverExceedsMax(uint256 a1, uint256 a2, uint256 a3) public onFork {
        uint256[3] memory amts = [bound(a1, 1, 80e6), bound(a2, 1, 80e6), bound(a3, 1, 80e6)];
        uint256 debt;
        for (uint256 i; i < 3; i++) {
            vm.prank(agent);
            try vault.borrow(shop, amts[i], bytes32(i)) {
                debt += amts[i];
            } catch {}
        }
        assertLe(debt, vault.getLine(agent).currentCap);
        assertLe(vault.getLine(agent).currentCap, MAX_CAP);
        assertEq(vault.amountDue(agent), debt);
    }
}

contract EthereumForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
