// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Topic 3: Custom Accounting & Delta-Returning Hook (Mini Implementation)
 * @notice In-depth, line-by-line educational walkthrough demonstrating how a Uniswap v4 Hook
 *         can intercept a user's swap and fulfill it directly from internal reserves using
 *         `BeforeSwapDelta`, bypassing the AMM tick curve and eliminating slippage/price impact.
 *
 * =========================================================================================
 * ARCHITECTURAL CONCEPT: "Delta-Returning Hooks"
 * =========================================================================================
 * In Uniswap v3, every swap had to run through the AMM curve (x * y = k math across ticks).
 * In Uniswap v4, a Hook can return a delta (`BeforeSwapDelta`) to the PoolManager.
 *
 * When the Hook returns a delta:
 * 1. It tells PoolManager: "I am taking X amount of the trader's input tokens."
 * 2. It tells PoolManager: "I am providing Y amount of output tokens to the trader."
 * 3. PoolManager subtracts X from the swap amount.
 * 4. If X equals 100% of the trade, ZERO tokens touch the AMM curve! No price impact occurs!
 * =========================================================================================
 */
contract DeltaReturnsHookMini {

    // =====================================================================================
    // SECTION 1: HOOK PERMISSION BIT FLAGS
    // =====================================================================================

    /// @notice Bit 3 (0x0008): Informs PoolManager that this hook returns a custom BeforeSwapDelta.
    /// @dev 1 << 3 in binary is 0000_0000_0000_1000. When this bit is set in the Hook's address,
    /// PoolManager knows to read and apply the returned BeforeSwapDelta from beforeSwap().
    uint16 public constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3; // 0x0008

    /// @notice Bit 7 (0x0080): Informs PoolManager that this hook implements the beforeSwap callback.
    /// @dev 1 << 7 in binary is 0000_0000_1000_0000. Without this flag, PoolManager skips beforeSwap.
    uint16 public constant BEFORE_SWAP_FLAG = 1 << 7; // 0x0080


    // =====================================================================================
    // SECTION 2: INTERNAL VAULT RESERVES
    // =====================================================================================

    /// @notice Internal vault reserve holding Token0 (e.g. deposited limit orders or CoW liquidity).
    /// @dev uint256 tracks the balance of Token0 held within this Hook contract.
    uint256 public internalReserveToken0;

    /// @notice Internal vault reserve holding Token1.
    /// @dev uint256 tracks the balance of Token1 held within this Hook contract.
    uint256 public internalReserveToken1;

    /// @notice Fixed execution exchange rate used for internal matching (1 Token0 = 2 Token1).
    /// @dev In a production protocol, this would be determined by a TWAP, CoW batching, or limit orders.
    uint256 public constant INTERNAL_RATE = 2;


    // =====================================================================================
    // SECTION 3: EVENTS
    // =====================================================================================

    /// @notice Emitted whenever a trade is intercepted and fulfilled internally by the Hook.
    /// @param trader The address of the user initiating the swap.
    /// @param amountInFulfilled Amount of input tokens consumed by the Hook's internal vault.
    /// @param amountOutProvided Amount of output tokens paid to the trader from the Hook's vault.
    /// @param remainingForAMM Amount of input tokens that could not be fulfilled internally and
    ///                       must be executed on the AMM tick curve.
    event InternalSwapFulfilled(
        address indexed trader,
        uint256 amountInFulfilled,
        uint256 amountOutProvided,
        uint256 remainingForAMM
    );


    // =====================================================================================
    // SECTION 4: CONSTRUCTOR
    // =====================================================================================

    /// @notice Seeds the Hook's internal vault with initial liquidity for demonstration.
    constructor() {
        // Deposit 1,000 units of Token0 into the internal vault
        internalReserveToken0 = 1000 ether;

        // Deposit 2,000 units of Token1 into the internal vault (matches the 2:1 rate)
        internalReserveToken1 = 2000 ether;
    }


    // =====================================================================================
    // SECTION 5: BEFORE_SWAP_DELTA PACKING HELPER
    // =====================================================================================

    /**
     * @notice Packs two 128-bit signed deltas into a single 256-bit signed integer.
     * @dev In Uniswap v4, `BeforeSwapDelta` is represented as a single `int256` to save gas.
     *      Layout of the 256 bits:
     *      - Upper 128 bits: int128 deltaSpecified (how much input/output the Hook intercepts).
     *      - Lower 128 bits: int128 deltaUnspecified (the opposite token delta provided by Hook).
     *
     * @param deltaSpecified   Signed change to the user's specified currency.
     * @param deltaUnspecified Signed change to the user's unspecified currency.
     * @return Packed int256 representing the BeforeSwapDelta.
     */
    function toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
        public
        pure
        returns (int256)
    {
        // Step 1: Shift deltaSpecified left by 128 bits to occupy the upper half of the 256-bit word.
        int256 upper = int256(deltaSpecified) << 128;

        // Step 2: Mask deltaUnspecified as a 128-bit unsigned value, then cast to int256
        // to prevent negative sign extension from corrupting the upper 128 bits.
        int256 lower = int256(uint256(uint128(deltaUnspecified)));

        // Step 3: Combine upper and lower halves using bitwise OR (|).
        return upper | lower;
    }


    // =====================================================================================
    // SECTION 6: CORE LOGIC - SWAP INTERCEPTION WITH DELTA RETURNS
    // =====================================================================================

    /**
     * @notice Simulates PoolManager calling `beforeSwap` when `beforeSwapReturnDelta` is active.
     *
     * @param trader Address of the user executing the swap.
     * @param zeroForOne Direction of the trade:
     *                   true  = Trader gives Token0, receives Token1.
     *                   false = Trader gives Token1, receives Token0.
     * @param amountSpecified Exact amount of tokens the trader wishes to swap.
     *
     * @return returnDelta Packed BeforeSwapDelta passed back to the PoolManager.
     * @return remainingForAMM Amount of input tokens leftover to be swapped on the AMM curve.
     */
    function processBeforeSwapWithDelta(
        address trader,
        bool zeroForOne,
        uint256 amountSpecified
    ) external returns (int256 returnDelta, uint256 remainingForAMM) {

        // Line 1: Ensure trader is not swapping 0 tokens
        require(amountSpecified > 0, "Zero swap amount");

        // Line 2: Declare int128 variable to store how much input the Hook takes responsibility for
        int128 hookSpecifiedDelta;

        // Line 3: Declare int128 variable to store how much output the Hook will pay to the trader
        int128 hookUnspecifiedDelta;

        // =================================================================================
        // BRANCH A: Trader is swapping Token0 for Token1 (zeroForOne == true)
        // =================================================================================
        if (zeroForOne) {

            // Line 4: Calculate how much Token1 output is needed for the requested Token0 input at 2:1 rate
            uint256 desiredToken1Out = amountSpecified * INTERNAL_RATE;

            // Check if the Hook's internal vault has enough Token1 to fulfill the entire swap
            if (internalReserveToken1 >= desiredToken1Out) {

                // -------------------------------------------------------------------------
                // CASE A.1: 100% INTERNAL FULFILLMENT (Zero AMM Impact!)
                // -------------------------------------------------------------------------

                // Line 5: Deduct the output Token1 from the Hook's internal vault
                internalReserveToken1 -= desiredToken1Out;

                // Line 6: Add the input Token0 into the Hook's internal vault
                internalReserveToken0 += amountSpecified;

                // Line 7: Set hookSpecifiedDelta = positive amountSpecified.
                // Positive value tells PoolManager: "The Hook has taken 100% of this input amount."
                hookSpecifiedDelta = int128(uint128(amountSpecified));

                // Line 8: Set hookUnspecifiedDelta = negative desiredToken1Out.
                // Negative value tells PoolManager: "Credit the trader this amount of Token1 from Hook's tab."
                hookUnspecifiedDelta = -int128(uint128(desiredToken1Out));

                // Line 9: Zero tokens remaining! The AMM curve does NOT execute any trade at all.
                remainingForAMM = 0;

            } else {

                // -------------------------------------------------------------------------
                // CASE A.2: PARTIAL INTERNAL FULFILLMENT (Remainder routes to AMM)
                // -------------------------------------------------------------------------

                // Line 10: Read all available Token1 currently sitting in the Hook's vault
                uint256 maxToken1Available = internalReserveToken1;

                // Line 11: Calculate how much Token0 input can be matched by this available Token1
                uint256 token0Fulfilled = maxToken1Available / INTERNAL_RATE;

                // Line 12: Deplete the Hook's internal Token1 vault to 0
                internalReserveToken1 = 0;

                // Line 13: Deposit the matched Token0 into the Hook's internal vault
                internalReserveToken0 += token0Fulfilled;

                // Line 14: Tell PoolManager the Hook intercepted this portion of the input
                hookSpecifiedDelta = int128(uint128(token0Fulfilled));

                // Line 15: Tell PoolManager to credit the trader with all available Token1
                hookUnspecifiedDelta = -int128(uint128(maxToken1Available));

                // Line 16: The unmatched portion of Token0 is passed through to execute on the AMM tick curve
                remainingForAMM = amountSpecified - token0Fulfilled;
            }

        // =================================================================================
        // BRANCH B: Trader is swapping Token1 for Token0 (zeroForOne == false)
        // =================================================================================
        } else {

            // Line 17: Calculate how much Token0 output is needed for the requested Token1 input at 2:1 rate
            uint256 desiredToken0Out = amountSpecified / INTERNAL_RATE;

            // Check if the Hook's internal vault has enough Token0 to fulfill the swap
            if (internalReserveToken0 >= desiredToken0Out) {

                // -------------------------------------------------------------------------
                // CASE B.1: 100% INTERNAL FULFILLMENT
                // -------------------------------------------------------------------------

                // Line 18: Deduct output Token0 from Hook vault
                internalReserveToken0 -= desiredToken0Out;

                // Line 19: Add input Token1 to Hook vault
                internalReserveToken1 += amountSpecified;

                // Line 20: Hook claims 100% of the input Token1
                hookSpecifiedDelta = int128(uint128(amountSpecified));

                // Line 21: Hook credits output Token0 to the trader
                hookUnspecifiedDelta = -int128(uint128(desiredToken0Out));

                // Line 22: AMM tick curve does not move
                remainingForAMM = 0;

            } else {

                // -------------------------------------------------------------------------
                // CASE B.2: PARTIAL INTERNAL FULFILLMENT
                // -------------------------------------------------------------------------

                // Line 23: Read all available Token0 in Hook vault
                uint256 maxToken0Available = internalReserveToken0;

                // Line 24: Calculate how much Token1 can be matched by available Token0
                uint256 token1Fulfilled = maxToken0Available * INTERNAL_RATE;

                // Line 25: Deplete Token0 vault to 0
                internalReserveToken0 = 0;

                // Line 26: Add matched Token1 to Hook vault
                internalReserveToken1 += token1Fulfilled;

                // Line 27: Hook takes the matched Token1 amount
                hookSpecifiedDelta = int128(uint128(token1Fulfilled));

                // Line 28: Hook credits the available Token0 to the trader
                hookUnspecifiedDelta = -int128(uint128(maxToken0Available));

                // Line 29: Route remaining unmatched Token1 to the AMM tick curve
                remainingForAMM = amountSpecified - token1Fulfilled;
            }
        }

        // Line 30: Pack the two int128 values into a single int256 BeforeSwapDelta
        returnDelta = toBeforeSwapDelta(hookSpecifiedDelta, hookUnspecifiedDelta);

        // Line 31: Emit audit log event recording the internal fulfillment details
        emit InternalSwapFulfilled(
            trader,
            uint128(hookSpecifiedDelta),
            uint128(-hookUnspecifiedDelta),
            remainingForAMM
        );
    }
}
