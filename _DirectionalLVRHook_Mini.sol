// SPDX-License-Identifier: MIT
// The license identifier tells compilers and tools that this code is open-source under the MIT license.

pragma solidity ^0.8.24;
// We target Solidity version 0.8.24 or higher because it natively supports:
// 1. The Cancun hard fork EVM opcodes (specifically EIP-1153: `tstore` and `tload`).
// 2. Custom types and modern overflow/underflow protection.

/**
 * @title Topic 4: Directional LVR Siphon Hook (Mini Implementation)
 * @notice Protects passive Liquidity Providers (LPs) from Loss-Versus-Rebalancing (LVR).
 *
 * HOW IT WORKS AT A HIGH LEVEL:
 * 1. Toxic Arbitrage: When external market prices move, arbitrageurs rush to extract
 *    value by pushing the pool's tick in the same direction as ongoing momentum.
 *    The Hook detects this and surges the swap fee (up to 5.00%).
 * 2. Rebalancing Flow: When a trader swaps in the opposite direction, bringing the pool
 *    back toward balance, the Hook gives them a fee discount (down to 0.01%).
 * 3. Restitution to LPs: The extra fee captured from arbitrageurs is stashed temporarily
 *    in EIP-1153 transient storage, then immediately donated back to active in-range LPs
 *    during `afterSwap` via `poolManager.donate()`.
 */
