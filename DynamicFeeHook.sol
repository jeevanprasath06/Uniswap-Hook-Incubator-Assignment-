// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Topic 6: Simple Dynamic Fee Hook (Mini Implementation)
 * @notice In-depth, line-by-line educational walkthrough demonstrating the fundamental
 *         mechanics of Uniswap v4 Dynamic Fees.
 *
 * =========================================================================================
 * ARCHITECTURAL CONCEPT: "Dynamic Fees in Uniswap v4"
 * =========================================================================================
 * In Uniswap v3:
 * - A pool's fee tier was permanently hardcoded at creation (e.g. 0.05%, 0.30%, or 1.00%).
 * - If market conditions changed, LPs had to withdraw all liquidity and migrate to a new pool.
 *
 * In Uniswap v4:
 * - A pool can be initialized with the `DYNAMIC_FEE_FLAG` enabled.
 * - On every trade, `PoolManager` calls the Hook's `beforeSwap()` callback.
 * - The Hook calculates the appropriate fee in real time and returns it with the
 *   `OVERRIDE_FEE_FLAG` bit set.
 * - `PoolManager` immediately applies this calculated fee to that specific transaction!
 *
 * THIS IMPLEMENTATION: "Volume-Tiered Dynamic Fee Model"
 * 1. Small Retail Swaps (< 1 token): 0.10% fee (Discounted to attract retail volume).
 * 2. Medium Swaps (1 to 10 tokens): 0.30% fee (Standard baseline fee).
 * 3. Large Whale Swaps (> 10 tokens): 0.60% fee (Elevated to protect LPs from price impact).
 * =========================================================================================
 */
