// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SteppedAgentVault} from "../../src/SteppedAgentVault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// @notice Audit 2026-11-23 PoCs and regression tests. See AUDIT-2026-11-23.md.
contract Audit20261123Test is Test {
    SteppedAgentVault vault;
    MockUSDC usdc;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address sink = makeAddr("agent-controlled-sink");
    address keeper = makeAddr("keeper");

    uint64 constant TERM = 1 days; // shortest allowed term = most favourable to the attacker
    uint64 constant GRACE = 0;
    uint128 constant STARTER = 100e6;
    uint128 constant STEP = 100e6;
    uint128 constant MAX_CAP = 10_000e6; // 99 steps above starter

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        vault = new SteppedAgentVault(owner, address(usdc));
        usdc.mint(owner, 1_000_000e6);
        usdc.mint(agent, 1_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(20_000e6);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        vm.stopPrank();
        vm.prank(agent);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// H-1 PoC: dust borrow/repay loops in one block. Before the fix this climbed to MAX_CAP
    /// (and onTimeCount = 99) for gas only; then the agent borrowed MAX_CAP and walked away.
    function test_H1_dustLoopCannotClimbLadder() public {
        for (uint256 i; i < 99; i++) {
            vm.startPrank(agent);
            vault.borrow(agent, 1, "dust");
            vault.repay(agent, 1);
            vm.stopPrank();
        }
        assertEq(vault.getLine(agent).currentCap, STARTER, "cap must not move on dust cycles");
        assertEq(vault.creditHistory(agent).onTimeCount, 0, "history must not inflate");
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SteppedAgentVault.ExceedsCredit.selector, uint256(MAX_CAP), uint256(STARTER)));
        vault.borrow(sink, MAX_CAP, "rug");
    }

    /// H-1 PoC variant: full-size same-block loops (agent repays with the money it just borrowed).
    function test_H1_fullSizeSameBlockLoopStepsAtMostOnce() public {
        for (uint256 i; i < 10; i++) {
            uint256 cap = vault.getLine(agent).currentCap;
            vm.startPrank(agent);
            vault.borrow(agent, cap, "loop");
            vault.repay(agent, cap);
            vm.stopPrank();
        }
        assertEq(vault.getLine(agent).currentCap, STARTER + STEP);
        assertEq(vault.creditHistory(agent).onTimeCount, 1);
    }

    /// Regression: honest agent that uses >= 50% of the cap once per term still steps every term.
    function test_H1_honestCyclesStillStep() public {
        for (uint256 i = 1; i <= 5; i++) {
            uint256 cap = vault.getLine(agent).currentCap;
            vm.prank(agent);
            vault.borrow(agent, cap / 2, "work");
            vm.warp(block.timestamp + TERM);
            vm.prank(agent);
            vault.repay(agent, cap / 2); // exactly at dueDate = on time
            assertEq(vault.getLine(agent).currentCap, STARTER + i * STEP);
        }
        assertEq(vault.creditHistory(agent).onTimeCount, 5);
        assertEq(vault.cyclePeak(agent), 0);
    }

    /// Regression: just under 50% peak usage does not step; peak is reset at cycle close.
    function test_H1_usageThreshold() public {
        vm.startPrank(agent);
        vault.borrow(agent, STARTER / 2 - 1, "u");
        assertEq(vault.cyclePeak(agent), STARTER / 2 - 1);
        vault.repay(agent, STARTER / 2 - 1);
        vm.stopPrank();
        assertEq(vault.getLine(agent).currentCap, STARTER);
        assertEq(vault.cyclePeak(agent), 0);
    }

    /// Fuzz: any mix of borrow/repay/warp never gives more than 1 + elapsed/TERM steps.
    function testFuzz_H1_stepsRateLimited(uint256 seed) public {
        uint256 start = block.timestamp;
        for (uint256 i; i < 40; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 3;
            if (op == 0) {
                uint256 room = vault.availableCredit(agent);
                if (room > 0) {
                    vm.prank(agent);
                    vault.borrow(agent, bound(r >> 8, 1, room), "f");
                }
            } else if (op == 1) {
                uint256 due = vault.amountDue(agent);
                if (due > 0) {
                    usdc.mint(agent, due);
                    vm.prank(agent);
                    vault.repay(agent, bound(r >> 8, 1, due));
                }
            } else {
                vm.warp(block.timestamp + bound(r >> 8, 0, TERM));
            }
        }
        uint256 maxSteps = 1 + (block.timestamp - start) / TERM;
        assertLe(vault.creditHistory(agent).onTimeCount, maxSteps);
        assertLe(vault.getLine(agent).currentCap, uint256(STARTER) + maxSteps * STEP);
    }

    /// L-1 (acknowledged): default is only recorded if someone calls markDefault before repayment.
    function test_L1_lateRepayAfterGraceWithoutKeeperLeavesNoDefault() public {
        vm.prank(agent);
        vault.borrow(agent, 60e6, "x");
        vm.warp(vault.getLine(agent).dueDate + 10 days);
        vm.prank(agent);
        vault.repay(agent, 60e6);
        assertEq(vault.creditHistory(agent).defaultCount, 0);
        assertEq(vault.getHistory(agent).lateCount, 1);
        assertFalse(vault.getLine(agent).frozen);
    }
}
