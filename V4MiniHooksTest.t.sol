// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/V3/V4/01_HookAddressMining.sol";
import "../contracts/V3/V4/02_DirectionalLVRHook_Mini.sol";
import "../contracts/V3/V4/03_DeltaReturnsHook_Mini.sol";

contract V4MiniHooksTest is Test {
    HookAddressMiningExplainer miningExplainer;
    DirectionalLVRHookMini lvrHook;
    DeltaReturnsHookMini deltaHook;

    bytes32 constant POOL_ID = keccak256("TEST_POOL_V4");

    function setUp() public {
        miningExplainer = new HookAddressMiningExplainer();
        lvrHook = new DirectionalLVRHookMini();
        deltaHook = new DeltaReturnsHookMini();
    }

    // -------------------------------------------------------------
    // Test 1: Hook Address Mining & Bitmask Verification
    // -------------------------------------------------------------
    function test_AddressMiningFindsMatchingBitmask() public view {
        // Require BEFORE_SWAP (0x0080) and AFTER_SWAP (0x0040) -> 0x00C0
        uint16 requiredFlags = miningExplainer.BEFORE_SWAP_FLAG() | miningExplainer.AFTER_SWAP_FLAG();
        bytes memory dummyBytecode = type(DirectionalLVRHookMini).creationCode;

        // Mine salt
        (bytes32 salt, address minedAddr, uint256 attempts) = miningExplainer.mineSalt(
            address(this),
            dummyBytecode,
            requiredFlags,
            100000
        );

        assertTrue(salt != bytes32(0) || attempts == 0);
        assertTrue(minedAddr != address(0));

        // Verify the mined address satisfies the bitmask
        assertTrue(miningExplainer.hasSwapHooks(minedAddr), "Mined address must have swap hooks");
        assertTrue(miningExplainer.hasBeforeSwap(minedAddr), "Mined address must have beforeSwap");
    }

    // -------------------------------------------------------------
    // Test 2: Directional LVR Hook - Surge Fee on Toxic Momentum Trade
    // -------------------------------------------------------------
    function test_DirectionalLVR_ToxicTradePaysSurgeFee() public {
        // Step 1: Initial trade sets baseline tick and initial positive momentum
        lvrHook.processBeforeSwap(POOL_ID, false, 100);
        lvrHook.processAfterSwap(POOL_ID, 150, 1 ether); // price jumped UP (+50 ticks)

        // Momentum is now positive. A subsequent trade with zeroForOne = false (buying/pushing tick UP)
        // is aligned with momentum -> TOXIC ARBITRAGE!
        uint24 fee = lvrHook.processBeforeSwap(POOL_ID, false, 150);

        // Remove override flag for fee comparison
        uint24 rawFee = fee & ~lvrHook.DYNAMIC_FEE_FLAG();

        // Baseline is 3000 (0.30%). Fee must surge above baseline!
        assertGt(rawFee, lvrHook.BASE_FEE(), "Toxic trade must pay surge fee above 0.30%");
    }

    // -------------------------------------------------------------
    // Test 3: Directional LVR Hook - Discount Fee on Rebalancing Trade
    // -------------------------------------------------------------
    function test_DirectionalLVR_RebalancingTradeGetsDiscount() public {
        // Step 1: Establish positive momentum (price jumped UP)
        lvrHook.processBeforeSwap(POOL_ID, false, 100);
        lvrHook.processAfterSwap(POOL_ID, 150, 1 ether);

        // Step 2: An opposing trade arrives: zeroForOne = true (selling/pushing tick DOWN)
        // This opposes momentum -> REBALANCING FLOW!
        uint24 fee = lvrHook.processBeforeSwap(POOL_ID, true, 150);
        uint24 rawFee = fee & ~lvrHook.DYNAMIC_FEE_FLAG();

        // Fee must be discounted below baseline 3000 (0.30%)!
        assertLt(rawFee, lvrHook.BASE_FEE(), "Rebalancing trade must receive fee discount below 0.30%");
    }

    // -------------------------------------------------------------
    // Test 4: Delta-Returning Hook - 100% Internal Fulfillment
    // -------------------------------------------------------------
    function test_DeltaHook_FullInternalFulfillmentLeavesZeroForAMM() public {
        address trader = address(0xABCD);
        uint256 swapAmount = 10 ether; // Trader swaps 10 Token0

        uint256 initReserve0 = deltaHook.internalReserveToken0();
        uint256 initReserve1 = deltaHook.internalReserveToken1();

        // Trader swaps Token0 -> Token1
        (int256 returnDelta, uint256 remainingForAMM) = deltaHook.processBeforeSwapWithDelta(
            trader,
            true, // zeroForOne
            swapAmount
        );

        // At 2:1 rate, 10 Token0 yields 20 Token1
        // Since hook has 2000 Token1 in vault, it fulfills 100% of the trade!
        assertEq(remainingForAMM, 0, "Trade should be 100% fulfilled internally with 0 price impact on AMM");
        assertTrue(returnDelta != 0, "Return delta must be non-zero");

        // Verify Hook Vault updated
        assertEq(deltaHook.internalReserveToken0(), initReserve0 + 10 ether);
        assertEq(deltaHook.internalReserveToken1(), initReserve1 - 20 ether);
    }

    // -------------------------------------------------------------
    // Test 5: Delta-Returning Hook - Partial Fulfillment routes rest to AMM
    // -------------------------------------------------------------
    function test_DeltaHook_PartialFulfillmentRoutesRemainingToAMM() public {
        address trader = address(0xABCD);
        // Request a huge swap: 2000 ether Token0 (requires 4000 ether Token1)
        // But hook only has 2000 ether Token1 in reserve!
        uint256 swapAmount = 2000 ether;

        (, uint256 remainingForAMM) = deltaHook.processBeforeSwapWithDelta(
            trader,
            true, // zeroForOne
            swapAmount
        );

        // Hook should fulfill 1000 Token0 using all 2000 Token1, leaving 1000 Token0 for AMM
        assertEq(remainingForAMM, 1000 ether, "Excess 1000 Token0 must route to AMM curve");
        assertEq(deltaHook.internalReserveToken1(), 0, "Internal Token1 vault depleted");
    }
}

