# GrantStreamVault

A secure token vesting contract with interval-based vesting, cliff periods, and protocol fees.

## Overview

GrantStreamVault enables administrators to create token grants with:

- **Interval-based vesting** over configurable durations (default 30-day intervals)
- Optional cliff periods
- Protocol fees (max 5%) on each claim
- Pause/unpause functionality
- Grant revocation with unvested fund recovery
- One-time initialization with token pool allocation

## Features

✅ **Secure Implementation**

- Check-effects-interactions pattern
- Custom errors for gas efficiency
- Modifier-based access control
- Explicit balance tracking with `contractBalance`

✅ **Complete Functionality**

- Initialize contract with token pool (one-time)
- Create/update grants with configurable parameters
- Claim vested tokens with automatic fee deduction (interval-based)
- Revoke grants while preserving vested amounts
- Emergency pause mechanism
- Withdraw unallocated funds

✅ **Comprehensive Testing**

- 44 passing tests covering all scenarios
- Happy path and negative cases
- Edge case handling (zero values, timing, etc.)
- Revocation and multi-recipient tests

## Installation & Testing

### Run Tests

```bash
forge test
```

### Run Tests with Gas Report

```bash
forge test --gas-report
```

### Run Specific Test

```bash
forge test --match-test test_Claim_Success -vvv
```

## Core Contract Functions

### Initialization

- `initialize(amount)` - Owner transfers tokens into contract once (required before creating grants)

### Admin Functions (Owner Only)

- `createGrant(recipient, total, start, duration, cliff)` - Create a new vesting grant
- `updateGrant(recipient, total, start, duration, cliff)` - Update existing grant (refunds old, allocates new)
- `revokeGrant(recipient)` - Cancel a grant and recover unvested funds
- `setStreamInterval(newInterval)` - Configure vesting interval (default: 30 days)
- `pause()` - Stop all claims
- `unpause()` - Resume claims
- `withdraw(amount)` - Withdraw unallocated tokens from contract balance

### User Functions

- `claim()` - Claim vested tokens (automatically deducts protocol fee)
- `vestedAmount(recipient)` - View vested amount for an address
- `claimableAmount(recipient)` - View claimable amount (after fees)

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for detailed design documentation.

## Contract Details

- **Solidity Version**: ^0.8.20
- **Dependencies**: IERC20 interface (via forge-std)
- **Gas Optimized**: Custom errors, efficient storage
- **Vesting Model**: Interval-based (only complete intervals count)
- **Default Interval**: 30 days (2,592,000 seconds)

## Interval-Based Vesting Explained

Unlike continuous linear vesting, this contract uses **discrete intervals**:

```
Grant: 1200 tokens, 360 days duration, 30-day intervals
Total intervals: 360 / 30 = 12 intervals

Day 29:  0 complete intervals → 0 tokens vested
Day 30:  1 complete interval  → 100 tokens vested (1/12)
Day 60:  2 complete intervals → 200 tokens vested (2/12)
Day 180: 6 complete intervals → 600 tokens vested (6/12)
Day 360: 12 complete intervals → 1200 tokens vested (12/12)
```

This ensures predictable, scheduled distributions rather than per-second accrual.

## Test Coverage

| Category             | Tests | Status      |
| -------------------- | ----- | ----------- |
| Constructor          | 5     | ✅ All Pass |
| Initialization       | 4     | ✅ All Pass |
| Create Grant         | 8     | ✅ All Pass |
| Update Grant         | 3     | ✅ All Pass |
| Vesting Calculations | 3     | ✅ All Pass |
| Claims               | 5     | ✅ All Pass |
| Revocation           | 2     | ✅ All Pass |
| Pause/Unpause        | 2     | ✅ All Pass |
| Stream Interval      | 4     | ✅ All Pass |
| Withdraw             | 5     | ✅ All Pass |
| Integration          | 3     | ✅ All Pass |

**Total: 44 tests, 100% passing**

## Security Considerations

- ✅ One-time initialization prevents double-funding
- ✅ Balance tracking prevents over-allocation
- ✅ Check-effects-interactions pattern
- ✅ Input validation on all parameters
- ✅ Access control via modifiers
- ✅ Safe math (Solidity 0.8+ overflow protection)
- ✅ Pause mechanism for emergency stops
- ✅ Single active grant per recipient

## Example Usage

```solidity
// Deploy contract
GrantStreamVault vault = new GrantStreamVault(
    IERC20(tokenAddress),
    250,              // 2.5% protocol fee
    feeRecipient,
    owner
);

// Initialize with 10,000 tokens (one-time only)
// Owner must approve vault first
token.approve(address(vault), 10000 ether);
vault.initialize(10000 ether);

// Create a 1-year vesting grant with 3-month cliff
vault.createGrant(
    recipient,
    1000 ether,       // Total amount
    block.timestamp,  // Start now
    365 days,         // 1 year vesting
    90 days           // 3 month cliff
);

// Default: vesting in 30-day intervals
// After 120 days: 4 intervals passed = 4/12 = 33.33% vested

// Recipient claims after 120 days (4 intervals)
vault.claim(); // Receives ~333 ether minus protocol fee

// Change to weekly intervals
vault.setStreamInterval(7 days);
```

## Key Differences from Original Spec

1. **Interval-based vesting**: Uses discrete intervals instead of continuous linear vesting
2. **Initialize pattern**: One-time funding via `initialize()` instead of transfers during grant creation
3. **Balance tracking**: Explicit `contractBalance` prevents over-allocation
4. **Split functions**: Separate `createGrant()` and `updateGrant()` instead of combined function
5. **uint256 amounts**: Standard token amounts (not uint128)
6. **No reentrancy guard**: Standard ERC20 doesn't require it

## License

MIT
