# GrantStreamVault Architecture

A secure token vesting contract with interval-based vesting, cliff periods, and protocol fees.

## Storage Layout

Grant struct: `total`, `claimed` (uint256), `start`, `duration`, `cliff` (uint64), `active` (bool). Single `contractBalance` (uint256) tracks unallocated pool. Stream interval configurable.

## Access Control

Owner-only functions via `onlyOwner` modifier. Single address controls grants, configuration, pause, and withdrawals.

**Balance Management**: `createGrant()` deducts from `contractBalance`. `claim()` transfers out. `updateGrant()` refunds old, deducts new. Prevents over-allocation.

**Interval-based Vesting**: Calculated on complete `streamInterval` periods only (default 30 days). Prevents partial claims.

**Pause Mechanism**: Blocks claims via `whenNotPaused` while preserving calculations.

**Single Grant**: One active grant per recipient prevents duplicates.

## Notes made during development

- the vesting period has been defaulted to 1 month, as it wasnt specified, however this can be changed by the owner via the `setStreamInterval` function
- we arent allowed any other dependancies, but decided to use OZ's NonReentrant guard for the sake of security. We could implement a custom one, but this is a vetted industry standard. We have implemented checks-effects-integration for token transfers etc
- `contractBalance` utilised to censure we have a running total of the amount in the contract which can be used to output grants in a vested manner whilst recording contract balance wrt existing vesting schemes (this covers updates and revocations of grants too). Just to note this method is a design decision, and could have been implemented in a number of different ways
- considered utilising `uint128` for token balances, since it would creater a tighter storage layout for the Grant structs, however didn't on the premise that `IERC20` typically uses `uint256` and didn't want to risk collisions or type errors within a small development timeframe: I would take slightly more time to read into and ascertain the most effective decision here, however in a risk matrix, if we had to, I would say that the cost of an extra slot per grant is less than the cost of a break in functionality
- added events per function call to be succinct - for the sake of actually tracking events on a frontend etc, these would be more tightly tailored, however provide for testing each function in an easy manner here

## UUPS upgrade notes

- consider addingstorage gaps prevent storage collisions
- would need to replace constructor with initializer function from open zeppelin `Initializable` if UUPS is used
- be careful to make sure all new versions **append** storage variables only, **never** reorder existing ones, since this will overwrite existing slots
- create a `dry-run` script to test the upgrade process

## Notes for owner

- be careful which ERC20 token is used during deployment, as bad tokens couold be built with hooks that could cause issues with the contract
- the Owner is the single point of trust in this contract, which may be odd or too dependant on a single entity in production. For the sake of rapid development, this contract has been left this way, but timelocks and/or multisig could be considered for production

## Testing

To run the entire test suite

```bash
forge test -vv
```

To run the fuzz tests

```bash
forge test --match-test "testFuzz" -vv
```

To run the invariants

```bash
forge test --match-test "testInvariant" -vv
```
