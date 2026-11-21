// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SteppedAgentVault} from "../src/SteppedAgentVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract Handler is Test {
    SteppedAgentVault public vault;
    MockUSDC public usdc;
    address public owner;
    address public agent;
    address[] public recipients;
    address public outsider = makeAddr("outsider-not-allowlisted");
    address public payer = makeAddr("handler-payer");

    uint256 public ghostBorrowed;
    uint256 public ghostRepaid;
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    uint256 public ghostOutsiderReceived;
    uint256 public ghostBorrowsWhileFrozen;
    uint256 public ghostBorrowsWhileBlocked;
    uint256 public ghostOverCollect;
    uint256 public ghostCapOverMax;
    uint256 public calls;

    constructor(SteppedAgentVault v, MockUSDC u, address o, address a, address[] memory r, uint256 initialDeposit) {
        vault = v;
        usdc = u;
        owner = o;
        agent = a;
        recipients = r;
        ghostDeposited = initialDeposit;
        usdc.mint(payer, 50_000_000e6);
        vm.prank(payer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function borrow(uint256 amt, uint256 rIdx) external {
        calls++;
        amt = bound(amt, 1, 20_000e6);
        address to = rIdx % 8 == 0 ? outsider : recipients[rIdx % recipients.length];
        SteppedAgentVault.Line memory line = vault.getLine(agent);
        bool blocked = !line.active || line.frozen || vault.paused()
            || (line.dueDate != 0 && block.timestamp >= line.dueDate);
        bool wasFrozen = line.frozen;
        vm.prank(agent);
        try vault.borrow(to, amt, bytes32(calls)) {
            if (blocked) ghostBorrowsWhileBlocked++;
            if (wasFrozen) ghostBorrowsWhileFrozen++;
            if (to == outsider) ghostOutsiderReceived += amt;
            ghostBorrowed += amt;
            if (vault.getLine(agent).currentCap > vault.getLine(agent).maxCap) ghostCapOverMax++;
        } catch {}
    }

    function repay(uint256 amt) external {
        amt = bound(amt, 1, 20_000e6);
        uint256 debt = vault.amountDue(agent);
        if (debt == 0) return;
        uint256 before = usdc.balanceOf(payer);
        vm.prank(payer);
        try vault.repay(agent, amt) {
            uint256 taken = before - usdc.balanceOf(payer);
            ghostRepaid += taken;
            if (taken > debt) ghostOverCollect++;
            if (vault.getLine(agent).currentCap > vault.getLine(agent).maxCap) ghostCapOverMax++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 20 days));
    }

    function togglePause(bool p) external {
        bool isPaused = vault.paused();
        vm.prank(owner);
        if (p && !isPaused) vault.pause();
        else if (!p && isPaused) vault.unpause();
        else vault.owner();
    }

    function revokeAndReopen(bool reopen) external {
        SteppedAgentVault.Line memory line = vault.getLine(agent);
        if (line.frozen) return;
        vm.startPrank(owner);
        vault.revokeAgent(agent);
        if (reopen) {
            if (block.timestamp >= type(uint64).max - 400 days) {
                vm.stopPrank();
                return;
            }
            try vault.openLine(agent, line.starterCap, line.stepSize, line.maxCap, line.term, line.grace, true) {
                for (uint256 i; i < recipients.length; i++) {
                    vault.setRecipient(agent, recipients[i], true);
                }
            } catch {}
        }
        vm.stopPrank();
    }

    function maybeMarkDefault() external {
        try vault.markDefault(agent) {} catch {}
    }

    function maybeClearDefault() external {
        vm.prank(owner);
        try vault.clearDefault(agent) {} catch {}
    }

    function ownerWithdrawDeposit(uint256 amt, bool isWithdraw) external {
        amt = bound(amt, 1, 50_000e6);
        if (isWithdraw) {
            uint256 bal = usdc.balanceOf(address(vault));
            if (bal == 0) return;
            amt = bound(amt, 1, bal);
            uint256 before = usdc.balanceOf(address(vault));
            vm.prank(owner);
            try vault.withdraw(owner, amt) {
                ghostWithdrawn += before - usdc.balanceOf(address(vault));
            } catch {}
        } else {
            vm.startPrank(owner);
            usdc.approve(address(vault), amt);
            uint256 before = usdc.balanceOf(address(vault));
            try vault.deposit(amt) {
                ghostDeposited += usdc.balanceOf(address(vault)) - before;
            } catch {}
            vm.stopPrank();
        }
    }
}

