// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {GrantStreamVault} from "../src/GrantStreamVault.sol";
import {IERC20} from "../lib/forge-std/src/interfaces/IERC20.sol";

contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract GrantStreamVaultTest is Test {
    GrantStreamVault public vault;
    MockERC20 public token;

    address public owner = address(1);
    address public feeRecipient = address(2);
    address public recipient1 = address(3);
    address public recipient2 = address(4);
    address public notOwner = address(5);

    uint256 public constant PROTOCOL_FEE_BPS = 250; // 2.5%
    uint256 public constant INITIAL_BALANCE = 10000 ether;
    uint256 public constant GRANT_AMOUNT = 1000 ether;
    uint256 public constant STREAM_INTERVAL = 30 days;
    uint64 public constant DURATION = 365 days;
    uint64 public constant CLIFF = 90 days;

    event GrantCreated(address indexed recipient, uint256 total, uint64 start, uint64 duration, uint64 cliff);
    event GrantUpdated(address indexed recipient, uint256 total, uint64 start, uint64 duration, uint64 cliff);
    event Claimed(address indexed recipient, uint256 amount, uint256 fee);
    event GrantRevoked(address indexed recipient, uint256 vestedAmount, uint256 revokedAmount);
    event PauseToggled(bool isPaused);
    event StreamIntervalUpdated(uint256 newInterval);
    event Withdrawn(address indexed to, uint256 amount);

    function setUp() public {
        token = new MockERC20();
        token.mint(owner, INITIAL_BALANCE * 2); // mint extra to cover excess in expanding test suite

        address predictedVault = vm.computeCreateAddress(owner, vm.getNonce(owner));

        vm.prank(owner);
        token.approve(predictedVault, type(uint256).max);

        vm.prank(owner);
        vault = new GrantStreamVault(IERC20(address(token)), INITIAL_BALANCE, PROTOCOL_FEE_BPS, feeRecipient, owner);

        // verify balance has funds
        assertEq(vault.contractBalance(), INITIAL_BALANCE);
    }

    function test_Constructor_Success() public view {
        assertEq(address(vault.token()), address(token)); //token successfully initialised
        assertEq(vault.owner(), owner);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.protocolFeeBps(), PROTOCOL_FEE_BPS);
        assertEq(vault.streamInterval(), 30 days);
        assertFalse(vault.paused());
    }

    function test_Constructor_RevertsOnZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidToken.selector);
        new GrantStreamVault(IERC20(address(0)), INITIAL_BALANCE, PROTOCOL_FEE_BPS, feeRecipient, owner);
    }

    function test_Constructor_RevertsOnZeroFeeRecipient() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidFeeRecipient.selector);
        new GrantStreamVault(IERC20(address(token)), INITIAL_BALANCE, PROTOCOL_FEE_BPS, address(0), owner);
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidOwner.selector);
        new GrantStreamVault(IERC20(address(token)), INITIAL_BALANCE, PROTOCOL_FEE_BPS, feeRecipient, address(0));
    }

    function test_Constructor_RevertsOnExcessiveFee() public {
        address predictedVault = vm.computeCreateAddress(owner, vm.getNonce(owner));

        vm.prank(owner);
        token.approve(predictedVault, type(uint256).max);

        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.ProtocolFeeTooHigh.selector);
        new GrantStreamVault(IERC20(address(token)), INITIAL_BALANCE, 501, feeRecipient, owner); // 5.01% > 5% max
    }

    // =============================================================
    //                    CREATE GRANT TESTS
    // =============================================================

    function test_CreateGrant_Success() public {
        uint64 start = uint64(block.timestamp);

        vm.expectEmit(true, true, true, true);
        emit GrantCreated(recipient1, GRANT_AMOUNT, start, DURATION, CLIFF);

        vm.prank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, CLIFF);

        (uint256 total, uint256 claimed, uint64 gStart, uint64 duration, uint64 cliff, bool active) =
            vault.grants(recipient1);
        assertEq(total, GRANT_AMOUNT);
        assertEq(claimed, 0);
        assertEq(gStart, start);
        assertEq(duration, DURATION);
        assertEq(cliff, CLIFF);
        assertTrue(active);
        assertEq(vault.contractBalance(), INITIAL_BALANCE - GRANT_AMOUNT);
    }

    function test_CreateGrant_RevertsOnNonOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(GrantStreamVault.NotOwner.selector);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), DURATION, CLIFF);
    }

    function test_CreateGrant_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.ZeroAddress.selector);
        vault.createGrant(address(0), GRANT_AMOUNT, uint64(block.timestamp), DURATION, CLIFF);
    }

    function test_CreateGrant_RevertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.ZeroAmount.selector);
        vault.createGrant(recipient1, 0, uint64(block.timestamp), DURATION, CLIFF);
    }

    function test_CreateGrant_RevertsOnZeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.ZeroDuration.selector);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), 0, CLIFF);
    }

    function test_CreateGrant_RevertsOnDuplicateGrant() public {
        vm.startPrank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), DURATION, 0);

        vm.expectRevert(GrantStreamVault.GrantAlreadyExists.selector);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), DURATION, 0);
        vm.stopPrank();
    }

    function test_CreateGrant_RevertsOnInsufficientBalance() public {
        // Vault has INITIAL_BALANCE, try to create grant for more
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InsufficientContractBalance.selector);
        vault.createGrant(recipient1, INITIAL_BALANCE + 1 ether, uint64(block.timestamp), DURATION, 0);
    }

    function test_CreateGrant_RevertsOnCliffGreaterThanDuration() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidCliff.selector);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), 365 days, 366 days);
    }

    function test_CreateGrant_RevertsOnDurationTooShort() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.DurationTooShort.selector);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), 30 minutes, 0);
    }

    function test_CreateGrant_RevertsOnDurationTooLong() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.DurationTooLong.selector);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), uint64(11 * 365 days), 0);
    }

    // =============================================================
    //                    UPDATE GRANT TESTS
    // =============================================================

    function test_UpdateGrant_Success() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, CLIFF);

        uint256 balanceAfterCreate = vault.contractBalance();

        // Update grant
        uint256 newAmount = GRANT_AMOUNT * 2;
        uint64 newDuration = DURATION * 2;

        vm.expectEmit(true, true, true, true);
        emit GrantUpdated(recipient1, newAmount, start, newDuration, CLIFF);

        vault.updateGrant(recipient1, newAmount, start, newDuration, CLIFF);
        vm.stopPrank();

        (uint256 total, uint256 claimed,, uint64 duration,, bool active) = vault.grants(recipient1);
        assertEq(total, newAmount);
        assertEq(claimed, 0); // Claimed resets on update
        assertEq(duration, newDuration);
        assertTrue(active);

        // Contract balance should have: old balance + old grant - new grant
        assertEq(vault.contractBalance(), balanceAfterCreate + GRANT_AMOUNT - newAmount);
    }

    function test_UpdateGrant_RevertsOnNoGrant() public {
        vm.startPrank(owner);

        vm.expectRevert(GrantStreamVault.NoGrantExists.selector);
        vault.updateGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), DURATION, CLIFF);
        vm.stopPrank();
    }

    function test_UpdateGrant_RevertsOnInsufficientBalance() public {
        vm.startPrank(owner);
        // Create first grant using most of balance
        vault.createGrant(recipient1, INITIAL_BALANCE - 100 ether, uint64(block.timestamp), DURATION, 0);
        // Balance left: 100 ether

        // Try to update to amount larger than available (100 + refunded = INITIAL_BALANCE, but we need more)
        vm.expectRevert(GrantStreamVault.InsufficientContractBalance.selector);
        vault.updateGrant(recipient1, INITIAL_BALANCE + 1 ether, uint64(block.timestamp), DURATION, 0);
        vm.stopPrank();
    }

    // =============================================================
    //                    INTERVAL VESTING TESTS
    // =============================================================
    // we are going to cover 1. interval based vesting 2. before cliff 3. after cliff

    function test_VestedAmount_IntervalBased() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);
        vm.stopPrank();

        // 0 intervals: 0%
        assertEq(vault.vestedAmount(recipient1), 0);

        // Advance by 0.9 intervals (still 0 complete intervals)
        vm.warp(block.timestamp + (STREAM_INTERVAL * 9) / 10);
        assertEq(vault.vestedAmount(recipient1), 0);

        // Advance to exactly 1 interval
        vm.warp(start + STREAM_INTERVAL);
        uint256 expectedVested = GRANT_AMOUNT / 12; // 365 days / 30 days = ~12 intervals
        assertEq(vault.vestedAmount(recipient1), expectedVested);

        // Advance to 6 intervals (half year)
        vm.warp(start + STREAM_INTERVAL * 6);
        expectedVested = (GRANT_AMOUNT * 6) / 12;
        assertEq(vault.vestedAmount(recipient1), expectedVested);

        // Advance past full duration
        vm.warp(start + DURATION);
        assertEq(vault.vestedAmount(recipient1), GRANT_AMOUNT);
    }

    function test_VestedAmount_BeforeCliff() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, CLIFF);
        vm.stopPrank();

        vm.warp(start + CLIFF - 1);
        assertEq(vault.vestedAmount(recipient1), 0);
    }

    function test_VestedAmount_AfterCliff() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, CLIFF);
        vm.stopPrank();

        // advance to 4 intervals, making it past 90 day cliff
        vm.warp(start + STREAM_INTERVAL * 4);

        uint256 expectedVested = (GRANT_AMOUNT * 4) / 12;
        assertEq(vault.vestedAmount(recipient1), expectedVested);
    }

    // =============================================================
    //                    CLAIM TESTS
    // =============================================================
    // we are going to cover 1. success 2. partial then full 3. paused 4. before first interval 5. before cliff 6. with no grant 7. revoke grant mid stream 8. recipient can claim vested

    function test_Claim_Success() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);
        vm.stopPrank();

        vm.warp(start + STREAM_INTERVAL * 6);

        uint256 expectedVested = (GRANT_AMOUNT * 6) / 12; // 500 ether
        uint256 expectedFee = (expectedVested * PROTOCOL_FEE_BPS) / 10_000;
        uint256 expectedNet = expectedVested - expectedFee;

        vm.expectEmit(true, true, true, true);
        emit Claimed(recipient1, expectedNet, expectedFee);

        vm.prank(recipient1);
        vault.claim();

        assertEq(token.balanceOf(recipient1), expectedNet);
        assertEq(token.balanceOf(feeRecipient), expectedFee);

        (, uint256 claimed,,,,) = vault.grants(recipient1); //deconstruct here
        assertEq(claimed, expectedVested);
    }

    function test_Claim_PartialThenFull() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);
        vm.stopPrank();

        vm.warp(start + STREAM_INTERVAL * 3);
        vm.prank(recipient1);
        vault.claim();

        uint256 balance1 = token.balanceOf(recipient1);
        assertTrue(balance1 > 0);

        vm.warp(start + STREAM_INTERVAL * 6);
        vm.prank(recipient1);
        vault.claim();

        uint256 balance2 = token.balanceOf(recipient1);
        assertGt(balance2, balance1);

        // final claim > duration
        vm.warp(start + DURATION);
        vm.prank(recipient1);
        vault.claim();

        uint256 finalBalance = token.balanceOf(recipient1);
        assertGt(finalBalance, balance2);
    }

    function test_Claim_RevertsWhenPaused() public {
        vm.startPrank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), DURATION, 0);
        vault.pauseToggle(true);
        vm.stopPrank();

        vm.warp(block.timestamp + STREAM_INTERVAL * 6);

        vm.prank(recipient1);
        vm.expectRevert(GrantStreamVault.ContractPaused.selector);
        vault.claim();
    }

    function test_Claim_RevertsBeforeFirstInterval() public {
        vm.startPrank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), DURATION, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + STREAM_INTERVAL / 2);

        vm.prank(recipient1);
        vm.expectRevert(GrantStreamVault.NothingToClaim.selector);
        vault.claim();
    }

    function test_Claim_RevertsBeforeCliff() public {
        uint64 start = uint64(block.timestamp);

        vm.startPrank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, CLIFF);
        vm.stopPrank();

        vm.warp(start + 30 days);

        assertEq(vault.vestedAmount(recipient1), 0);

        // attempt to claim should revert
        vm.prank(recipient1);
        vm.expectRevert(GrantStreamVault.NothingToClaim.selector);
        vault.claim();
    }

    function test_Claim_RevertsWithNoGrant() public {
        vm.prank(recipient1);
        vm.expectRevert(GrantStreamVault.NoGrantExists.selector);
        vault.claim();
    }

    function test_RevokeGrant_MidStream() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);

        uint256 balanceAfterCreate = vault.contractBalance();
        vm.stopPrank();

        vm.warp(start + STREAM_INTERVAL * 6);

        uint256 vestedAmount = vault.vestedAmount(recipient1);
        uint256 unvestedAmount = GRANT_AMOUNT - vestedAmount;

        vm.expectEmit(true, true, true, true);
        emit GrantRevoked(recipient1, vestedAmount, unvestedAmount);

        vm.prank(owner);
        vault.revokeGrant(recipient1);

        assertEq(vault.contractBalance(), balanceAfterCreate + unvestedAmount);

        (uint256 total,,,,, bool active) = vault.grants(recipient1);
        assertEq(total, vestedAmount);
        assertTrue(active); // still active because there's vested amount to claim
    }

    function test_RevokeGrant_RecipientCanClaimVested() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);
        vm.stopPrank();

        vm.warp(start + STREAM_INTERVAL * 6);

        uint256 vestedAmount = vault.vestedAmount(recipient1);

        vm.prank(owner);
        vault.revokeGrant(recipient1);

        vm.prank(recipient1);
        vault.claim();

        uint256 expectedFee = (vestedAmount * PROTOCOL_FEE_BPS) / 10_000;
        uint256 expectedNet = vestedAmount - expectedFee;

        assertEq(token.balanceOf(recipient1), expectedNet);
    }

    // =============================================================
    //                    PAUSE/UNPAUSE TESTS
    // =============================================================

    function test_Pause_Success() public {
        vm.expectEmit(true, true, true, true);
        emit PauseToggled(true);

        vm.prank(owner);
        vault.pauseToggle(true);

        assertTrue(vault.paused());
    }

    function test_Unpause_Success() public {
        vm.prank(owner);
        vault.pauseToggle(true);

        vm.expectEmit(true, true, true, true);
        emit PauseToggled(false);

        vm.prank(owner);
        vault.pauseToggle(false);

        assertFalse(vault.paused());
    }

    // =============================================================
    //                    STREAM INTERVAL TESTS
    // =============================================================

    function test_SetStreamInterval_Success() public {
        uint256 newInterval = 7 days;

        vm.expectEmit(true, true, true, true);
        emit StreamIntervalUpdated(newInterval);

        vm.prank(owner);
        vault.setStreamInterval(newInterval);

        assertEq(vault.streamInterval(), newInterval);
    }

    function test_SetStreamInterval_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InvalidInterval.selector);
        vault.setStreamInterval(0);
    }

    function test_SetStreamInterval_RevertsOnNonOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(GrantStreamVault.NotOwner.selector);
        vault.setStreamInterval(7 days);
    }

    function test_SetStreamInterval_AffectsVesting() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, 365 days, 0);

        vault.setStreamInterval(1 days);
        vm.stopPrank();

        vm.warp(start + 30 days);

        uint256 expectedVested = (GRANT_AMOUNT * 30) / 365;
        assertEq(vault.vestedAmount(recipient1), expectedVested);
    }

    // =============================================================
    //                    WITHDRAW TESTS
    // =============================================================
    // here we are going to cover 1. success 2. zero amount 3. insufficient balance 4. non owner 5. excess wwithdrawal

    function test_Withdraw_Success() public {
        uint256 withdrawAmount = 1000 ether;
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        vm.expectEmit(true, true, true, true);
        emit Withdrawn(owner, withdrawAmount);

        vm.prank(owner);
        vault.withdraw(withdrawAmount);

        assertEq(vault.contractBalance(), INITIAL_BALANCE - withdrawAmount);
        assertEq(token.balanceOf(owner) - ownerBalanceBefore, withdrawAmount);
    }

    function test_Withdraw_RevertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    function test_Withdraw_RevertsOnInsufficientBalance() public {
        vm.prank(owner);
        vm.expectRevert(GrantStreamVault.InsufficientContractBalance.selector);
        vault.withdraw(INITIAL_BALANCE + 1);
    }

    function test_Withdraw_RevertsOnNonOwner() public {
        vm.prank(notOwner);
        vm.expectRevert(GrantStreamVault.NotOwner.selector);
        vault.withdraw(1000 ether);
    }

    function test_Withdraw_CannotWithdrawAllocatedFunds() public {
        vm.startPrank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), DURATION, 0);

        uint256 unallocated = vault.contractBalance();
        assertEq(unallocated, INITIAL_BALANCE - GRANT_AMOUNT);

        vault.withdraw(unallocated);

        // trying to withdraw more should fail
        vm.expectRevert(GrantStreamVault.InsufficientContractBalance.selector);
        vault.withdraw(1);
        vm.stopPrank();
    }

    // =============================================================
    //                    INTEGRATION TESTS
    // =============================================================

    function test_FullLifecycle() public {
        // Create grant
        uint64 start = uint64(block.timestamp);
        vm.prank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);

        // Claim at 25% (3 intervals)
        vm.warp(start + STREAM_INTERVAL * 3);
        vm.prank(recipient1);
        vault.claim();

        uint256 balance1 = token.balanceOf(recipient1);
        assertTrue(balance1 > 0);

        // Claim at 50% (6 intervals)
        vm.warp(start + STREAM_INTERVAL * 6);
        vm.prank(recipient1);
        vault.claim();

        uint256 balance2 = token.balanceOf(recipient1);
        assertGt(balance2, balance1);

        // Claim at 100%
        vm.warp(start + DURATION);
        vm.prank(recipient1);
        vault.claim();

        // Verify all tokens claimed (minus fees)
        uint256 totalFee = (GRANT_AMOUNT * PROTOCOL_FEE_BPS) / 10_000;
        assertEq(token.balanceOf(recipient1), GRANT_AMOUNT - totalFee);
        assertEq(token.balanceOf(feeRecipient), totalFee);
    }

    function test_MultipleGrants() public {
        vm.startPrank(owner);

        uint64 start = uint64(block.timestamp);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);
        vault.createGrant(recipient2, GRANT_AMOUNT * 2, start, DURATION * 2, 0);
        vm.stopPrank();

        assertEq(vault.contractBalance(), INITIAL_BALANCE - GRANT_AMOUNT - (GRANT_AMOUNT * 2));

        // Both can claim independently
        vm.warp(start + STREAM_INTERVAL * 6);

        vm.prank(recipient1);
        vault.claim();

        vm.prank(recipient2);
        vault.claim();

        assertTrue(token.balanceOf(recipient1) > 0);
        assertTrue(token.balanceOf(recipient2) > 0);
    }

    function test_ZeroFeeConfiguration() public {
        // Predict vault address and approve
        address predictedZeroFeeVault = vm.computeCreateAddress(owner, vm.getNonce(owner));

        vm.prank(owner);
        token.approve(predictedZeroFeeVault, type(uint256).max);

        // Create vault with 0% fee
        vm.prank(owner);
        GrantStreamVault zeroFeeVault = new GrantStreamVault(
            IERC20(address(token)),
            INITIAL_BALANCE,
            0, // 0% fee
            feeRecipient,
            owner
        );

        uint64 start = uint64(block.timestamp);
        vm.prank(owner);
        zeroFeeVault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);

        vm.warp(start + DURATION);

        uint256 recipientBalanceBefore = token.balanceOf(recipient1);
        uint256 feeBalanceBefore = token.balanceOf(feeRecipient);

        vm.prank(recipient1);
        zeroFeeVault.claim();

        // Recipient gets full amount, no fee
        assertEq(token.balanceOf(recipient1) - recipientBalanceBefore, GRANT_AMOUNT);
        assertEq(token.balanceOf(feeRecipient), feeBalanceBefore);
    }

    // =============================================================
    //                    FUZZ TESTS
    // =============================================================

    function testFuzz_CreateGrant_ValidInputs(uint256 grantAmount, uint64 duration, uint64 cliff) public {
        // Bound inputs to reasonable ranges
        grantAmount = bound(grantAmount, 1 ether, INITIAL_BALANCE);
        duration = uint64(bound(duration, 1 hours, 10 * 365 days));
        cliff = uint64(bound(cliff, 0, duration));

        uint64 start = uint64(block.timestamp);

        vm.prank(owner);
        vault.createGrant(recipient1, grantAmount, start, duration, cliff);

        (uint256 total, uint256 claimed, uint64 gStart, uint64 gDuration, uint64 gCliff, bool active) =
            vault.grants(recipient1);

        assertEq(total, grantAmount);
        assertEq(claimed, 0);
        assertEq(gStart, start);
        assertEq(gDuration, duration);
        assertEq(gCliff, cliff);
        assertTrue(active);
        assertEq(vault.contractBalance(), INITIAL_BALANCE - grantAmount);
    }

    function testFuzz_VestedAmount_LinearityAfterCliff(uint256 grantAmount, uint64 duration, uint64 timeElapsed)
        public
    {
        grantAmount = bound(grantAmount, 1 ether, INITIAL_BALANCE);
        duration = uint64(bound(duration, 30 days, 365 days));
        timeElapsed = uint64(bound(timeElapsed, 0, duration));

        uint64 start = uint64(block.timestamp);

        vm.prank(owner);
        vault.createGrant(recipient1, grantAmount, start, duration, 0);

        vm.warp(start + timeElapsed);

        uint256 vested = vault.vestedAmount(recipient1);

        assertLe(vested, grantAmount);

        // if time >= duration we should be fully vested
        if (timeElapsed >= duration) {
            assertEq(vested, grantAmount);
        }
    }

    function testFuzz_Claim_FeesCorrect(uint256 grantAmount, uint64 duration) public {
        grantAmount = bound(grantAmount, 10 ether, INITIAL_BALANCE);
        duration = uint64(bound(duration, 30 days, 365 days));

        uint64 start = uint64(block.timestamp);

        vm.prank(owner);
        vault.createGrant(recipient1, grantAmount, start, duration, 0);

        vm.warp(start + duration);

        uint256 feeBalanceBefore = token.balanceOf(feeRecipient);
        uint256 recipientBalanceBefore = token.balanceOf(recipient1);

        vm.prank(recipient1);
        vault.claim();

        uint256 expectedFee = (grantAmount * PROTOCOL_FEE_BPS) / 10_000;
        uint256 expectedNet = grantAmount - expectedFee;

        assertEq(token.balanceOf(feeRecipient) - feeBalanceBefore, expectedFee);
        assertEq(token.balanceOf(recipient1) - recipientBalanceBefore, expectedNet);
    }

    function testFuzz_Revoke_CorrectSplit(uint256 grantAmount, uint64 duration, uint64 timeElapsed) public {
        grantAmount = bound(grantAmount, 10 ether, INITIAL_BALANCE);
        duration = uint64(bound(duration, 30 days, 365 days));
        timeElapsed = uint64(bound(timeElapsed, 0, duration));

        uint64 start = uint64(block.timestamp);

        vm.prank(owner);
        vault.createGrant(recipient1, grantAmount, start, duration, 0);

        uint256 balanceBeforeRevoke = vault.contractBalance();

        vm.warp(start + timeElapsed);

        uint256 expectedVested = vault.vestedAmount(recipient1);
        uint256 expectedUnvested = grantAmount - expectedVested;

        vm.prank(owner);
        vault.revokeGrant(recipient1);

        assertEq(vault.contractBalance(), balanceBeforeRevoke + expectedUnvested);

        // Grant total should now equal vested
        (uint256 total,,,,,) = vault.grants(recipient1); //deconstruct here
        assertEq(total, expectedVested);
    }

    // =============================================================
    //                    INVARIANT TESTS
    // =============================================================
    // we are going to cover 1. claimed never exceeds total 2. contract balance accounting 3. sum of unclaimed less than or equal to contract balance

    function test_Invariant_ClaimedNeverExceedsTotal() public {
        uint64 start = uint64(block.timestamp);

        vm.prank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, start, DURATION, 0);

        // Check invariant at multiple time points
        for (uint256 i = 0; i <= 10; i++) {
            vm.warp(start + (DURATION * i) / 10);

            (uint256 total, uint256 claimed,,,, bool active) = vault.grants(recipient1);

            if (active) {
                assertLe(claimed, total, "Claimed exceeds total");

                uint256 vested = vault.vestedAmount(recipient1);
                assertLe(vested, total, "Vested exceeds total");
                assertLe(claimed, vested, "Claimed exceeds vested");
            }
        }
    }

    function test_Invariant_ContractBalanceAccounting() public {
        uint256 initialTokenBalance = token.balanceOf(address(vault));
        uint256 initialContractBalance = vault.contractBalance();

        assertEq(initialTokenBalance, initialContractBalance, "Initial state mismatch");

        vm.prank(owner);
        vault.createGrant(recipient1, GRANT_AMOUNT, uint64(block.timestamp), DURATION, 0);

        assertEq(token.balanceOf(address(vault)), initialTokenBalance);
        assertEq(vault.contractBalance(), initialContractBalance - GRANT_AMOUNT);

        // after claim, both balances reduce
        vm.warp(block.timestamp + DURATION);

        uint256 balBeforeClaim = token.balanceOf(address(vault));
        uint256 contractBalBeforeClaim = vault.contractBalance();

        vm.prank(recipient1);
        vault.claim();

        // token balance reduced by full grant
        assertLt(token.balanceOf(address(vault)), balBeforeClaim);
        // contract balance unchanged (was already allocated)
        assertEq(vault.contractBalance(), contractBalBeforeClaim);
    }

    function test_Invariant_SumOfUnclaimedLessThanOrEqualContractBalance() public {
        // CRITICAL INVARIANT: sum(grants.total - grants.claimed) <= contractBalance
        // this ensures we never over-allocate funds

        uint64 start = uint64(block.timestamp);

        // create array of grants

        vm.startPrank(owner);
        vault.createGrant(recipient1, 3000 ether, start, DURATION, 0);
        vault.createGrant(recipient2, 2000 ether, start, DURATION * 2, 0);
        vm.stopPrank();

        // check invariant at multiple timestops
        for (uint256 i = 0; i <= 10; i++) {
            vm.warp(start + (DURATION * 2 * i) / 10);

            (uint256 g1Total, uint256 g1Claimed,,,, bool g1Active) = vault.grants(recipient1);
            (uint256 g2Total, uint256 g2Claimed,,,, bool g2Active) = vault.grants(recipient2);

            uint256 totalUnclaimed = 0;
            if (g1Active) totalUnclaimed += (g1Total - g1Claimed);
            if (g2Active) totalUnclaimed += (g2Total - g2Claimed);

            uint256 contractBal = vault.contractBalance();
            uint256 tokenBal = token.balanceOf(address(vault));

            // INVARIANT: Unclaimed allocations + contractBalance = tokenBalance
            assertEq(totalUnclaimed + contractBal, tokenBal, "Invariant violated: accounting mismatch");

            // try claiming if vested for arguments sake
            if (vault.vestedAmount(recipient1) > g1Claimed) {
                vm.prank(recipient1);
                vault.claim();
            }
        }

        (uint256 g1Total, uint256 g1Claimed,,,, bool g1Active) = vault.grants(recipient1);
        (uint256 g2Total, uint256 g2Claimed,,,, bool g2Active) = vault.grants(recipient2);

        uint256 finalUnclaimed = 0;
        if (g1Active) finalUnclaimed += (g1Total - g1Claimed);
        if (g2Active) finalUnclaimed += (g2Total - g2Claimed);

        assertEq(
            finalUnclaimed + vault.contractBalance(), token.balanceOf(address(vault)), "Final invariant check failed"
        );
    }
}
