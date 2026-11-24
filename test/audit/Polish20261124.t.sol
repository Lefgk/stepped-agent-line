// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SteppedAgentVault} from "../../src/SteppedAgentVault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev USDT-style 6-decimal token: transfer/transferFrom/approve return nothing.
contract NoReturnToken {
    string public name = "NoReturn";
    string public symbol = "NRT";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// @dev 6-decimal token that takes a 1% fee on every transfer.
contract FeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xdead), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @dev 6-decimal token with a hook that calls back into the vault mid-transfer.
contract HookToken is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public lastOk;
    bytes public lastRet;

    constructor() ERC20("Hook", "HOOK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function arm(address t, bytes calldata p) external {
        target = t;
        payload = p;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && from != address(0)) {
            armed = false;
            (lastOk, lastRet) = target.call(payload);
        }
    }
}

contract Polish20261124Test is Test {
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
    uint128 constant MAX_CAP = 250e6;

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
        vault.setGuardian(guardian);
        vm.stopPrank();
        vm.prank(payer);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(agent);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------ access control

    function test_onlyOwnerFunctionsRejectStrangerAndGuardian() public {
        address[2] memory callers = [stranger, guardian];
        for (uint256 i; i < 2; i++) {
            vm.startPrank(callers[i]);
            bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]);
            vm.expectRevert(err);
            vault.withdraw(callers[i], 1);
            vm.expectRevert(err);
            vault.openLine(stranger, 1, 1, 1, 1 days, 0, false);
            vm.expectRevert(err);
            vault.setRecipient(agent, shop, true);
            vm.expectRevert(err);
            vault.setGuardian(callers[i]);
            vm.expectRevert(err);
            vault.clearDefault(agent);
            vm.expectRevert(err);
            vault.unpause();
            vm.stopPrank();
        }
    }

    function test_revokeAndPauseRejectStranger() public {
        vm.startPrank(stranger);
        vm.expectRevert(SteppedAgentVault.NotOwnerOrGuardian.selector);
        vault.revokeAgent(agent);
        vm.expectRevert(SteppedAgentVault.NotOwnerOrGuardian.selector);
        vault.pause();
        vm.stopPrank();
    }

    function test_guardianRemovedLosesPowers() public {
        vm.prank(owner);
        vault.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(SteppedAgentVault.NotOwnerOrGuardian.selector);
        vault.pause();
    }

    function test_ownable2StepHandoff() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        // pending owner has no power yet
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vault.setGuardian(newOwner);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.acceptOwnership();
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.withdraw(owner, 1);
    }

    function test_renounceAgentByNonAgentReverts() public {
        vm.prank(stranger);
        vm.expectRevert(SteppedAgentVault.NotAgent.selector);
        vault.renounceAgent();
        vm.prank(agent);
        vault.renounceAgent();
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.NotAgent.selector); // already inactive
        vault.renounceAgent();
    }

    function test_constructorZeroUsdcReverts() public {
        vm.expectRevert(SteppedAgentVault.ZeroAddress.selector);
        new SteppedAgentVault(owner, address(0));
    }

    function test_openLineZeroAgentAndSetRecipientZeroRevert() public {
        vm.startPrank(owner);
        vm.expectRevert(SteppedAgentVault.ZeroAddress.selector);
        vault.openLine(address(0), 1, 1, 1, 1 days, 0, false);
        vm.expectRevert(SteppedAgentVault.ZeroAddress.selector);
        vault.setRecipient(agent, address(0), true);
        vm.expectRevert(SteppedAgentVault.ZeroAddress.selector);
        vault.withdraw(address(0), 1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ pause / revoke paths

    function test_pauseBlocksBorrowButNotRepayWithdrawDeposit() public {
        vm.prank(agent);
        vault.borrow(shop, 60e6, "p");
        vm.prank(guardian);
        vault.pause();
        assertEq(vault.availableCredit(agent), 0);
        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.borrow(shop, 1, "p");
        vm.prank(payer);
        vault.repay(agent, 10e6);
        vm.prank(owner);
        vault.withdraw(owner, 1e6);
        vm.prank(owner);
        vault.deposit(1e6);
        vm.prank(guardian);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.pause();
        vm.prank(owner);
        vault.unpause();
        vm.prank(agent);
        vault.borrow(shop, 1, "p");
    }

    function test_revokedAgentCanStillBeRepaidAndStepsOnTime() public {
        vm.prank(agent);
        vault.borrow(shop, 60e6, "r");
        vm.prank(guardian);
        vault.revokeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.NotAgent.selector);
        vault.borrow(shop, 1, "r");
        assertEq(vault.availableCredit(agent), 0);
        vm.prank(payer);
        vault.repay(agent, 60e6);
        assertEq(vault.amountDue(agent), 0);
        assertEq(vault.totalPrincipal(), 0);
    }

    function test_revokeBumpsEpochAndWipesAllowlist() public {
        vm.startPrank(owner);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
        assertTrue(vault.isRecipientAllowed(agent, shop));
        vm.prank(guardian);
        vault.revokeAgent(agent);
        assertEq(vault.getLine(agent).epoch, 1);
        assertFalse(vault.isRecipientAllowed(agent, shop));
        vm.prank(owner);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, true);
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.RecipientNotAllowed.selector);
        vault.borrow(shop, 1, "x");
    }

    // ------------------------------------------------------------ time boundaries

    function test_borrowRevertsExactlyAtDueDate() public {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "b");
        uint64 due = vault.getLine(agent).dueDate;
        vm.warp(due - 1);
        vm.prank(agent);
        vault.borrow(shop, 1, "b"); // still open
        vm.warp(due);
        assertEq(vault.availableCredit(agent), 0);
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.LineDue.selector);
        vault.borrow(shop, 1, "b");
    }

    function test_repayAtDueDateIsOnTimeOneSecondLaterIsLate() public {
        vm.prank(agent);
        vault.borrow(shop, 60e6, "b");
        uint64 due = vault.getLine(agent).dueDate;
        vm.warp(due);
        vm.prank(payer);
        vault.repay(agent, 60e6);
        assertEq(vault.getHistory(agent).onTimeCount, 1);

        vm.warp(block.timestamp + TERM);
        vm.prank(agent);
        vault.borrow(shop, 80e6 + 20e6 - 20e6, "b"); // cap now 150
        due = vault.getLine(agent).dueDate;
        vm.warp(due + 1);
        vm.prank(payer);
        vault.repay(agent, 80e6);
        assertEq(vault.getHistory(agent).onTimeCount, 1);
        assertEq(vault.getHistory(agent).lateCount, 1);
        assertEq(vault.getLine(agent).currentCap, STARTER + STEP);
    }

    function test_markDefaultBoundary() public {
        vm.prank(agent);
        vault.borrow(shop, 60e6, "b");
        uint64 due = vault.getLine(agent).dueDate;
        vm.warp(uint256(due) + GRACE);
        vm.expectRevert(SteppedAgentVault.NotDue.selector);
        vault.markDefault(agent);
        vm.warp(uint256(due) + GRACE + 1);
        vm.prank(stranger);
        vault.markDefault(agent);
        vm.expectRevert(SteppedAgentVault.AlreadyFrozen.selector);
        vault.markDefault(agent);
        assertEq(vault.getHistory(agent).defaultCount, 1);
        assertEq(vault.getHistory(agent).lastDefaultAt, block.timestamp);
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.LineFrozen.selector);
        vault.borrow(shop, 1, "b");
    }

    function test_markDefaultRevertsWithoutOpenCycle() public {
        vm.expectRevert(SteppedAgentVault.NoDebt.selector);
        vault.markDefault(agent);
        vm.expectRevert(SteppedAgentVault.NoDebt.selector);
        vault.markDefault(stranger);
    }

    function test_defaultThenFullRepayThenClearRestartsAtStarter() public {
        // climb one step first
        vm.prank(agent);
        vault.borrow(shop, 60e6, "b");
        vm.prank(agent);
        vault.repay(agent, 60e6);
        assertEq(vault.getLine(agent).currentCap, STARTER + STEP);
        vm.warp(block.timestamp + TERM);

        vm.prank(agent);
        vault.borrow(shop, 150e6, "b");
        vm.warp(vault.getLine(agent).dueDate + GRACE + 1);
        vault.markDefault(agent);
        // frozen line: edit blocked, clear blocked while debt remains
        vm.startPrank(owner);
        vm.expectRevert(SteppedAgentVault.LineFrozen.selector);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        vm.expectRevert(SteppedAgentVault.DebtOutstanding.selector);
        vault.clearDefault(agent);
        vm.stopPrank();

        vm.prank(payer);
        vault.repay(agent, 150e6); // frozen: no step, no late count
        assertEq(vault.getHistory(agent).lateCount, 0);
        assertEq(vault.getHistory(agent).onTimeCount, 1);
        vm.prank(owner);
        vault.clearDefault(agent);
        SteppedAgentVault.Line memory l = vault.getLine(agent);
        assertEq(l.currentCap, STARTER);
        assertFalse(l.frozen);
        assertEq(l.dueDate, 0);
        assertEq(vault.getHistory(agent).currentTier, 0);
        assertEq(vault.getHistory(agent).defaultCount, 1);
        vm.prank(agent);
        vault.borrow(shop, STARTER, "again");
    }

    // ------------------------------------------------------------ steps / openLine

    function test_stepRequiresExactlyHalfPeak() public {
        // peak == 50% steps (boundary), covered by under-50 in audit suite
        vm.prank(agent);
        vault.borrow(shop, STARTER / 2, "h");
        vm.prank(agent);
        vault.repay(agent, STARTER / 2);
        assertEq(vault.getLine(agent).currentCap, STARTER + STEP);
    }

    function test_peakCountsHighWaterNotEndDebt() public {
        vm.startPrank(agent);
        vault.borrow(shop, 80e6, "h");
        vault.repay(agent, 70e6); // debt 10, peak 80
        vault.repay(agent, 10e6);
        vm.stopPrank();
        assertEq(vault.getLine(agent).currentCap, STARTER + STEP);
    }

    function test_reopenActiveLineKeepsTierAndRecomputesCap() public {
        vm.prank(agent);
        vault.borrow(shop, 60e6, "h");
        vm.prank(agent);
        vault.repay(agent, 60e6);
        assertEq(vault.getHistory(agent).currentTier, 1);
        vm.prank(owner);
        vault.openLine(agent, 200e6, 10e6, 1_000e6, TERM, GRACE, false);
        assertEq(vault.getLine(agent).currentCap, 210e6);
        assertEq(vault.getHistory(agent).currentTier, 1);
    }

    function test_openLineBelowDebtRevertsOnShrunkLadder() public {
        vm.prank(agent);
        vault.borrow(shop, 90e6, "h");
        vm.prank(owner);
        vm.expectRevert(SteppedAgentVault.CapBelowDebt.selector);
        vault.openLine(agent, 50e6, STEP, MAX_CAP, TERM, GRACE, false);
    }

    function test_renounceThenReopenKeepsTierAndOpenCycle() public {
        vm.prank(agent);
        vault.borrow(shop, 60e6, "h");
        uint64 due = vault.getLine(agent).dueDate;
        vm.prank(agent);
        vault.renounceAgent();
        vm.prank(owner);
        vault.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        assertEq(vault.getLine(agent).dueDate, due);
        assertEq(vault.getLine(agent).principal, 60e6);
    }

    function testFuzz_capAtNeverExceedsMax(uint128 starter, uint128 step, uint128 maxCap, uint8 n) public {
        starter = uint128(bound(starter, 1, type(uint128).max));
        step = uint128(bound(step, 1, type(uint128).max));
        maxCap = uint128(bound(maxCap, starter, type(uint128).max));
        address a = makeAddr("fz");
        vm.startPrank(owner);
        vault.openLine(a, starter, step, maxCap, 1 days, 0, false);
        assertEq(vault.getLine(a).currentCap, starter);
        // re-open repeatedly: cap always within [starter, maxCap]
        vault.openLine(a, starter, step, maxCap, 1 days, 0, false);
        vm.stopPrank();
        assertLe(vault.getLine(a).currentCap, maxCap);
        n; // tier stays 0 without borrow history
    }

    // ------------------------------------------------------------ borrow amounts

    function testFuzz_borrowRepayConservation(uint256 b, uint256 r) public {
        b = bound(b, 1, STARTER);
        r = bound(r, 1, type(uint128).max);
        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vm.prank(agent);
        vault.borrow(shop, b, "f");
        assertEq(vault.totalPrincipal(), b);
        assertEq(usdc.balanceOf(shop), b);
        vm.prank(payer);
        vault.repay(agent, r);
        uint256 paid = r > b ? b : r;
        assertEq(vault.totalPrincipal(), b - paid);
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - b + paid);
    }

    function test_maxAmountsRevertCleanly() public {
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(SteppedAgentVault.ExceedsCredit.selector, type(uint256).max, uint256(STARTER)));
        vault.borrow(shop, type(uint256).max, "m");
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(); // ERC20 insufficient balance
        vault.withdraw(owner, type(uint256).max);
        vm.prank(payer);
        vm.expectRevert(SteppedAgentVault.NoDebt.selector);
        vault.repay(agent, type(uint256).max);
    }

    function test_insufficientLiquidityAfterWithdraw() public {
        vm.startPrank(owner);
        vault.withdraw(owner, 10_000e6);
        vm.stopPrank();
        assertEq(vault.availableCredit(agent), 0);
        vm.prank(agent);
        vm.expectRevert(SteppedAgentVault.InsufficientLiquidity.selector);
        vault.borrow(shop, 1, "l");
    }

    function test_availableCreditCappedByLiquidity() public {
        vm.prank(owner);
        vault.withdraw(owner, 10_000e6 - 30e6);
        assertEq(vault.availableCredit(agent), 30e6);
        assertEq(vault.liquidity(), 30e6);
    }

    function test_borrowToVaultItselfAllowedAndAccountedSafely() public {
        // borrowing to the vault address leaves balance intact but books debt (agent self-harm only)
        vm.prank(agent);
        vault.borrow(address(vault), 10e6, "self");
        assertEq(vault.totalPrincipal(), 10e6);
        assertEq(vault.liquidity(), 10_000e6);
    }

    function test_noAllowlistLineReportsAnyRecipientAllowed() public view {
        assertTrue(vault.isRecipientAllowed(agent, shop));
        assertFalse(vault.isRecipientAllowed(agent, address(0)));
    }

    // ------------------------------------------------------------ non-standard tokens

    function test_noReturnTokenWorks() public {
        NoReturnToken t = new NoReturnToken();
        SteppedAgentVault v = new SteppedAgentVault(owner, address(t));
        t.mint(owner, 1_000e6);
        t.mint(agent, 1_000e6);
        vm.startPrank(owner);
        t.approve(address(v), type(uint256).max);
        v.deposit(1_000e6);
        v.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        vm.stopPrank();
        vm.startPrank(agent);
        t.approve(address(v), type(uint256).max);
        v.borrow(shop, 60e6, "u");
        v.repay(agent, 60e6);
        vm.stopPrank();
        assertEq(t.balanceOf(shop), 60e6);
        assertEq(v.getLine(agent).currentCap, STARTER + STEP);
        vm.prank(owner);
        v.withdraw(owner, 100e6);
    }

    function test_feeTokenDepositEventReportsReceivedAmount() public {
        FeeToken t = new FeeToken();
        SteppedAgentVault v = new SteppedAgentVault(owner, address(t));
        t.mint(owner, 1_000e6);
        vm.startPrank(owner);
        t.approve(address(v), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(v));
        emit SteppedAgentVault.Deposited(owner, 99e6); // 1% fee withheld
        v.deposit(100e6);
        vm.stopPrank();
        assertEq(v.liquidity(), 99e6);
    }

    // ------------------------------------------------------------ reentrancy

    function _hookSetup() internal returns (HookToken t, SteppedAgentVault v) {
        t = new HookToken();
        v = new SteppedAgentVault(owner, address(t));
        t.mint(owner, 1_000e6);
        t.mint(agent, 1_000e6);
        vm.startPrank(owner);
        t.approve(address(v), type(uint256).max);
        v.deposit(500e6);
        v.openLine(agent, STARTER, STEP, MAX_CAP, TERM, GRACE, false);
        vm.stopPrank();
        vm.prank(agent);
        t.approve(address(v), type(uint256).max);
    }

    function test_reentrancyBorrowCallbackBlocked() public {
        (HookToken t, SteppedAgentVault v) = _hookSetup();
        // during borrow's payout, token calls back into borrow as the vault (msg.sender = token, not agent)
        // so use the stronger check: callback into deposit/withdraw/repay guarded by nonReentrant
        t.arm(address(v), abi.encodeCall(SteppedAgentVault.deposit, (1)));
        vm.prank(agent);
        v.borrow(shop, 60e6, "re");
        assertFalse(t.lastOk());
        assertEq(bytes4(t.lastRet()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(v.totalPrincipal(), 60e6);
    }

    function test_reentrancyRepayCallbackBlocked() public {
        (HookToken t, SteppedAgentVault v) = _hookSetup();
        vm.prank(agent);
        v.borrow(shop, 60e6, "re");
        t.arm(address(v), abi.encodeCall(SteppedAgentVault.repay, (agent, 1)));
        vm.prank(agent);
        v.repay(agent, 10e6);
        assertFalse(t.lastOk());
        assertEq(bytes4(t.lastRet()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(v.totalPrincipal(), 50e6);
    }

    function test_reentrancyDepositCallbackBlocked() public {
        (HookToken t, SteppedAgentVault v) = _hookSetup();
        t.arm(address(v), abi.encodeCall(SteppedAgentVault.deposit, (1)));
        vm.prank(agent);
        v.deposit(1e6);
        assertFalse(t.lastOk());
        assertEq(bytes4(t.lastRet()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    // ------------------------------------------------------------ invariants-by-sequence

    function testFuzz_totalPrincipalMatchesAgentDebt(uint256 b1, uint256 r1, uint256 b2) public {
        b1 = bound(b1, 1, STARTER);
        vm.prank(agent);
        vault.borrow(shop, b1, "1");
        r1 = bound(r1, 1, b1);
        vm.prank(payer);
        vault.repay(agent, r1);
        uint256 room = vault.availableCredit(agent);
        if (room > 0) {
            b2 = bound(b2, 1, room);
            vm.prank(agent);
            vault.borrow(shop, b2, "2");
        }
        assertEq(vault.totalPrincipal(), vault.amountDue(agent));
        assertLe(vault.amountDue(agent), vault.getLine(agent).currentCap);
    }
}