contract SteppedAgentVaultInvariantTest is Test {
    SteppedAgentVault vault;
    MockUSDC usdc;
    Handler handler;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    uint256 constant FUND = 1_000_000e6;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        vault = new SteppedAgentVault(owner, address(usdc));
        address[] memory r = new address[](3);
        r[0] = makeAddr("r0");
        r[1] = makeAddr("r1");
        r[2] = makeAddr("r2");

        usdc.mint(owner, FUND * 2);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(FUND);
        vault.openLine(agent, 100e6, 50e6, 1_000e6, 30 days, 3 days, true);
        for (uint256 i; i < r.length; i++) {
            vault.setRecipient(agent, r[i], true);
        }
        vm.stopPrank();

        handler = new Handler(vault, usdc, owner, agent, r, FUND);
        targetContract(address(handler));
        address fuzzCaller = makeAddr("fuzz-caller");
        vm.deal(fuzzCaller, 1_000 ether);
        targetSender(fuzzCaller);
    }

    function invariant_capNeverExceedsMax() public view {
        SteppedAgentVault.Line memory line = vault.getLine(agent);
        assertLe(line.currentCap, line.maxCap);
        assertEq(handler.ghostCapOverMax(), 0);
        // After a default reset currentCap == starter; openLine recomputes from the tier ladder
        // so currentCap is never below starter when starter <= max.
        if (line.starterCap > 0 && line.starterCap <= line.maxCap) {
            assertGe(line.currentCap, line.starterCap);
        }
    }

    function invariant_currentCapMatchesTierLadder() public view {
        SteppedAgentVault.Line memory line = vault.getLine(agent);
        SteppedAgentVault.History memory hist = vault.getHistory(agent);
        if (line.starterCap == 0) return;
        uint256 stepped = uint256(line.starterCap);
        if (hist.currentTier != 0 && line.stepSize != 0) {
            if (uint256(hist.currentTier) > type(uint256).max / line.stepSize) {
                stepped = line.maxCap;
            } else {
                stepped = uint256(line.starterCap) + uint256(hist.currentTier) * uint256(line.stepSize);
                if (stepped > line.maxCap) stepped = line.maxCap;
            }
        } else if (stepped > line.maxCap) {
            stepped = line.maxCap;
        }
        assertEq(line.currentCap, stepped);
    }

    function invariant_defaultFreezesTheLine() public view {
        assertEq(handler.ghostBorrowsWhileFrozen(), 0);
        SteppedAgentVault.Line memory line = vault.getLine(agent);
        if (line.frozen) {
            // available credit must be zero while frozen, even mid-cycle
            assertEq(vault.availableCredit(agent), 0);
        }
    }

    function invariant_noBorrowWhileBlocked() public view {
        assertEq(handler.ghostBorrowsWhileBlocked(), 0);
    }

    function invariant_backerFundsConserved() public view {
        // vault + outstanding principal = deposits - withdrawals
        // equivalently: vault = deposits - withdrawals - borrowed + repaid
        assertEq(
            usdc.balanceOf(address(vault)),
            handler.ghostDeposited() + handler.ghostRepaid() - handler.ghostWithdrawn() - handler.ghostBorrowed()
        );
        assertEq(vault.totalPrincipal(), vault.amountDue(agent));
        assertEq(usdc.balanceOf(address(vault)) + vault.totalPrincipal(), handler.ghostDeposited() - handler.ghostWithdrawn());
    }

    function invariant_neverPaysOutsider() public view {
        assertEq(handler.ghostOutsiderReceived(), 0);
        assertEq(usdc.balanceOf(handler.outsider()), 0);
    }

    function invariant_repayNeverOverCollects() public view {
        assertEq(handler.ghostOverCollect(), 0);
        assertEq(vault.getHistory(agent).totalBorrowed, handler.ghostBorrowed());
        assertEq(vault.getHistory(agent).totalRepaid, handler.ghostRepaid());
        assertLe(handler.ghostRepaid(), handler.ghostBorrowed());
    }

    function invariant_creditHistoryConsistency() public view {
        SteppedAgentVault.CreditHistory memory h = vault.creditHistory(agent);
        SteppedAgentVault.Line memory line = vault.getLine(agent);
        SteppedAgentVault.History memory hist = vault.getHistory(agent);
        assertEq(h.onTimeCount, hist.onTimeCount);
        assertEq(h.defaultCount, hist.defaultCount);
        assertEq(h.currentTier, hist.currentTier);
        assertEq(h.currentCap, line.currentCap);
        assertEq(h.frozen, line.frozen);
        assertLe(h.currentCap, h.maxCap);
    }
}