contract SimpleDynamicFeeHookMini {

    // =====================================================================================
    // SECTION 1: HOOK PERMISSION BIT FLAGS & UNISWAP V4 CONSTANTS
    // =====================================================================================

    /// @notice Bit 7 (0x0080): Informs PoolManager that this hook implements beforeSwap.
    /// @dev 1 << 7 in binary is 0000_0000_1000_0000. When this bit is set in the Hook address,
    /// PoolManager will call beforeSwap() before executing any swap.
    uint16 public constant BEFORE_SWAP_FLAG = 1 << 7; // 0x0080

    /// @notice Special 24-bit flag (1 << 23 = 0x800000) defined by Uniswap v4's LPFeeLibrary.
    /// @dev When returned from beforeSwap(), this high bit signals to PoolManager:
    /// "Do not use the pool's default fee; override it with the fee returned in the lower 23 bits!"
    uint24 public constant OVERRIDE_FEE_FLAG = 1 << 23; // 0x800000

    /// @notice Bitmask to isolate the raw fee pips from the override flag (0x7FFFFF).
    /// @dev Bitwise AND (&) with this mask strips the 24th bit, leaving only the fee amount.
    uint24 public constant RAW_FEE_MASK = 0x7FFFFF;


    // =====================================================================================
    // SECTION 2: FEE TIER CONSTANTS (EXPRESSED IN PIPS)
    // =====================================================================================
    // In Uniswap, fees are measured in pips (hundredths of a basis point).
    // 1,000,000 pips = 100%
    // 10,000 pips    = 1.00%
    // 3,000 pips     = 0.30%
    // 1,000 pips     = 0.10%
    // 100 pips       = 0.01%
    // -------------------------------------------------------------------------------------

    /// @notice Fee charged on small retail trades: 1,000 pips (0.10%).
    /// @dev Encourages organic retail volume by making small trades cheap.
    uint24 public constant RETAIL_FEE = 1000; // 0.10%

    /// @notice Standard fee charged on normal trades: 3,000 pips (0.30%).
    /// @dev Matches the traditional standard Uniswap 0.30% fee tier.
    uint24 public constant BASE_FEE = 3000; // 0.30%

    /// @notice Fee charged on large whale trades: 6,000 pips (0.60%).
    /// @dev Compensates LPs for taking higher inventory risk and price impact from whale orders.
    uint24 public constant WHALE_FEE = 6000; // 0.60%


    // =====================================================================================
    // SECTION 3: VOLUME TIER THRESHOLDS
    // =====================================================================================

    /// @notice Volume threshold below which trades qualify for the retail discount (< 1 ether).
    uint256 public constant RETAIL_THRESHOLD = 1 ether;

    /// @notice Volume threshold above which trades are classified as whale swaps (> 10 ether).
    uint256 public constant WHALE_THRESHOLD = 10 ether;


    // =====================================================================================
    // SECTION 4: EVENTS
    // =====================================================================================

    /// @notice Emitted whenever a dynamic fee is evaluated and returned for a swap.
    /// @param poolId Identifier of the pool being traded.
    /// @param swapAmount Absolute volume of the swap.
    /// @param appliedFee The fee tier in pips applied to the trade.
    /// @param feeWithFlag The 24-bit value returned to PoolManager containing the OVERRIDE_FEE_FLAG.
    event DynamicFeeCalculated(
        bytes32 indexed poolId,
        uint256 swapAmount,
        uint24 appliedFee,
        uint24 feeWithFlag
    );


    // =====================================================================================
    // SECTION 5: FEE CALCULATION ENGINE
    // =====================================================================================

    /**
     * @notice Pure function to calculate the dynamic fee based on trade volume.
     * @dev Separated as a pure helper to make unit testing and gas profiling straightforward.
     *
     * @param swapAmount The quantity of tokens being swapped.
     * @return feeInPips The calculated fee in pips (e.g. 1000, 3000, or 6000).
     */
    function determineFeeByVolume(uint256 swapAmount) public pure returns (uint24 feeInPips) {

        // Line 1: Check if swap volume is less than the 1 ether retail threshold
        if (swapAmount < RETAIL_THRESHOLD) {

            // Line 2: Apply the retail discount fee (0.10%)
            return RETAIL_FEE;

        // Line 3: Check if swap volume exceeds the 10 ether whale threshold
        } else if (swapAmount > WHALE_THRESHOLD) {

            // Line 4: Apply the whale protective fee (0.60%)
            return WHALE_FEE;

        // Line 5: Otherwise, the trade falls within the standard 1 - 10 ether band
        } else {

            // Line 6: Apply the standard base fee (0.30%)
            return BASE_FEE;
        }
    }


    // =====================================================================================
    // SECTION 6: BEFORE SWAP CALLBACK (CORE V4 HOOK ENTRYPOINT)
    // =====================================================================================

    /**
     * @notice Executed by PoolManager immediately before a swap begins.
     * @dev Calculates the dynamic fee and returns it with OVERRIDE_FEE_FLAG set.
     *
     * @param poolId Unique identifier for the pool being swapped against.
     * @param amountSpecified Amount of tokens requested by the trader.
     *                        In v4, positive = exact input, negative = exact output.
     *
     * @return selector Function selector confirming successful execution to PoolManager.
     * @return feeToApply The 24-bit fee with the OVERRIDE_FEE_FLAG bit active.
     */
    function processBeforeSwap(
        bytes32 poolId,
        int256 amountSpecified
    ) external returns (bytes4 selector, uint24 feeToApply) {

        // Line 7: Ensure trader is not swapping 0 tokens
        require(amountSpecified != 0, "Zero swap amount");

        // Line 8: Extract the absolute trade volume (convert negative exact-output to positive)
        uint256 volume = amountSpecified < 0
            ? uint256(-amountSpecified)
            : uint256(amountSpecified);

        // Line 9: Calculate the dynamic fee based on trade size
        uint24 rawFee = determineFeeByVolume(volume);

        // Line 10: Attach the OVERRIDE_FEE_FLAG (1 << 23) using bitwise OR (|)
        // This signals to PoolManager that this swap must use this custom fee!
        feeToApply = rawFee | OVERRIDE_FEE_FLAG;

        // Line 11: Emit audit event logging fee details
        emit DynamicFeeCalculated(poolId, volume, rawFee, feeToApply);

        // Line 12: Return selector and the override-flagged fee
        return (this.processBeforeSwap.selector, feeToApply);
    }


    // =====================================================================================
    // SECTION 7: UTILITY HELPERS
    // =====================================================================================

    /**
     * @notice Strips the OVERRIDE_FEE_FLAG to read the actual fee percentage.
     * @param feeWithFlag The 24-bit fee value returned from processBeforeSwap.
     * @return rawFee The fee in pips (e.g. 3000 for 0.30%).
     */
    function extractRawFee(uint24 feeWithFlag) public pure returns (uint24 rawFee) {

        // Line 13: Bitwise AND (&) with RAW_FEE_MASK zeroes out the 24th override flag bit
        return feeWithFlag & RAW_FEE_MASK;
    }

    /**
     * @notice Verifies whether a given 24-bit fee has the override flag bit active.
     * @param feeWithFlag The 24-bit fee value to inspect.
     * @return hasFlag True if OVERRIDE_FEE_FLAG is present, false otherwise.
     */
    function hasOverrideFlag(uint24 feeWithFlag) public pure returns (bool hasFlag) {

        // Line 14: Check if the 24th bit is 1
        return (feeWithFlag & OVERRIDE_FEE_FLAG) != 0;
    }
}