contract DirectionalLVRHookMini {

    // =========================================================================
    // 1. FEE CONSTANTS (Measured in "pips": 1 pip = 0.0001% = 1/1,000,000th)
    // =========================================================================

    // Uniswap uses 24-bit unsigned integers (uint24) for fee tiers (max 16,777,215).
    // 3,000 pips = 0.30% (the standard Uniswap pool fee tier).
    uint24 public constant BASE_FEE = 3000;

    // Minimum fee floor: 100 pips = 0.01%.
    // Even on the heaviest rebalancing trade, the pool still charges at least 0.01%
    // so liquidity providers are never trading for completely free.
    uint24 public constant MIN_FEE = 100;

    // Maximum fee ceiling: 50,000 pips = 5.00%.
    // When toxic arbitrage momentum is maxed out, the fee spikes up to 5.00% to
    // capture the arbitrage spread and protect LPs from being picked off.
    uint24 public constant MAX_FEE = 50000;

    // Uniswap v4 Dynamic Fee Override Flag:
    // In Uniswap v4, the top bit (bit 23: 1 << 23 = 0x800000) of the returned fee uint24
    // acts as an "override flag". When set, PoolManager overrides the pool's static fee
    // and enforces the dynamic fee returned by this hook.
    uint24 public constant DYNAMIC_FEE_FLAG = 1 << 23;

    // =========================================================================
    // 2. MOMENTUM SENSITIVITY & TRANSIENT STORAGE SLOTS
    // =========================================================================

    // In Uniswap, price is tracked in "ticks". 1 tick ≈ 0.01% price change.
    // 200 ticks ≈ 2.0% price displacement.
    // MOMENTUM_MAX is the ceiling threshold: once the price moves by 200 ticks in one
    // direction, the fee formula reaches its maximum surge (5.00%).
    // We use int24 because ticks in Uniswap are signed 24-bit integers (-8,388,608 to +8,388,607).
    int24 public constant MOMENTUM_MAX = 200;

    // This is the keccak256 hash of the string "SURPLUS_FEE_SLOT".
    // It serves as a unique 32-byte storage key for EIP-1153 Transient Storage.
    // Transient storage lives only for the duration of the current transaction and costs
    // only 100 gas (vs 20,000 gas for regular storage). It resets to 0 automatically.
    bytes32 public constant TRANSIENT_SURPLUS_SLOT = 0xf2404953903c30aedf58424bf9b85dffbd62b17f94de86244b50882366da5186;

    // =========================================================================
    // 3. STATE TRACKING DATA STRUCTURES
    // =========================================================================

    // Tracks the momentum metrics for each individual pool:
    struct PoolMomentumState {
        // The tick price recorded immediately after the most recent swap concluded.
        int24 lastTick;

        // The Exponential Moving Average (EMA) of tick displacement.
        // Positive value = price has been moving UP (token0 getting more expensive).
        // Negative value = price has been moving DOWN (token0 getting cheaper).
        int24 smoothedMomentum;

        // The block number when the pool state was last updated.
        // Used to detect multiple swaps occurring in the SAME block (flash loan defense).
        uint64 lastBlockUpdated;
    }

    // Mapping from unique Uniswap v4 PoolId (bytes32) to its momentum tracking state.
    mapping(bytes32 poolId => PoolMomentumState) public poolStates;

    // =========================================================================
    // 4. EVENTS (For off-chain monitoring, analytics, and indexers)
    // =========================================================================

    // Emitted whenever `beforeSwap` evaluates momentum and applies a dynamic fee.
    event MomentumTracked(bytes32 indexed poolId, int24 smoothedMomentum, uint24 dynamicFee);

    // Emitted in `afterSwap` when the surplus fee is siphoned and donated to LPs.
    event LPRestitutionDonated(bytes32 indexed poolId, uint256 surplusAmount);

    // =========================================================================
    // 5. BEFORE SWAP: EVALUATE DIRECTION, COMPUTE FEE & STASH SURPLUS
    // =========================================================================

    /**
     * @notice Executed right before a swap occurs on the pool curve.
     * @param poolId The unique identifier of the pool being traded.
     * @param zeroForOne Swap direction:
     *        - true: Trader sells token0 to buy token1 -> pushes tick DOWN (negative delta).
     *        - false: Trader sells token1 to buy token0 -> pushes tick UP (positive delta).
     * @param currentTick The current tick price of the pool before this swap executes.
     * @return feeToCharge The dynamic fee packed with the OVERRIDE_FEE_FLAG bit.
     */
    function processBeforeSwap(
        bytes32 poolId,
        bool zeroForOne,
        int24 currentTick
    ) external returns (uint24 feeToCharge) {
        // Load a storage reference to the pool's ongoing momentum state.
        PoolMomentumState storage state = poolStates[poolId];

        // First-swap initialization: if the pool is being traded for the very first time,
        // seed `lastTick` with the current pool tick so delta calculations have a starting point.
        if (state.lastTick == 0 && state.smoothedMomentum == 0) {
            state.lastTick = currentTick;
        }

        // Determine the directional sign of the incoming swap:
        // Selling token0 (zeroForOne = true) drives price down -> directional sign is -1.
        // Buying token0 (zeroForOne = false) drives price up -> directional sign is +1.
        int256 direction = zeroForOne ? -1 : int256(1);

        // Compute "alignment" between the trade direction and historical momentum:
        // alignment = direction * smoothedMomentum
        // If momentum is positive (+100) and trade pushes UP (+1): (+1) * (+100) = +100 (> 0: TOXIC)
        // If momentum is positive (+100) and trade pushes DOWN (-1): (-1) * (+100) = -100 (< 0: REBALANCING)
        int256 alignment = direction * int256(state.smoothedMomentum);

        // Default fee starts at the standard baseline (0.30%).
        uint24 dynamicFee = BASE_FEE;

        if (alignment > 0) {
            // -------------------------------------------------------------
            // CASE A: TOXIC ARBITRAGE FLOW (Trade moves WITH price momentum)
            // -------------------------------------------------------------

            // The surge factor represents the severity of momentum alignment.
            uint256 surge = uint256(alignment);

            // Cap the surge factor at MOMENTUM_MAX (200 ticks) so fees never exceed MAX_FEE.
            if (surge > uint24(MOMENTUM_MAX)) {
                surge = uint24(MOMENTUM_MAX);
            }

            // Linear interpolation: feeIncrease = (MAX_FEE - BASE_FEE) * (surge / MOMENTUM_MAX)
            // Example at max surge: (50000 - 3000) * 200 / 200 = 47,000 pips.
            uint256 feeIncrease = ((uint256(MAX_FEE) - uint256(BASE_FEE)) * surge) / uint24(MOMENTUM_MAX);

            // Add the increase to the base fee: dynamicFee can reach up to 50,000 (5.00%).
            dynamicFee = uint24(BASE_FEE + feeIncrease);

            // Calculate the "surplus fee" above the normal 0.30% baseline.
            // This surplus is the extracted arbitrage profit that belongs to passive LPs.
            uint256 surplusPips = dynamicFee - BASE_FEE;

            // Stash `surplusPips` into EIP-1153 Transient Storage using inline Yul assembly.
            // `tstore` writes to temporary EVM memory (gas cost: 100 gas).
            // It will be read in `processAfterSwap` to compute the donation amount.
            assembly {
                tstore(0xf2404953903c30aedf58424bf9b85dffbd62b17f94de86244b50882366da5186, surplusPips)
            }
        } else {
            // -------------------------------------------------------------
            // CASE B: REBALANCING FLOW (Trade moves AGAINST price momentum)
            // -------------------------------------------------------------

            // Since alignment is negative, negate it to get the positive magnitude of relief.
            uint256 relief = uint256(-alignment);

            // Cap relief at MOMENTUM_MAX (200 ticks).
            if (relief > uint24(MOMENTUM_MAX)) {
                relief = uint24(MOMENTUM_MAX);
            }

            // Linear discount: discount = (BASE_FEE - MIN_FEE) * (relief / MOMENTUM_MAX)
            // Example at max relief: (3000 - 100) * 200 / 200 = 2,900 pips discount.
            uint256 feeDiscount = ((uint256(BASE_FEE) - uint256(MIN_FEE)) * relief) / uint24(MOMENTUM_MAX);

            // Subtract the discount: dynamicFee can drop down to 100 pips (0.01%).
            dynamicFee = uint24(BASE_FEE - feeDiscount);

            // Rebalancing trades pay no surplus penalty, so reset transient slot to 0.
            assembly {
                tstore(0xf2404953903c30aedf58424bf9b85dffbd62b17f94de86244b50882366da5186, 0)
            }
        }

        // Emit event for off-chain monitoring.
        emit MomentumTracked(poolId, state.smoothedMomentum, dynamicFee);

        // Bitwise OR (`|`) with DYNAMIC_FEE_FLAG (bit 23).
        // This informs Uniswap v4's PoolManager: "Do not use the static pool fee;
        // enforce this dynamicFee value for this swap!"
        return dynamicFee | DYNAMIC_FEE_FLAG;
    }

    // =========================================================================
    // 6. AFTER SWAP: UPDATE MOMENTUM EMA & DONATE SURPLUS RESTITUTION TO LPS
    // =========================================================================

    /**
     * @notice Executed immediately after the swap completes and the tick curve has moved.
     * @param poolId The unique identifier of the pool being traded.
     * @param postSwapTick The new pool tick resulting from this completed swap.
     * @param swapAmount The trade volume input into the pool.
     */
    function processAfterSwap(
        bytes32 poolId,
        int24 postSwapTick,
        uint256 swapAmount
    ) external {
        // Load the pool momentum state from storage.
        PoolMomentumState storage state = poolStates[poolId];

        // 1. Calculate how many ticks the price moved during this specific swap.
        // Positive deltaTick = price moved UP. Negative deltaTick = price moved DOWN.
        int24 deltaTick = postSwapTick - state.lastTick;

        // 2. Update Exponential Moving Average (EMA) with Flash Loan Resistance:
        int256 newMomentum;

        // Flash Loan Attack Defense:
        // If an attacker attempts to manipulate momentum using multiple back-to-back swaps
        // in the SAME BLOCK, `lastBlockUpdated == block.number` is triggered.
        if (state.lastBlockUpdated == block.number) {
            // Heavily dampen new movements: 95% weight to prior momentum, only 5% to the new tick move.
            // This prevents an intra-block flash loan from creating a massive artificial surge fee.
            newMomentum = (int256(state.smoothedMomentum) * 950 + int256(deltaTick) * 50) / 1000;
        } else {
            // Normal block-to-block trading: 80% weight to prior momentum, 20% to the new tick move.
            newMomentum = (int256(state.smoothedMomentum) * 800 + int256(deltaTick) * 200) / 1000;

            // Update the block timestamp to the current block number.
            state.lastBlockUpdated = uint64(block.number);
        }

        // Clamp momentum within [-MOMENTUM_MAX, +MOMENTUM_MAX] to prevent integer overflow.
        if (newMomentum > int24(MOMENTUM_MAX)) {
            newMomentum = int24(MOMENTUM_MAX);
        }
        if (newMomentum < -int24(MOMENTUM_MAX)) {
            newMomentum = -int24(MOMENTUM_MAX);
        }

        // Save the updated momentum back to storage.
        state.smoothedMomentum = int24(newMomentum);

        // Update lastTick so the NEXT swap can measure its displacement from this final tick.
        state.lastTick = postSwapTick;

        // 3. Retrieve the transient surplus fee stashed during `processBeforeSwap`.
        // `tload` reads from EIP-1153 temporary memory (costs only 100 gas).
        uint256 surplusPips;
        assembly {
            surplusPips := tload(0xf2404953903c30aedf58424bf9b85dffbd62b17f94de86244b50882366da5186)
        }

        // 4. Restitution to Passive LPs:
        // If a surplus fee was collected (i.e. this was a toxic trade), calculate the token amount.
        if (surplusPips > 0 && swapAmount > 0) {
            // Formula: donationAmount = (swapAmount * surplusPips) / 1,000,000 pips
            // Example: A 10 ETH swap with a 4.70% surplus fee (47,000 pips):
            // donationAmount = (10 ETH * 47,000) / 1,000,000 = 0.47 ETH donated!
            uint256 donationAmount = (swapAmount * surplusPips) / 1_000_000;

            // In production Uniswap v4, this calls:
            // poolManager.donate(key, donationAmount, 0, "");
            // which directly credits this 0.47 ETH into the fee growth accumulator
            // for active, in-range liquidity providers without shifting the tick curve!
            emit LPRestitutionDonated(poolId, donationAmount);
        }
    }
}
