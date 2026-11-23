// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SteppedAgentVault} from "../src/SteppedAgentVault.sol";
import {SteppedAgentVaultFactory} from "../src/SteppedAgentVaultFactory.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SteppedAgentVaultTest is Test {
    SteppedAgentVault vault;
    MockUSDC usdc;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address stranger = makeAddr("stranger");
    address guardian = makeAddr("guardian");
    address payer = makeAddr("payer");

    uint64 constant TERM = 30 days;
    uint64 constant GRACE = 3 days;
    uint128 constant STARTER = 100e6;
    uint128 constant STEP = 50e6;
    uint128 constant MAX_CAP = 250e6; // starter + 3 steps = 250

    event Borrowed(address indexed agent, address indexed to, uint256 amount, uint256 debt, uint64 dueDate, bytes32 memo);
    event Repaid(address indexed agent, address indexed from, uint256 amount, uint256 remainingDebt);
    event Stepped(address indexed agent, uint128 newCap, uint32 newTier);
    event Defaulted(address indexed agent, uint256 debt, address indexed by);
    event DefaultCleared(address indexed agent, address indexed by, uint128 resetCap);

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        vault = new SteppedAgentVault(owner, address(usdc));
        usdc.mint(owner, 1_000_000e6);
        usdc.mint(payer, 1_000_000e6);
        usdc.mint(agent, 1_000_000e6);

        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        vm.stopPrank();

        vm.prank(payer);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(agent);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _line() internal view returns (SteppedAgentVault.Line memory) {
        return vault.getLine(agent);
    }

    function _hist() internal view returns (SteppedAgentVault.History memory) {
        return vault.getHistory(agent);
    }

    function _credit() internal view returns (SteppedAgentVault.CreditHistory memory) {
        return vault.creditHistory(agent);
    }

    function _cycle(uint256 amount) internal {
        vm.prank(agent);
        vault.borrow(shop, amount, "c");
        vm.prank(payer);
        vault.repay(agent, amount);
        // audit H-1: at most one step per term, so move to the next term
        vm.warp(block.timestamp + TERM);
    }

    // ---------------------------------------------------------------- happy paths

    function test_borrowAndRepayStartsCycle() public {
        uint64 expectedDue = uint64(block.timestamp + TERM);
        vm.expectEmit(true, true, false, true);
        emit Borrowed(agent, shop, 60e6, 60e6, expectedDue, "job-1");
        vm.prank(agent);
        vault.borrow(shop, 60e6, "job-1");
        assertEq(usdc.balanceOf(shop), 60e6);
        assertEq(vault.amountDue(agent), 60e6);
        assertEq(vault.totalPrincipal(), 60e6);
        assertEq(_line().dueDate, expectedDue);
        assertEq(_line().currentCap, STARTER);

        vm.expectEmit(true, true, false, true);
        emit Repaid(agent, payer, 15e6, 45e6);
        vm.prank(payer);
        vault.repay(agent, 15e6);
        assertEq(vault.amountDue(agent), 45e6);
        // partial repay does not step
        assertEq(_line().currentCap, STARTER);
        assertEq(_hist().onTimeCount, 0);

        vm.expectEmit(true, false, false, true);
        emit Stepped(agent, STARTER + STEP, 1);
        vm.prank(agent);
        vault.repay(agent, 45e6);
        assertEq(vault.amountDue(agent), 0);
        assertEq(_line().dueDate, 0);
        assertEq(_line().currentCap, STARTER + STEP);
        assertEq(_hist().onTimeCount, 1);
        assertEq(_hist().currentTier, 1);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
    }

    function test_multipleOnTimeRepaysStepUpToMaxAndNoFurther() public {
        _cycle(STARTER);
        assertEq(_line().currentCap, 150e6);
        assertEq(_credit().currentTier, 1);

        _cycle(150e6);
        assertEq(_line().currentCap, 200e6);
        assertEq(_credit().currentTier, 2);

        _cycle(200e6);
        assertEq(_line().currentCap, MAX_CAP); // 250
        assertEq(_credit().currentTier, 3);

        _cycle(MAX_CAP);
        assertEq(_line().currentCap, MAX_CAP); // clamped
        assertEq(_hist().onTimeCount, 4);
        assertEq(_hist().currentTier, 4);
        assertLe(_line().currentCap, _line().maxCap);

        // cannot borrow more than max
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SteppedAgentVault.ExceedsCredit.selector, MAX_CAP + 1, MAX_CAP));
        vault.borrow(shop, MAX_CAP + 1, "over");
    }

    function test_lateRepayDoesNotStepButAvoidsDefault() public {
        vm.prank(agent);
        vault.borrow(shop, 40e6, "late");
        vm.warp(_line().dueDate + 1);
        vm.prank(payer);
        vault.repay(agent, 40e6);
        assertEq(_line().currentCap, STARTER);
        assertEq(_hist().onTimeCount, 0);
        assertEq(_hist().lateCount, 1);
        assertFalse(_line().frozen);
        assertEq(_line().dueDate, 0);
        // a new cycle can start at the same cap
        vm.prank(agent);
        vault.borrow(shop, 40e6, "next");
        assertEq(_line().currentCap, STARTER);
    }

    function test_markDefaultAfterGraceFreezesLine() public {
        vm.prank(agent);
        vault.borrow(shop, 40e6, "d");

        vm.prank(stranger);
        vm.expectRevert(SteppedAgentVault.NotDue.selector);
        vault.markDefault(agent);

        vm.warp(_line().dueDate + 1);
        // still in grace
        vm.prank(stranger);
        vm.expectRevert(SteppedAgentVault.NotDue.selector);
        vault.markDefault(agent);
        // cannot borrow past due even during grace
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.LineDue.selector);
        vault.borrow(shop, 1, "no");

        vm.warp(_line().dueDate + GRACE + 1);
        vm.expectEmit(true, true, false, true);
        emit Defaulted(agent, 40e6, stranger);
        vm.prank(stranger);
        vault.markDefault(agent);
        assertTrue(_line().frozen);
        assertEq(_hist().defaultCount, 1);
        assertEq(_credit().defaultCount, 1);
        assertTrue(_credit().frozen);

        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.LineFrozen.selector);
        vault.borrow(shop, 1, "frozen");

        vm.prank(stranger);
        vm.expectRevert(SteppedAgentVault.AlreadyFrozen.selector);
        vault.markDefault(agent);

        // repay while frozen does not step
        vm.prank(payer);
        vault.repay(agent, 40e6);
        assertEq(_line().currentCap, STARTER);
        assertEq(_hist().onTimeCount, 0);
        assertTrue(_line().frozen);

        vm.prank(owner);
        vm.expectRevert(SteppedAgentVault.LineFrozen.selector);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);

        vm.expectEmit(true, true, false, true);
        emit DefaultCleared(agent, owner, STARTER);
        vm.prank(owner);
        vault.clearDefault(agent);
        assertFalse(_line().frozen);
        assertEq(_line().currentCap, STARTER);
        assertEq(_hist().currentTier, 0);
        assertEq(_hist().defaultCount, 1); // lifetime kept
        vm.prank(agent);
        vault.borrow(shop, 10e6, "reinstated");
    }

    function test_clearDefaultRequiresFullRepayAndResetsCap() public {
        _cycle(STARTER); // now cap = 150
        vm.prank(agent);
        vault.borrow(shop, 80e6, "x");
        vm.warp(_line().dueDate + GRACE + 1);
        vault.markDefault(agent);
        assertEq(_line().currentCap, 150e6);

        vm.prank(owner);
        vm.expectRevert(SteppedAgentVault.DebtOutstanding.selector);
        vault.clearDefault(agent);

        vm.prank(payer);
        vault.repay(agent, 80e6);
        vm.prank(owner);
        vault.clearDefault(agent);
        assertEq(_line().currentCap, STARTER);
        assertEq(_hist().currentTier, 0);
        assertEq(_hist().onTimeCount, 1); // lifetime kept
    }

    function test_optionalAllowlistAndRevoke() public {
        vm.prank(agent);
        vault.borrow(stranger, 50e6, "open");
        assertEq(usdc.balanceOf(stranger), 50e6);
        vm.prank(payer);
        vault.repay(agent, 50e6);
        assertEq(_line().currentCap, STARTER + STEP);

        vm.startPrank(owner);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
        // tier kept on update of an active zero-debt line
        assertEq(_hist().currentTier, 1);
        assertEq(_line().currentCap, STARTER + STEP);

        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.RecipientNotAllowed.selector);
        vault.borrow(stranger, 10e6, "no");
        vm.prank(agent);
        vault.borrow(shop, 10e6, "yes");

        vm.prank(owner);
        vault.revokeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.NotAgent.selector);
        vault.borrow(shop, 1e6, "y");
        assertEq(vault.amountDue(agent), 10e6);

        vm.startPrank(owner);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
        // progress kept across revoke
        assertEq(_line().currentCap, STARTER + STEP);
        vm.prank(agent);
        vault.borrow(shop, 5e6, "again");
        assertEq(vault.amountDue(agent), 15e6);
    }

    function test_renounceAndGuardianRevokePauseWithdraw() public {
        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(agent);
        vault.renounceAgent();
        assertFalse(_line().active);

        vm.prank(owner);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        vm.prank(guardian);
        vault.revokeAgent(agent);
        assertFalse(_line().active);

        vm.prank(stranger);
        vm.expectRevert(SteppedAgentVault.NotOwnerOrGuardian.selector);
        vault.revokeAgent(agent);

        vm.prank(owner);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        vm.prank(agent);
        vault.borrow(shop, 50e6, "p");

        vm.prank(guardian);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.borrow(shop, 1e6, "no");

        vm.prank(payer);
        vault.repay(agent, 50e6); // on-time repay while paused still steps
        assertEq(_line().currentCap, STARTER + STEP);

        uint256 before = usdc.balanceOf(owner);
        vm.prank(owner);
        vault.withdraw(owner, 1_000e6);
        assertEq(usdc.balanceOf(owner), before + 1_000e6);

        vm.prank(stranger);
        vm.expectRevert();
        vault.unpause();
        vm.prank(owner);
        vault.unpause();
        vm.prank(agent);
        vault.borrow(shop, 1e6, "ok");
    }

    function test_exceedsCreditAndInsufficientLiquidity() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SteppedAgentVault.ExceedsCredit.selector, STARTER + 1, STARTER));
        vault.borrow(shop, STARTER + 1, "big");

        vm.prank(owner);
        vault.withdraw(owner, 10_000e6 - 50e6);
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.InsufficientLiquidity.selector);
        vault.borrow(shop, 51e6, "liq");
        vm.prank(agent);
        vault.borrow(shop, 50e6, "ok");
    }

    function test_repayCapsOverpaymentAndRevertsIfNoDebt() public {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "x");
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        vault.repay(agent, 50e6);
        assertEq(usdc.balanceOf(payer), payerBefore - 10e6);
        assertEq(vault.amountDue(agent), 0);
        vm.prank(payer);
        vm.expectRevert(SteppedAgentVault.NoDebt.selector);
        vault.repay(agent, 1);
    }

    function test_openLineValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(SteppedAgentVault.ZeroAddress.selector);
        vault.openLine(address(0), STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        vm.expectRevert(SteppedAgentVault.InvalidLine.selector);
        vault.openLine(agent, 0, STEP, MAX_CAP, TERM, GRACE, false);
        vm.expectRevert(SteppedAgentVault.InvalidLine.selector);
        vault.openLine(agent, STARTER, 0, MAX_CAP, TERM, GRACE, false);
        vm.expectRevert(SteppedAgentVault.InvalidLine.selector);
        vault.openLine(agent, STARTER, STEP, STARTER - 1, TERM, GRACE, false);
        vm.expectRevert(SteppedAgentVault.InvalidTerm.selector);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, 1 days - 1, GRACE, false);
        vm.expectRevert(SteppedAgentVault.InvalidTerm.selector);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, 365 days + 1, GRACE, false);
        vm.expectRevert(SteppedAgentVault.InvalidGrace.selector);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, 14 days + 1, false);
        vm.stopPrank();
    }

    function test_openLineCapBelowDebtReverts() public {
        vm.prank(agent);
        vault.borrow(shop, 80e6, "x");
        vm.prank(owner);
        // new max below outstanding debt
        vm.expectRevert(SteppedAgentVault.CapBelowDebt.selector);
        vault.openLine(agent, 10e6, STEP, 50e6, TERM, GRACE, false);
    }

    function test_depositAnyoneWithdrawOwnerOnly() public {
        usdc.mint(stranger, 5e6);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 5e6);
        vault.deposit(5e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.withdraw(stranger, 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 10_005e6);
    }

    function test_zeroAmountGuardsAndFactory() public {
        vm.prank(owner);
        vm.expectRevert(SteppedAgentVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.prank(owner);
        vm.expectRevert(SteppedAgentVault.ZeroAmount.selector);
        vault.withdraw(owner, 0);
        vm.prank(owner);
        vm.expectRevert(SteppedAgentVault.ZeroAddress.selector);
        vault.withdraw(address(0), 1);
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.ZeroAddress.selector);
        vault.borrow(address(0), 1, "");
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.ZeroAmount.selector);
        vault.borrow(shop, 0, "");

        SteppedAgentVaultFactory factory = new SteppedAgentVaultFactory(address(usdc));
        vm.prank(owner);
        address v = factory.createVault();
        assertEq(SteppedAgentVault(v).owner(), owner);
        assertEq(address(SteppedAgentVault(v).usdc()), address(usdc));
        assertEq(factory.vaultsOf(owner).length, 1);
        assertEq(factory.vaultsOf(owner)[0], v);

        vm.expectRevert(SteppedAgentVaultFactory.ZeroAddress.selector);
        new SteppedAgentVaultFactory(address(0));
    }

    function test_clearDefaultWhenNotFrozenAndMarkWithNoDebtRevert() public {
        vm.prank(owner);
        vm.expectRevert(SteppedAgentVault.NotFrozen.selector);
        vault.clearDefault(agent);
        vm.warp(block.timestamp + TERM + GRACE + 1);
        vm.expectRevert(SteppedAgentVault.NoDebt.selector);
        vault.markDefault(agent);
    }

    function test_availableCreditZeroWhenBlocked() public {
        assertEq(vault.availableCredit(agent), STARTER);
        vm.prank(agent);
        vault.borrow(shop, 40e6, "a");
        assertEq(vault.availableCredit(agent), STARTER - 40e6);
        vm.warp(_line().dueDate);
        assertEq(vault.availableCredit(agent), 0);
    }

    function test_publicCreditHistoryShape() public {
        _cycle(50e6);
        SteppedAgentVault.CreditHistory memory h = _credit();
        assertEq(h.onTimeCount, 1);
        assertEq(h.defaultCount, 0);
        assertEq(h.currentTier, 1);
        assertEq(h.currentCap, STARTER + STEP);
        assertEq(h.starterCap, STARTER);
        assertEq(h.maxCap, MAX_CAP);
        assertFalse(h.frozen);
        assertTrue(h.active);
        assertEq(h.lastDefaultAt, 0);
    }

    function test_multipleBorrowsInOneCycleOneStep() public {
        vm.prank(agent);
        vault.borrow(shop, 30e6, "1");
        uint64 due = _line().dueDate;
        vm.prank(agent);
        vault.borrow(shop, 20e6, "2");
        assertEq(_line().dueDate, due);
        assertEq(vault.amountDue(agent), 50e6);
        vm.prank(payer);
        vault.repay(agent, 50e6);
        assertEq(_hist().onTimeCount, 1);
        assertEq(_line().currentCap, STARTER + STEP);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_borrowRespectsCurrentCap(uint256 a1, uint256 a2, uint256 a3) public {
        uint256[3] memory amts = [bound(a1, 1, STARTER + 100e6), bound(a2, 1, STARTER + 100e6), bound(a3, 1, STARTER + 100e6)];
        uint256 debt;
        for (uint256 i; i < 3; i++) {
            vm.prank(agent);
            try vault.borrow(shop, amts[i], bytes32(i)) {
                debt += amts[i];
            } catch {}
        }
        assertLe(debt, STARTER);
        assertEq(vault.amountDue(agent), debt);
        assertEq(usdc.balanceOf(shop), debt);
        assertLe(_line().currentCap, MAX_CAP);
    }

    function testFuzz_capNeverExceedsMaxAfterOnTimeCycles(uint8 n) public {
        n = uint8(bound(n, 1, 12));
        for (uint256 i; i < n; i++) {
            uint256 cap = _line().currentCap;
            _cycle(cap);
            assertLe(_line().currentCap, MAX_CAP);
            uint256 expected = uint256(STARTER) + uint256(_hist().currentTier) * STEP;
            if (expected > MAX_CAP) expected = MAX_CAP;
            assertEq(_line().currentCap, expected);
        }
        assertLe(_credit().currentCap, _credit().maxCap);
    }

    function testFuzz_repayNeverOverCollects(uint256 borrowAmt, uint256 repayAmt) public {
        borrowAmt = bound(borrowAmt, 1, STARTER);
        repayAmt = bound(repayAmt, 1, 10 * uint256(STARTER));
        vm.prank(agent);
        vault.borrow(shop, borrowAmt, "f");
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        vault.repay(agent, repayAmt);
        uint256 taken = payerBefore - usdc.balanceOf(payer);
        assertLe(taken, borrowAmt);
        assertEq(taken + vault.amountDue(agent), borrowAmt);
    }

    function testFuzz_nonAgentCannotBorrow(address caller) public {
        vm.assume(caller != agent);
        vm.prank(caller);
        vm.expectRevert(SteppedAgentVault.NotAgent.selector);
        vault.borrow(shop, 1e6, bytes32(0));
    }

    function testFuzz_defaultOnlyAfterGrace(uint64 dt) public {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "g");
        uint64 due = _line().dueDate;
        dt = uint64(bound(dt, 0, TERM + GRACE + 30 days));
        vm.warp(due + dt); // warp relative to due: actually due + dt starting from due
        // reset and warp from borrow time more clearly:
        // due is start+TERM, we are now at due+dt
        if (block.timestamp <= uint256(due) + GRACE) {
            vm.expectRevert(SteppedAgentVault.NotDue.selector);
            vault.markDefault(agent);
            assertFalse(_line().frozen);
        } else {
            vault.markDefault(agent);
            assertTrue(_line().frozen);
            vm.prank(agent);
            vm.expectRevert(SteppedAgentVault.LineFrozen.selector);
            vault.borrow(shop, 1, "no");
        }
    }

    function testFuzz_fundsConservedAcrossBorrowRepay(uint256 borrowAmt, uint256 repayAmt) public {
        borrowAmt = bound(borrowAmt, 1, STARTER);
        repayAmt = bound(repayAmt, 1, STARTER);
        uint256 vault0 = usdc.balanceOf(address(vault));
        vm.prank(agent);
        vault.borrow(shop, borrowAmt, "c");
        assertEq(usdc.balanceOf(address(vault)) + vault.amountDue(agent), vault0);
        vm.prank(payer);
        vault.repay(agent, repayAmt);
        assertEq(usdc.balanceOf(address(vault)) + vault.amountDue(agent), vault0);
    }

    function testFuzz_allowlistEnforced(address to) public {
        vm.assume(to != shop && to != address(0));
        vm.startPrank(owner);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.RecipientNotAllowed.selector);
        vault.borrow(to, 1e6, bytes32(0));
    }

    function testFuzz_openLineParams(uint128 starter, uint128 step, uint128 maxCap, uint64 term, uint64 grace) public {
        starter = uint128(bound(starter, 0, 10_000e6));
        step = uint128(bound(step, 0, 10_000e6));
        maxCap = uint128(bound(maxCap, 0, 20_000e6));
        term = uint64(bound(term, 0, 400 days));
        grace = uint64(bound(grace, 0, 30 days));
        address a = makeAddr("fresh-agent");
        vm.prank(owner);
        if (starter == 0 || step == 0 || maxCap < starter) {
            vm.expectRevert(SteppedAgentVault.InvalidLine.selector);
            vault.openLine(a, starter, step, maxCap, term == 0 ? TERM : term, grace > 14 days ? 0 : grace, false);
        } else if (term < 1 days || term > 365 days) {
            vm.expectRevert(SteppedAgentVault.InvalidTerm.selector);
            vault.openLine(a, starter, step, maxCap, term, grace > 14 days ? 0 : grace, false);
        } else if (grace > 14 days) {
            vm.expectRevert(SteppedAgentVault.InvalidGrace.selector);
            vault.openLine(a, starter, step, maxCap, term, grace, false);
        } else {
            vault.openLine(a, starter, step, maxCap, term, grace, false);
            SteppedAgentVault.Line memory line = vault.getLine(a);
            assertEq(line.currentCap, starter);
            assertLe(line.currentCap, line.maxCap);
        }
    }
}
