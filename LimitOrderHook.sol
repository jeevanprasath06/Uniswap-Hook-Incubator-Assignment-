// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Topic 5: Native In-Pool Limit Order Hook (Mini Implementation)
 * @notice In-depth, line-by-line educational walkthrough demonstrating how Uniswap v4
 *         can execute decentralized, zero-keeper on-chain limit orders by monitoring
 *         tick crossing directly inside the `afterSwap` lifecycle callback.
 *
 * =========================================================================================
 * ARCHITECTURAL CONCEPT: "The Double-Cross Problem in Uniswap v3"
 * =========================================================================================
 * In Uniswap v3, users tried to create "range orders" by providing liquidity across a single tick:
 * - If you wanted to sell Token0 at tick 150, you provided Token0 liquidity at [149, 150].
 * - When market price crossed 150, the pool converted your Token0 into Token1.
 *
 * THE DOUBLE-CROSS FLAW:
 * If the market price bounced back below 150 minutes later, the AMM converted your Token1
 * RIGHT BACK into Token0! Unless an off-chain keeper bot (like Gelato or Chainlink) intervened
 * in the exact same second to withdraw your LP NFT, your limit order was undone.
 *
 * THE UNISWAP V4 SOLUTION:
 * The Hook monitors tick movement inside `afterSwap()`:
 * 1. User deposits tokens into the Hook at a target tick price.
 * 2. Every time ANY user swaps on the pool, `afterSwap()` executes.
 * 3. If `postSwapTick` crosses the target tick, the Hook fills the order and permanently
 *    freezes the filled tokens into a `claimable` ledger.
 * 4. Even if the market subsequently crashes back down, the user's converted tokens are
 *    safe and locked! The user can call `claimOrder()` whenever they choose.
 * 5. ZERO external keeper bots, cron jobs, or centralized keepers required!
 * =========================================================================================
 */
