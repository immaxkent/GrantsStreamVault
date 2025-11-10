// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../lib/forge-std/src/interfaces/IERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract GrantStreamVault is ReentrancyGuard {
    struct Grant {
        uint256 total;
        uint256 claimed;
        uint64 start;
        uint64 duration;
        uint64 cliff;
        bool active;
    }

    IERC20 public token;
    address public owner;
    address public feeRecipient;
    uint256 public protocolFeeBps;
    uint256 public streamInterval; // time delta for vesting intervals (in seconds) (1 month == 2592000 seconds)
    uint256 public contractBalance; // token balance deposited at initilisation as per the spec - used for vesting allocations - typically, we would support further additions of funds for vesting

    bool public paused;
    bool private initialized;

    mapping(address => Grant) public grants;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant MAX_PROTOCOL_FEE_BPS = 500; // 5%
    uint256 private constant DEFAULT_STREAM_INTERVAL = 30 days;
    uint256 private constant MIN_REASONABLE_DURATION = 1 hours; // Minimum reasonable vesting duration
    uint256 private constant MAX_REASONABLE_DURATION = 10 * 365 days; // 10 years max

    event GrantCreated(address indexed recipient, uint256 total, uint64 start, uint64 duration, uint64 cliff);

    event GrantUpdated(address indexed recipient, uint256 total, uint64 start, uint64 duration, uint64 cliff);

    event Claimed(address indexed recipient, uint256 amount, uint256 fee);

    event GrantRevoked(address indexed recipient, uint256 vestedAmount, uint256 revokedAmount);

    event PauseToggled(bool isPaused);

    event StreamIntervalUpdated(uint256 newInterval);

    event Withdrawn(address indexed to, uint256 amount);

    error AlreadyInitialized();
    error NotInitialized();
    error NotOwner();
    error InvalidToken();
    error InvalidFeeRecipient();
    error InvalidOwner();
    error ProtocolFeeTooHigh();
    error ZeroAddress();
    error ZeroDuration();
    error ZeroAmount();
    error InvalidInterval();
    error InvalidCliff();
    error DurationTooShort();
    error DurationTooLong();
    error StartTimeInvalid();
    error NoGrantExists();
    error GrantAlreadyExists();
    error GrantNotActive();
    error InsufficientContractBalance();
    error ContractPaused();
    error NothingToClaim();
    error TransferFailed();

    // implemented onlyOwner as inheritance was restricted in brief - would typically utilise openZeppelin's onlyOwner which is initialised in constructor
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    constructor(
        IERC20 _token,
        uint256 _amount,
        uint256 _protocolFeeBps, // fee in basis points
        address _feeRecipient,
        address _owner
    ) {
        if (address(_token) == address(0)) revert InvalidToken();
        if (_feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (_owner == address(0)) revert InvalidOwner();
        if (_protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeTooHigh();

        token = _token;
        protocolFeeBps = _protocolFeeBps;
        feeRecipient = _feeRecipient;
        owner = _owner;
        streamInterval = DEFAULT_STREAM_INTERVAL;
        
        if (!token.transferFrom(msg.sender, address(this), _amount)) {
            revert TransferFailed();
        }
        
        contractBalance = _amount;
        initialized = true;
    }

    function createGrant(address recipient, uint256 total, uint64 start, uint64 duration, uint64 cliff)
        external
        onlyOwner
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (total == 0) revert ZeroAmount();
        if (duration == 0) revert ZeroDuration();
        
        // Time validations for reasonable values (mitigates timestamp manipulation impact)
        if (duration < MIN_REASONABLE_DURATION) revert DurationTooShort();
        if (duration > MAX_REASONABLE_DURATION) revert DurationTooLong();
        if (cliff > duration) revert InvalidCliff();
        
        // Start time should be reasonable (not too far in past, accounting for 15s block drift)
        // Allow zero (means now) or any time within 15s of current block
        if (start != 0 && block.timestamp > 15 && start < block.timestamp - 15) revert StartTimeInvalid();

        Grant storage g = grants[recipient];
        if (g.active) revert GrantAlreadyExists();

        // allocate from **internal** contract balance
        if (contractBalance < total) revert InsufficientContractBalance();
        contractBalance -= total;

        g.total = total;
        g.claimed = 0;
        g.start = start;
        g.duration = duration;
        g.cliff = cliff;
        g.active = true;

        emit GrantCreated(recipient, total, start, duration, cliff);
    }

    function updateGrant(address recipient, uint256 total, uint64 start, uint64 duration, uint64 cliff)
        external
        onlyOwner
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (total == 0) revert ZeroAmount();
        if (duration == 0) revert ZeroDuration();
        
        // Time validations for reasonable values
        if (duration < MIN_REASONABLE_DURATION) revert DurationTooShort();
        if (duration > MAX_REASONABLE_DURATION) revert DurationTooLong();
        if (cliff > duration) revert InvalidCliff();
        if (start != 0 && block.timestamp > 15 && start < block.timestamp - 15) revert StartTimeInvalid();

        Grant storage g = grants[recipient];
        if (!g.active) revert NoGrantExists();

        // refund unvested allocation back to **internal contract balance**
        uint256 unvested = g.total - g.claimed;
        contractBalance += unvested;

        // allocate
        if (contractBalance < total) revert InsufficientContractBalance();
        contractBalance -= total;

        g.total = total;
        g.claimed = 0; // resets claimed amount on update -- may be worth adding new field for representation of grant version, down to design
        g.start = start;
        g.duration = duration;
        g.cliff = cliff;

        emit GrantUpdated(recipient, total, start, duration, cliff);
    }

    function vestedAmount(address recipient) public view returns (uint256) {
        Grant storage g = grants[recipient];
        if (!g.active) return 0;

        // checks for start time / cliff / after full vesting
        if (block.timestamp < g.start) return 0;
        if (block.timestamp < g.start + g.cliff) return 0;
        if (block.timestamp >= g.start + g.duration) {
            return g.total;
        }

        // only whole intervals count
        uint256 elapsed = block.timestamp - g.start;
        uint256 intervalsCompleted = elapsed / streamInterval;
        uint256 totalIntervals = uint256(g.duration) / streamInterval;

        // If duration < streamInterval, totalIntervals = 0
        // In this case, vesting should still work proportionally
        if (totalIntervals == 0) {
            // Fallback to linear vesting if duration is shorter than interval
            return (g.total * elapsed) / uint256(g.duration);
        }

        return (g.total * intervalsCompleted) / totalIntervals;
    }

    function claimableAmount(address recipient) public view returns (uint256, uint256) {
        uint256 vested = vestedAmount(recipient);
        Grant storage g = grants[recipient];

        if (vested <= g.claimed) return (0, 0);

        uint256 claimable = vested - g.claimed;
        uint256 fee = (claimable * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 net = claimable - fee;

        return (net, fee);
    }

    function claim() external whenNotPaused nonReentrant {
        Grant storage g = grants[msg.sender];
        if (!g.active) revert NoGrantExists();

        (uint256 netAmount, uint256 feeAmount) = claimableAmount(msg.sender);
        if (netAmount == 0 && feeAmount == 0) revert NothingToClaim();

        // CEI: storage allocations first
        g.claimed += netAmount + feeAmount;

        if (feeAmount > 0) {
            if (!token.transfer(feeRecipient, feeAmount)) revert TransferFailed();
        }

        if (netAmount > 0) {
            if (!token.transfer(msg.sender, netAmount)) revert TransferFailed();
        }

        // CEI: interactions / trasnfers last
        emit Claimed(msg.sender, netAmount, feeAmount);
    }

    function revokeGrant(address recipient) external onlyOwner nonReentrant {
        Grant storage g = grants[recipient];
        if (!g.active) revert NoGrantExists();

        uint256 vested = vestedAmount(recipient);
        uint256 unvested = g.total - vested;

        // 'refund' unvested amount to contract balance
        contractBalance += unvested;

        // Set total to vested amount and lock vesting at current point
        g.total = vested;
        
        // Always set duration to elapsed time so vestedAmount() returns correct total
        if (block.timestamp > g.start) {
            g.duration = uint64(block.timestamp - g.start);
        } else {
            g.duration = 0;
        }
        
        // Clear cliff since vesting is now complete/locked
        g.cliff = 0;

        // Deactivate grant if nothing left to claim (claimed equals or exceeds vested)
        // This prevents further claims and clears storage
        if (g.claimed >= vested) {
            g.active = false;
        }
        // If vested > claimed, keep active so recipient can claim remaining vested amount

        emit GrantRevoked(recipient, vested, unvested);
    }

    function pauseToggle(bool isPaused) external onlyOwner {
        paused = isPaused;
        emit PauseToggled(isPaused);
    }

    function setStreamInterval(uint256 newInterval) external onlyOwner {
        if (newInterval == 0) revert InvalidInterval();
        streamInterval = newInterval;
        emit StreamIntervalUpdated(newInterval);
    }

    // @notice Withdraw unallocated tokens from contract
    function withdraw(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (amount > contractBalance) revert InsufficientContractBalance();

        contractBalance -= amount;

        if (!token.transfer(owner, amount)) revert TransferFailed();

        emit Withdrawn(owner, amount);
    }
}
