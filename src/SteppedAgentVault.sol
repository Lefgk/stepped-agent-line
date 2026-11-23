// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SteppedAgentVault
/// @notice Backer-funded USDC credit lines for AI agent addresses. Each line starts at a
///         starter cap and steps up by a fixed amount after every on-time full repayment,
///         up to a max cap. A missed due date, after a short grace, lets anyone mark a
///         public default and freeze the line. v1 is fully backer-collateralized: no pooled
///         lenders, no interest, no fee. Anyone may repay. Other apps can read a public
///         per-agent credit history (on-time count, defaults, current tier).
/// @dev    PROTOTYPE - NOT AUDITED. USDC only. Agents cannot make arbitrary calls.
contract SteppedAgentVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint64 public constant MIN_TERM = 1 days;
    uint64 public constant MAX_TERM = 365 days;
    uint64 public constant MAX_GRACE = 14 days;
    /// @notice A cycle only counts toward a step if its peak debt reached this share of the cap.
    uint16 public constant MIN_USAGE_BPS = 5_000; // 50%
    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct Line {
        bool active; // false = revoked / never opened
        bool allowlistEnabled; // if true, borrow `to` must be allowlisted
        bool frozen; // set on default; blocks borrows until owner clears after full repay
        uint32 epoch; // bumped on revoke so the old allowlist dies
        uint64 term; // length of each borrow cycle
        uint64 grace; // delay after dueDate before anyone may mark default
        uint64 dueDate; // 0 = no open cycle; set on the first borrow of a cycle
        uint128 starterCap;
        uint128 stepSize;
        uint128 maxCap;
        uint128 currentCap; // outstanding debt cap; never exceeds maxCap
        uint128 principal; // outstanding USDC debt
    }

    struct History {
        uint32 onTimeCount; // lifetime on-time full repayments
        uint32 lateCount; // lifetime full repayments after dueDate (no default)
        uint32 defaultCount; // lifetime defaults
        uint32 currentTier; // on-time steps since last default reset (0 = starter)
        uint64 lastDefaultAt; // 0 if never defaulted
        uint64 lastOnTimeAt; // 0 if never stepped
        uint128 totalBorrowed;
        uint128 totalRepaid;
    }

    /// @notice Public, stable view for other apps. Does not include internal bookkeeping.
    struct CreditHistory {
        uint32 onTimeCount;
        uint32 defaultCount;
        uint32 currentTier;
        uint128 currentCap;
        uint128 starterCap;
        uint128 maxCap;
        bool frozen;
        bool active;
        uint64 lastDefaultAt;
    }

    IERC20 public immutable usdc;

    /// @notice Optional address that can pause and revoke, but never open lines or withdraw.
    address public guardian;

    /// @notice Sum of outstanding principal across all agents.
    uint256 public totalPrincipal;

    mapping(address agent => Line) public lines;
    mapping(address agent => History) public histories;
    /// @dev key = keccak256(agent, epoch, recipient)
    mapping(bytes32 key => bool) internal _recipientAllowed;
    /// @notice Peak outstanding debt in the agent's current cycle (reset when the cycle closes).
    mapping(address agent => uint128) public cyclePeak;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event GuardianSet(address indexed guardian);
    event LineOpened(
        address indexed agent,
        uint128 starterCap,
        uint128 stepSize,
        uint128 maxCap,
        uint64 term,
        uint64 grace,
        bool allowlistEnabled,
        uint32 epoch
    );
    event AgentRevoked(address indexed agent, address indexed by, uint32 newEpoch);
    event RecipientSet(address indexed agent, address indexed recipient, bool allowed);
    event Borrowed(address indexed agent, address indexed to, uint256 amount, uint256 debt, uint64 dueDate, bytes32 memo);
    event Repaid(address indexed agent, address indexed from, uint256 amount, uint256 remainingDebt);
    event Stepped(address indexed agent, uint128 newCap, uint32 newTier);
    event Defaulted(address indexed agent, uint256 debt, address indexed by);
    event DefaultCleared(address indexed agent, address indexed by, uint128 resetCap);

    error NotAgent();
    error LineDue();
    error LineFrozen();
    error RecipientNotAllowed();
    error ExceedsCredit(uint256 wouldDebt, uint256 cap);
    error InsufficientLiquidity();
    error InvalidLine();
    error InvalidTerm();
    error InvalidGrace();
    error ZeroAddress();
    error ZeroAmount();
    error NoDebt();
    error NotDue();
    error AlreadyFrozen();
    error NotFrozen();
    error DebtOutstanding();
    error CapBelowDebt();
    error NotOwnerOrGuardian();

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        _;
    }

    constructor(address initialOwner, address usdc_) Ownable(initialOwner) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
    }

    // ------------------------------------------------------------------ funding

    /// @notice Pull USDC into the vault (needs prior approve). Records the amount actually received.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, usdc.balanceOf(address(this)) - before);
    }

    /// @notice Backer withdraws unused USDC (vault balance). Works while paused so funds are never stuck.
    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    // ------------------------------------------------------------------ admin

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Open or update a stepped line. While debt is outstanding, new caps cannot sit below it
    ///         and a frozen line cannot be edited (clear the default first). A first-time or revoked
    ///         line with zero debt starts at `starterCap` (tier 0). An already-active zero-debt line
    ///         keeps its tier and recomputes `currentCap` from the new ladder.
    function openLine(
        address agent,
        uint128 starterCap,
        uint128 stepSize,
        uint128 maxCap,
        uint64 term,
        uint64 grace,
        bool allowlistEnabled
    ) external onlyOwner {
        if (agent == address(0)) revert ZeroAddress();
        if (starterCap == 0 || stepSize == 0 || maxCap < starterCap) revert InvalidLine();
        if (term < MIN_TERM || term > MAX_TERM) revert InvalidTerm();
        if (grace > MAX_GRACE) revert InvalidGrace();

        Line storage line = lines[agent];
        if (line.frozen) revert LineFrozen();
        if (line.principal > maxCap) revert CapBelowDebt();

        // Never-configured lines start at the starter cap. Revoked lines keep their tier.
        bool fresh = line.starterCap == 0;
        line.active = true;
        line.starterCap = starterCap;
        line.stepSize = stepSize;
        line.maxCap = maxCap;
        line.term = term;
        line.grace = grace;
        line.allowlistEnabled = allowlistEnabled;

        History storage hist = histories[agent];
        if (fresh) {
            hist.currentTier = 0;
            line.currentCap = starterCap;
            line.dueDate = 0;
            cyclePeak[agent] = 0;
        } else {
            line.currentCap = _capAt(starterCap, stepSize, maxCap, hist.currentTier);
            if (line.principal > line.currentCap) revert CapBelowDebt();
        }

        emit LineOpened(agent, starterCap, stepSize, maxCap, term, grace, allowlistEnabled, line.epoch);
    }

    function setRecipient(address agent, address recipient, bool allowed) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _recipientAllowed[_key(agent, lines[agent].epoch, recipient)] = allowed;
        emit RecipientSet(agent, recipient, allowed);
    }

    /// @notice Kill switch for one agent: deactivates the line and wipes its allowlist.
    ///         Outstanding debt, cap progress and the public history remain.
    function revokeAgent(address agent) external onlyOwnerOrGuardian {
        _revoke(agent);
    }

    /// @notice An agent can give up its own borrowing rights, e.g. if its key leaks. Debt remains.
    function renounceAgent() external {
        if (!lines[msg.sender].active) revert NotAgent();
        _revoke(msg.sender);
    }

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Anyone may mark a line defaulted after `dueDate + grace` if debt remains.
    ///         Freezes the line and records a public default. Blocks new borrows until the
    ///         backer clears the freeze after a full repayment.
    function markDefault(address agent) external {
        Line storage line = lines[agent];
        if (line.principal == 0) revert NoDebt();
        if (line.dueDate == 0) revert NotDue();
        if (block.timestamp <= uint256(line.dueDate) + line.grace) revert NotDue();
        if (line.frozen) revert AlreadyFrozen();
        line.frozen = true;
        History storage hist = histories[agent];
        unchecked {
            hist.defaultCount += 1;
        }
        hist.lastDefaultAt = uint64(block.timestamp);
        emit Defaulted(agent, line.principal, msg.sender);
    }

    /// @notice Backer may clear a freeze only after the line is fully repaid. Cap and tier
    ///         reset to the starter; lifetime on-time and default counts stay public.
    function clearDefault(address agent) external onlyOwner {
        Line storage line = lines[agent];
        if (!line.frozen) revert NotFrozen();
        if (line.principal != 0) revert DebtOutstanding();
        line.frozen = false;
        line.dueDate = 0;
        cyclePeak[agent] = 0;
        histories[agent].currentTier = 0;
        line.currentCap = line.starterCap;
        emit DefaultCleared(agent, msg.sender, line.currentCap);
    }

    // ------------------------------------------------------------------ borrow / repay

    /// @notice Agent borrows `amount` of USDC, sent to `to`. The first borrow of a cycle
    ///         starts the term clock (`dueDate = now + term`).
    function borrow(address to, uint256 amount, bytes32 memo) external whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        Line storage line = lines[msg.sender];
        if (!line.active) revert NotAgent();
        if (line.frozen) revert LineFrozen();
        if (line.dueDate != 0 && block.timestamp >= line.dueDate) revert LineDue();
        if (line.allowlistEnabled && !_recipientAllowed[_key(msg.sender, line.epoch, to)]) {
            revert RecipientNotAllowed();
        }

        uint256 newDebt = uint256(line.principal) + amount;
        if (newDebt > line.currentCap) revert ExceedsCredit(newDebt, line.currentCap);
        if (amount > usdc.balanceOf(address(this))) revert InsufficientLiquidity();
        if (amount > type(uint128).max - line.principal) revert ExceedsCredit(newDebt, line.currentCap);

        line.principal = uint128(newDebt);
        if (newDebt > cyclePeak[msg.sender]) cyclePeak[msg.sender] = uint128(newDebt);
        if (line.dueDate == 0) {
            line.dueDate = uint64(block.timestamp + line.term);
        }
        History storage hist = histories[msg.sender];
        hist.totalBorrowed = uint128(uint256(hist.totalBorrowed) + amount);
        totalPrincipal += amount;

        emit Borrowed(msg.sender, to, amount, newDebt, line.dueDate, memo);
        usdc.safeTransfer(to, amount);
    }

    /// @notice Anyone may repay an agent's debt. Overpayments are capped to the outstanding amount.
    ///         Allowed while paused, after revoke, and after a freeze. A full repayment at or
    ///         before `dueDate` steps the cap up (unless frozen) if the cycle's peak debt
    ///         reached MIN_USAGE_BPS of the cap and one `term` has passed since the last step. A full repayment after
    ///         `dueDate` is late: no step, no automatic default.
    function repay(address agent, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Line storage line = lines[agent];
        uint256 debt = line.principal;
        if (debt == 0) revert NoDebt();
        uint256 pay = amount > debt ? debt : amount;

        usdc.safeTransferFrom(msg.sender, address(this), pay);

        line.principal = uint128(debt - pay);
        totalPrincipal -= pay;
        History storage hist = histories[agent];
        hist.totalRepaid = uint128(uint256(hist.totalRepaid) + pay);

        emit Repaid(agent, msg.sender, pay, line.principal);

        if (line.principal == 0 && line.dueDate != 0) {
            if (!line.frozen && block.timestamp <= line.dueDate) {
                // Audit H-1: only a cycle that used a real share of the cap, at most once per
                // term, earns a step and an on-time count. Stops dust / same-block borrow-repay
                // loops from climbing the ladder to maxCap and inflating the public history.
                if (_qualifies(agent, line, hist)) _stepUp(agent, line, hist);
            } else if (!line.frozen) {
                unchecked {
                    hist.lateCount += 1;
                }
            }
            line.dueDate = 0;
            cyclePeak[agent] = 0;
        }
    }

    // ------------------------------------------------------------------ views

    function getLine(address agent) external view returns (Line memory) {
        return lines[agent];
    }

    function getHistory(address agent) external view returns (History memory) {
        return histories[agent];
    }

    /// @notice Public credit history other apps can read: on-time count, defaults, current tier and cap.
    function creditHistory(address agent) external view returns (CreditHistory memory h) {
        Line memory line = lines[agent];
        History memory hist = histories[agent];
        h.onTimeCount = hist.onTimeCount;
        h.defaultCount = hist.defaultCount;
        h.currentTier = hist.currentTier;
        h.currentCap = line.currentCap;
        h.starterCap = line.starterCap;
        h.maxCap = line.maxCap;
        h.frozen = line.frozen;
        h.active = line.active;
        h.lastDefaultAt = hist.lastDefaultAt;
    }

    function isRecipientAllowed(address agent, address recipient) external view returns (bool) {
        Line memory line = lines[agent];
        if (!line.allowlistEnabled) return recipient != address(0);
        return _recipientAllowed[_key(agent, line.epoch, recipient)];
    }

    function amountDue(address agent) public view returns (uint256) {
        return lines[agent].principal;
    }

    /// @notice Remaining credit, capped by vault liquidity, or 0 if the agent cannot borrow now.
    function availableCredit(address agent) public view returns (uint256) {
        Line memory line = lines[agent];
        if (!line.active || line.frozen || paused()) return 0;
        if (line.dueDate != 0 && block.timestamp >= line.dueDate) return 0;
        if (line.principal >= line.currentCap) return 0;
        uint256 room = uint256(line.currentCap) - line.principal;
        uint256 bal = usdc.balanceOf(address(this));
        return room < bal ? room : bal;
    }

    function liquidity() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ------------------------------------------------------------------ internal

    function _stepUp(address agent, Line storage line, History storage hist) internal {
        unchecked {
            hist.onTimeCount += 1;
            hist.currentTier += 1;
        }
        hist.lastOnTimeAt = uint64(block.timestamp);
        line.currentCap = _capAt(line.starterCap, line.stepSize, line.maxCap, hist.currentTier);
        emit Stepped(agent, line.currentCap, hist.currentTier);
    }

    /// @dev A cycle qualifies for a step if its peak debt reached MIN_USAGE_BPS of the cap and at
    ///      least one `term` has passed since the last step.
    function _qualifies(address agent, Line storage line, History storage hist) internal view returns (bool) {
        if (uint256(cyclePeak[agent]) * BPS_DENOMINATOR < uint256(line.currentCap) * MIN_USAGE_BPS) return false;
        if (hist.lastOnTimeAt != 0 && block.timestamp < uint256(hist.lastOnTimeAt) + line.term) return false;
        return true;
    }

    /// @dev currentCap = min(starter + tier * step, max). Never exceeds maxCap.
    function _capAt(uint128 starter, uint128 step, uint128 maxCap, uint32 tier) internal pure returns (uint128) {
        if (tier == 0) return starter <= maxCap ? starter : maxCap;
        if (step != 0 && uint256(tier) > type(uint256).max / step) return maxCap;
        uint256 stepped = uint256(starter) + uint256(tier) * uint256(step);
        if (stepped > maxCap) return maxCap;
        return uint128(stepped);
    }

    function _key(address agent, uint32 epoch, address x) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, epoch, x));
    }

    function _revoke(address agent) internal {
        Line storage line = lines[agent];
        line.active = false;
        unchecked {
            line.epoch += 1;
        }
        emit AgentRevoked(agent, msg.sender, line.epoch);
    }
}