contract LimitOrderHookMini {

    // =====================================================================================
    // SECTION 1: HOOK PERMISSION BIT FLAGS
    // =====================================================================================

    /// @notice Bit 6 (0x0040): Informs PoolManager that this hook implements afterSwap.
    /// @dev 1 << 6 in binary is 0000_0000_0100_0000. When set in the Hook address,
    /// PoolManager executes afterSwap() after every swap settles on the tick curve.
    uint16 public constant AFTER_SWAP_FLAG = 1 << 6; // 0x0040


    // =====================================================================================
    // SECTION 2: DATA STRUCTURES & STATE
    // =====================================================================================

    /// @notice Data structure representing a single user limit order.
    struct LimitOrder {
        /// @dev Address of the user who created and funded the limit order.
        address owner;
        /// @dev Swap direction:
        /// true  = Selling Token0 for Token1 (executes when tick rises to/above targetTick).
        /// false = Selling Token1 for Token0 (executes when tick falls to/below targetTick).
        bool zeroForOne;
        /// @dev The specific price tick boundary where this order should trigger.
        int24 targetTick;
        /// @dev Total amount of input tokens committed by the user.
        uint256 amountIn;
        /// @dev Amount of output tokens credited to the order upon execution.
        uint256 amountOutFilled;
        /// @dev Boolean flag set to true once the target tick is crossed.
        bool filled;
        /// @dev Boolean flag set to true once the user withdraws their filled tokens.
        bool claimed;
    }

    /// @notice Auto-incrementing unique order identifier counter.
    uint256 public nextOrderId;

    /// @notice Maps orderId => LimitOrder struct storing order details.
    mapping(uint256 orderId => LimitOrder) public orders;

    /// @notice Maps targetTick => array of order IDs waiting at that specific tick.
    mapping(int24 tick => uint256[] orderIds) public pendingOrdersAtTick;

    /// @notice Tracks the most recent pool tick recorded after a swap.
    int24 public lastTick;


    // =====================================================================================
    // SECTION 3: CUSTOM ERRORS & EVENTS
    // =====================================================================================

    /// @notice Thrown when attempting to claim or cancel an order that does not belong to the caller.
    error Unauthorized();

    /// @notice Thrown when attempting to claim an order that has not been filled yet.
    error OrderNotFilled();

    /// @notice Thrown when attempting to claim or cancel an already settled order.
    error OrderAlreadySettled();

    /// @notice Emitted when a new limit order is registered in the Hook.
    event OrderPlaced(
        uint256 indexed orderId,
        address indexed owner,
        bool zeroForOne,
        int24 targetTick,
        uint256 amountIn
    );

    /// @notice Emitted when a swap causes a tick crossing that fills a limit order.
    event OrderFilled(
        uint256 indexed orderId,
        address indexed owner,
        int24 executionTick,
        uint256 amountOut
    );

    /// @notice Emitted when a user claims their filled output tokens.
    event OrderClaimed(
        uint256 indexed orderId,
        address indexed owner,
        uint256 amountOut
    );

    /// @notice Emitted when a user cancels an unfilled limit order.
    event OrderCancelled(
        uint256 indexed orderId,
        address indexed owner,
        uint256 refundedAmount
    );


    // =====================================================================================
    // SECTION 4: ORDER PLACEMENT
    // =====================================================================================

    /**
     * @notice Places a new on-chain limit order into the Hook's order book.
     * @dev In full v4, the user transfers input tokens or settles deltas with PoolManager.
     *
     * @param zeroForOne Direction: true = selling Token0 for Token1, false = Token1 for Token0.
     * @param targetTick Target price tick where the user wants execution to occur.
     * @param amountIn Amount of input tokens deposited for the order.
     * @return orderId Unique identifier assigned to the created order.
     */
    function placeOrder(
        bool zeroForOne,
        int24 targetTick,
        uint256 amountIn
    ) external returns (uint256 orderId) {

        // Line 1: Ensure user is depositing a non-zero amount of tokens
        require(amountIn > 0, "Zero input amount");

        // Line 2: Assign the current counter value as the new order ID
        orderId = nextOrderId;

        // Line 3: Increment the counter for the next order
        nextOrderId++;

        // Line 4: Store order data in the orders mapping
        orders[orderId] = LimitOrder({
            owner: msg.sender,
            zeroForOne: zeroForOne,
            targetTick: targetTick,
            amountIn: amountIn,
            amountOutFilled: 0,
            filled: false,
            claimed: false
        });

        // Line 5: Add the order ID to the pending list for this target tick
        pendingOrdersAtTick[targetTick].push(orderId);

        // Line 6: Emit audit log event recording order creation
        emit OrderPlaced(orderId, msg.sender, zeroForOne, targetTick, amountIn);

        // Line 7: Return the assigned orderId to caller
        return orderId;
    }


    // =====================================================================================
    // SECTION 5: AFTER SWAP - AUTONOMOUS TICK-CROSSING EXECUTION
    // =====================================================================================

    /**
     * @notice Intercepts the pool state after a swap finishes to check for tick crossings.
     * @dev Completely autonomous: runs inside the normal swap transaction of other traders!
     *
     * @param postSwapTick The new current tick of the pool after the swap executed.
     * @return selector Returns afterSwap selector to PoolManager.
     */
    function processAfterSwap(int24 postSwapTick) external returns (bytes4 selector) {

        // Line 8: Read the previous tick prior to this swap
        int24 previousTick = lastTick;

        // Line 9: Update the stored lastTick state to the new post-swap tick
        lastTick = postSwapTick;

        // Line 10: If this is the initial tick seeding, skip execution
        if (previousTick == 0) {
            return this.processAfterSwap.selector;
        }

        // =================================================================================
        // SCENARIO A: TICK MOVED UPWARD (previousTick < postSwapTick)
        // Token0 price increased! We check for orders selling Token0 (zeroForOne == true).
        // =================================================================================
        if (postSwapTick > previousTick) {

            // Line 11: Iterate through every tick crossed in this upward price movement
            for (int24 tick = previousTick + 1; tick <= postSwapTick; tick++) {

                // Line 12: Fetch array of pending orders registered at this specific tick
                uint256[] storage orderList = pendingOrdersAtTick[tick];

                // Line 13: Loop through all orders pending at this crossed tick
                for (uint256 i = 0; i < orderList.length; i++) {

                    // Line 14: Read the order ID
                    uint256 id = orderList[i];

                    // Line 15: Fetch storage pointer to the order
                    LimitOrder storage order = orders[id];

                    // Line 16: Check if order is eligible (unfilled and selling Token0)
                    if (!order.filled && order.zeroForOne) {

                        // Line 17: Mark order as permanently filled
                        order.filled = true;

                        // Line 18: Calculate output Token1 received (simplified: 1 Token0 = 2 Token1)
                        // In full v4, this matches against the swap's excess currency delta
                        uint256 outputTokens = order.amountIn * 2;

                        // Line 19: Lock the output tokens safely into the order record
                        order.amountOutFilled = outputTokens;

                        // Line 20: Emit audit log event recording successful fill
                        emit OrderFilled(id, order.owner, tick, outputTokens);
                    }
                }
            }

        // =================================================================================
        // SCENARIO B: TICK MOVED DOWNWARD (previousTick > postSwapTick)
        // Token0 price decreased / Token1 price increased! Check orders selling Token1.
        // =================================================================================
        } else if (postSwapTick < previousTick) {

            // Line 21: Iterate downwards through ticks crossed in this downward movement
            for (int24 tick = previousTick - 1; tick >= postSwapTick; tick--) {

                // Line 22: Fetch array of pending orders registered at this specific tick
                uint256[] storage orderList = pendingOrdersAtTick[tick];

                // Line 23: Loop through all orders pending at this crossed tick
                for (uint256 i = 0; i < orderList.length; i++) {

                    // Line 24: Read the order ID
                    uint256 id = orderList[i];

                    // Line 25: Fetch storage pointer to the order
                    LimitOrder storage order = orders[id];

                    // Line 26: Check if order is eligible (unfilled and selling Token1)
                    if (!order.filled && !order.zeroForOne) {

                        // Line 27: Mark order as permanently filled
                        order.filled = true;

                        // Line 28: Calculate output Token0 received (simplified: 2 Token1 = 1 Token0)
                        uint256 outputTokens = order.amountIn / 2;

                        // Line 29: Lock the output tokens safely into the order record
                        order.amountOutFilled = outputTokens;

                        // Line 30: Emit audit log event recording successful fill
                        emit OrderFilled(id, order.owner, tick, outputTokens);
                    }
                }
            }
        }

        // Line 31: Return function selector to confirm successful execution to PoolManager
        return this.processAfterSwap.selector;
    }


    // =====================================================================================
    // SECTION 6: CLAIM FILLED TOKENS
    // =====================================================================================

    /**
     * @notice Allows an order owner to withdraw their converted tokens after a fill.
     * @dev Protected against the Double-Cross problem: once filled, it never reverts back!
     *
     * @param orderId Unique identifier of the order to claim.
     * @return amountOut The total amount of output tokens claimed and sent to the owner.
     */
    function claimOrder(uint256 orderId) external returns (uint256 amountOut) {

        // Line 32: Fetch storage pointer to the order
        LimitOrder storage order = orders[orderId];

        // Line 33: Verify that the caller is indeed the owner of the order
        if (msg.sender != order.owner) {
            revert Unauthorized();
        }

        // Line 34: Ensure the order has already crossed its target tick and filled
        if (!order.filled) {
            revert OrderNotFilled();
        }

        // Line 35: Prevent double-claiming an already withdrawn order
        if (order.claimed) {
            revert OrderAlreadySettled();
        }

        // Line 36: Mark the order as permanently claimed
        order.claimed = true;

        // Line 37: Read the filled output token amount
        amountOut = order.amountOutFilled;

        // Line 38: Emit claim audit log event
        emit OrderClaimed(orderId, msg.sender, amountOut);

        // Line 39: Return the claimed token amount to caller
        return amountOut;
    }


    // =====================================================================================
    // SECTION 7: CANCEL UNFILLED ORDER
    // =====================================================================================

    /**
     * @notice Allows an order owner to cancel an unfilled order and refund their input tokens.
     *
     * @param orderId Unique identifier of the order to cancel.
     * @return refundedAmount The total amount of input tokens returned to the owner.
     */
    function cancelOrder(uint256 orderId) external returns (uint256 refundedAmount) {

        // Line 40: Fetch storage pointer to the order
        LimitOrder storage order = orders[orderId];

        // Line 41: Verify caller is the order owner
        if (msg.sender != order.owner) {
            revert Unauthorized();
        }

        // Line 42: An already filled or claimed order cannot be cancelled
        if (order.filled || order.claimed) {
            revert OrderAlreadySettled();
        }

        // Line 43: Mark the order as claimed/settled to prevent future execution
        order.claimed = true;

        // Line 44: Mark filled = true so future tick crossings skip this order
        order.filled = true;

        // Line 45: Refund the original deposited amount
        refundedAmount = order.amountIn;

        // Line 46: Emit audit log event recording cancellation
        emit OrderCancelled(orderId, msg.sender, refundedAmount);

        // Line 47: Return the refunded input amount to caller
        return refundedAmount;
    }
}
