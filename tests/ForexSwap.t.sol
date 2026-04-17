// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Test } from "forge-std/src/Test.sol";
import { console2 } from "forge-std/src/console2.sol";
import { ForexSwap } from "../src/ForexSwap.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { Gaussian } from "../src/libraries/Gaussian.sol";

contract ForexSwapHarness is ForexSwap {
    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 internal constant STRICT_EPS = 1e9;
    uint256 internal constant WAD = 1e18;

    struct SwapDebugTrace {
        bool zeroForOne;
        uint256 amountIn;
        uint256 quoteAmountOut;
        uint256 reserve0Before;
        uint256 reserve1Before;
        uint256 liquidityBefore;
        int256 invariantBefore;
        uint256 xOverLBefore;
        uint256 yOverMuLBefore;
        uint256 hookFeeWad;
        uint256 feeAmount;
        uint256 effectiveIn;
        uint256 postFeeSpecifiedReserve;
        uint256 solvedLiquidity;
        uint256 reserve0After;
        uint256 reserve1After;
        uint256 amountOut;
        int256 invariantAfter;
        uint256 xOverLAfter;
        uint256 yOverMuLAfter;
    }

    struct ResidualDebugTrace {
        uint256 reserve0;
        uint256 reserve1;
        uint256 liquidity;
        uint256 maxReserve1;
        uint256 xNumerator;
        uint256 xDenominator;
        uint256 yNumerator;
        uint256 yDenominator;
        uint256 xOverL;
        uint256 yOverMuL;
        int256 invPhiX;
        int256 invPhiY;
        uint256 effectiveWidth;
        int256 residual;
    }

    constructor(IPoolManager manager) ForexSwap(manager) { }

    function configureTokenDecimalsForTest(uint8 token0Decimals_, uint8 token1Decimals_) external {
        _setTokenScales(token0Decimals_, token1Decimals_);
    }

    function seedState(
        uint256 reserve0,
        uint256 reserve1,
        uint256 liquidityL,
        uint256 supply,
        address holder
    )
        external
    {
        poolState = PoolState({ reserve0: reserve0, reserve1: reserve1, liquidity: liquidityL });
        totalSupply = supply;
        if (holder != address(0) && supply > 0) balanceOf[holder] = supply;
    }

    function seedConsistentState(uint256 reserve0, uint256 liquidityL, uint256 supply, address holder) external {
        uint256 reserve1 = _solveReserve1(reserve0, liquidityL);
        poolState = PoolState({ reserve0: reserve0, reserve1: reserve1, liquidity: liquidityL });
        totalSupply = supply;
        if (holder != address(0) && supply > 0) balanceOf[holder] = supply;
    }

    function quoteExactInput(uint256 amountIn, bool zeroForOne) external view returns (uint256) {
        return zeroForOne ? _quoteExactInput0For1(amountIn) : _quoteExactInput1For0(amountIn);
    }

    function executeExactInput(uint256 amountIn, bool zeroForOne) external returns (uint256) {
        return zeroForOne ? _executeExactInput0For1(amountIn) : _executeExactInput1For0(amountIn);
    }

    function executeExactOutput(uint256 amountOut, bool zeroForOne) external returns (uint256) {
        return zeroForOne ? _executeExactOutput0For1(amountOut) : _executeExactOutput1For0(amountOut);
    }

    function planRemove(uint256 shares) external view returns (uint256 amount0, uint256 amount1, uint256 deltaL) {
        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(shares);
        return (plan.amount0, plan.amount1, plan.deltaL);
    }

    function planBootstrap(
        uint160 sqrtPriceX96,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 shares, uint256 deltaL)
    {
        AddLiquidityPlan memory plan = _planAddLiquidity(
            sqrtPriceX96,
            AddLiquidityParams({
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        return (plan.amount0, plan.amount1, plan.shares, plan.deltaL);
    }

    function planBootstrapFromPrice(
        uint256 priceWad,
        uint256 amount0Desired,
        uint256 amount1Desired
    )
        external
        view
        returns (uint256 amount0, uint256 amount1, uint256 shares, uint256 deltaL)
    {
        AddLiquidityPlan memory plan = _bootstrapPlan(priceWad, amount0Desired, amount1Desired);
        return (plan.amount0, plan.amount1, plan.shares, plan.deltaL);
    }

    function bootstrapRatiosForPrice(uint256 priceWad) external view returns (uint256 xRatio, uint256 yRatio) {
        uint256 mu = logNormalParams.mean;
        uint256 sigma = FullMath.mulDiv(logNormalParams.width, inventoryResponseWad, 1e18);
        uint256 d1 = _d1(priceWad, mu, sigma);
        uint256 d2 = _d2(priceWad, mu, sigma);
        xRatio = 1e18 - _phiWad(_toInt256(d1));
        yRatio = _phiWad(_toInt256(d2));
    }

    function priceWadForXRatio(uint256 xRatio) external view returns (uint256 priceWad) {
        int256 d1 = _invPhiWad(1e18 - xRatio);
        uint256 sigma = FullMath.mulDiv(logNormalParams.width, inventoryResponseWad, 1e18);
        int256 sigmaTerm = _toInt256(FullMath.mulDiv(_abs(d1), sigma, 1e18));
        if (d1 < 0) sigmaTerm = -sigmaTerm;
        int256 exponent = sigmaTerm - _toInt256(FullMath.mulDiv(sigma, sigma, 2e18));
        priceWad = FullMath.mulDiv(logNormalParams.mean, _expWadToUint(exponent), 1e18);
    }

    function enforceBootstrapTailMass(uint256 xRatio, uint256 yRatio) external pure {
        if (xRatio <= STRICT_EPS || yRatio <= STRICT_EPS) revert ForexSwap.DomainExceeded();
    }

    function poolValuePerShare() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 price = this.currentPrice();
        uint256 totalValueInToken1 = (poolState.reserve0 * price) / 1e18 + poolState.reserve1;
        return totalValueInToken1 / totalSupply;
    }

    function poolValuePerShareWad() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 price = this.currentPrice();
        uint256 totalValueInToken1 = (poolState.reserve0 * price) / 1e18 + poolState.reserve1;
        return (totalValueInToken1 * 1e18) / totalSupply;
    }

    // solhint-disable-next-line code-complexity
    function symmetricLocalPriceWad() external view returns (uint256) {
        if (poolState.liquidity == 0) return 0;

        uint256 probe0 = poolState.reserve0 / 10_000;
        if (probe0 < 1e12) probe0 = 1e12;
        uint256 maxProbe0 = poolState.liquidity / 1000;
        if (probe0 > maxProbe0) probe0 = maxProbe0;

        uint256 probe1 = poolState.reserve1 / 10_000;
        if (probe1 < 1e12) probe1 = 1e12;
        uint256 maxProbe1 = _maxReserve1(poolState.liquidity) / 1000;
        if (probe1 > maxProbe1) probe1 = maxProbe1;

        uint256 priceBid = this.currentPrice();
        uint256 priceAsk = priceBid;

        if (probe0 > 0) {
            uint256 out1 = _quoteExactInput0For1(probe0);
            if (out1 > 0) priceBid = (out1 * 1e18) / probe0;
        }

        if (probe1 > 0) {
            uint256 out0 = _quoteExactInput1For0(probe1);
            if (out0 > 0) priceAsk = (probe1 * 1e18) / out0;
        }

        return (priceBid + priceAsk) / 2;
    }

    function symmetricLocalValuePerShareWad() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        uint256 price = this.symmetricLocalPriceWad();
        uint256 totalValueInToken1 = (poolState.reserve0 * price) / 1e18 + poolState.reserve1;
        return (totalValueInToken1 * 1e18) / totalSupply;
    }

    function inStrictDomain() external view returns (bool) {
        if (poolState.liquidity == 0) return true;
        return poolState.reserve0 > 0 && poolState.reserve0 < poolState.liquidity && poolState.reserve1 > 0
            && poolState.reserve1 < (poolState.liquidity * logNormalParams.mean) / 1e18;
    }

    function simulateAddLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        address to
    )
        external
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        AddLiquidityPlan memory plan = _planAddLiquidity(
            SQRT_PRICE_1_1,
            AddLiquidityParams({
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: bytes32(0)
            })
        );

        poolState.reserve0 += plan.amount0;
        poolState.reserve1 += plan.amount1;
        poolState.liquidity += plan.deltaL;
        totalSupply += plan.shares;
        balanceOf[to] += plan.shares;

        return (plan.amount0, plan.amount1, plan.shares);
    }

    function simulateRemoveLiquidity(uint256 shares, address from) external returns (uint256 amount0, uint256 amount1) {
        RemoveLiquidityPlan memory plan = _planRemoveLiquidity(shares);
        balanceOf[from] -= shares;
        totalSupply -= shares;
        poolState.reserve0 -= plan.amount0;
        poolState.reserve1 -= plan.amount1;
        poolState.liquidity -= plan.deltaL;
        return (plan.amount0, plan.amount1);
    }

    function solveReserve1(uint256 reserve0_, uint256 liquidity_) external view returns (uint256) {
        return _solveReserve1(reserve0_, liquidity_);
    }

    function solveReserve0(uint256 reserve1_, uint256 liquidity_) external view returns (uint256) {
        return _solveReserve0(reserve1_, liquidity_);
    }

    function phiInvClosure(uint256 u) external pure returns (int256) {
        return int256(_phiWad(_invPhiWad(u))) - int256(u);
    }

    function residualForState(uint256 reserve0_, uint256 reserve1_, uint256 liquidity_) external view returns (int256) {
        if (liquidity_ == 0) return 0;
        return _residual(reserve0_, reserve1_, liquidity_);
    }

    function strictEps() external pure returns (uint256) {
        return STRICT_EPS;
    }

    function maxReserve1ForLiquidity(uint256 liquidity_) external view returns (uint256) {
        return _maxReserve1(liquidity_);
    }

    function previewPostSwapState(
        uint256 amountIn,
        bool zeroForOne
    )
        external
        view
        returns (uint256 reserve0_, uint256 reserve1_, uint256 liquidity_)
    {
        PoolState memory state = poolState;
        (uint256 hookFeeWad,) = this.quoteHookFee(amountIn, zeroForOne);
        uint256 feeAmount = FullMath.mulDiv(amountIn, hookFeeWad, 1e18);
        uint256 effectiveIn = amountIn - feeAmount;

        if (zeroForOne) {
            uint256 xAfterFee = state.reserve0 + feeAmount;
            liquidity_ = _solveLiquidityFromReserves(xAfterFee, state.reserve1);
            reserve0_ = xAfterFee + effectiveIn;
            reserve1_ = _solveReserve1(reserve0_, liquidity_);
        } else {
            uint256 yAfterFee = state.reserve1 + feeAmount;
            liquidity_ = _solveLiquidityFromReserves(state.reserve0, yAfterFee);
            reserve1_ = yAfterFee + effectiveIn;
            reserve0_ = _solveReserve0(reserve1_, liquidity_);
        }
    }

    function expWadToUint(int256 exponent) external pure returns (uint256) {
        return _expWadToUint(exponent);
    }

    function toInt256(uint256 value) external pure returns (int256) {
        return _toInt256(value);
    }

    function currentPriceExponent() external view returns (int256) {
        return _priceExponent(poolState.reserve0, poolState.liquidity);
    }

    function priceExponent(uint256 reserve0_, uint256 liquidity_) external view returns (int256) {
        return _priceExponent(reserve0_, liquidity_);
    }

    function bootstrapDTerms(
        uint256 priceWad,
        uint256 mu,
        uint256 sigma
    )
        external
        pure
        returns (uint256 d1_, uint256 d2_)
    {
        d1_ = _d1(priceWad, mu, sigma);
        d2_ = _d2(priceWad, mu, sigma);
    }

    function debugExactInput(uint256 amountIn, bool zeroForOne) external view returns (SwapDebugTrace memory trace) {
        PoolState memory state = poolState;
        trace.zeroForOne = zeroForOne;
        trace.amountIn = amountIn;
        trace.reserve0Before = state.reserve0;
        trace.reserve1Before = state.reserve1;
        trace.liquidityBefore = state.liquidity;
        trace.invariantBefore = _residual(state.reserve0, state.reserve1, state.liquidity);

        uint256 maxReserve1Before = _maxReserve1(state.liquidity);
        trace.xOverLBefore = FullMath.mulDiv(state.reserve0, WAD, state.liquidity);
        trace.yOverMuLBefore = FullMath.mulDiv(state.reserve1, WAD, maxReserve1Before);

        trace.hookFeeWad = _computeHookFeeWad(state, amountIn, zeroForOne);
        trace.feeAmount = FullMath.mulDiv(amountIn, trace.hookFeeWad, WAD);
        trace.effectiveIn = amountIn - trace.feeAmount;

        if (zeroForOne) {
            trace.postFeeSpecifiedReserve = state.reserve0 + trace.feeAmount;
            trace.solvedLiquidity = _solveLiquidityFromReserves(trace.postFeeSpecifiedReserve, state.reserve1);
            trace.reserve0After = trace.postFeeSpecifiedReserve + trace.effectiveIn;
            trace.reserve1After = _solveReserve1(trace.reserve0After, trace.solvedLiquidity);
            trace.amountOut = state.reserve1 - trace.reserve1After;
            trace.quoteAmountOut = _quoteExactInput0For1(amountIn);
        } else {
            trace.postFeeSpecifiedReserve = state.reserve1 + trace.feeAmount;
            trace.solvedLiquidity = _solveLiquidityFromReserves(state.reserve0, trace.postFeeSpecifiedReserve);
            trace.reserve1After = trace.postFeeSpecifiedReserve + trace.effectiveIn;
            trace.reserve0After = _solveReserve0(trace.reserve1After, trace.solvedLiquidity);
            trace.amountOut = state.reserve0 - trace.reserve0After;
            trace.quoteAmountOut = _quoteExactInput1For0(amountIn);
        }

        uint256 maxReserve1After = _maxReserve1(trace.solvedLiquidity);
        trace.invariantAfter = _residual(trace.reserve0After, trace.reserve1After, trace.solvedLiquidity);
        trace.xOverLAfter = FullMath.mulDiv(trace.reserve0After, WAD, trace.solvedLiquidity);
        trace.yOverMuLAfter = FullMath.mulDiv(trace.reserve1After, WAD, maxReserve1After);
    }

    function debugResidual(uint256 reserve0_, uint256 reserve1_, uint256 liquidity_)
        external
        view
        returns (ResidualDebugTrace memory trace)
    {
        uint256 maxReserve1_ = _maxReserve1(liquidity_);
        uint256 xOverL_ = FullMath.mulDiv(reserve0_, WAD, liquidity_);
        uint256 yOverMuL_ = FullMath.mulDiv(reserve1_, WAD, maxReserve1_);
        int256 invPhiX_ = _invPhiWad(xOverL_);
        int256 invPhiY_ = _invPhiWad(yOverMuL_);
        uint256 effectiveWidth_ = _effectiveWidth();

        trace = ResidualDebugTrace({
            reserve0: reserve0_,
            reserve1: reserve1_,
            liquidity: liquidity_,
            maxReserve1: maxReserve1_,
            xNumerator: reserve0_ * WAD,
            xDenominator: liquidity_,
            yNumerator: reserve1_ * WAD,
            yDenominator: maxReserve1_,
            xOverL: xOverL_,
            yOverMuL: yOverMuL_,
            invPhiX: invPhiX_,
            invPhiY: invPhiY_,
            effectiveWidth: effectiveWidth_,
            residual: invPhiX_ + invPhiY_ + int256(effectiveWidth_)
        });
    }

    function debugInvPhi(uint256 u) external pure returns (int256) {
        return Gaussian.ppf(int256(u));
    }
}

contract ForexSwapCorrectTest is Test {
    bool internal constant DEBUG = false;
    uint256 internal constant MAX_FUZZ_SEQUENCE_STEPS = 8;

    struct RegressionStep {
        uint256 step;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOut;
        int256 invariantBefore;
        int256 invariantAfter;
        uint256 stepDrift;
        uint256 cumulativeDrift;
    }

    struct TraceState {
        uint256 reserve0;
        uint256 reserve1;
        uint256 liquidity;
        uint256 xOverL;
        uint256 yOverMuL;
        int256 residual;
        uint256 price;
        uint256 valuePerShare;
        uint256 quoted;
        uint256 xReconError;
        uint256 yReconError;
        int256 xClosureError;
        int256 yClosureError;
    }

    ForexSwapHarness internal forexSwap;
    PoolManager internal poolManager;

    address internal alice = address(0x1111);
    address internal attacker = address(0x3333);
    uint256 internal constant DOMAIN_INTERIOR_EPS = 5e16;
    uint256 internal constant INVARIANT_DRIFT_ABS_TOLERANCE = 8e1;
    uint256 internal constant INVARIANT_DRIFT_REL_TOLERANCE = 8e1;
    uint256 internal constant MULTI_SWAP_DRIFT_ABS_TOLERANCE = 8e1;
    uint256 internal constant MULTI_SWAP_DRIFT_REL_TOLERANCE = 8e1;
    uint256 internal constant ROUND_TRIP_STATE_ABS_TOLERANCE = 5e12;
    function setUp() public {
        poolManager = new PoolManager(address(this));
        bytes memory initCode = abi.encodePacked(type(ForexSwapHarness).creationCode, abi.encode(poolManager));
        bytes32 initCodeHash = keccak256(initCode);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes32 minedHookSalt = _mineHookSalt(initCodeHash, flags);
        address predicted = vm.computeCreate2Address(minedHookSalt, initCodeHash, address(this));
        if ((uint160(predicted) & ((1 << 14) - 1)) != flags) revert("invalid mined hook salt");
        forexSwap = new ForexSwapHarness{ salt: minedHookSalt }(poolManager);
    }

    function _mineHookSalt(bytes32 initCodeHash, uint160 flags) internal view returns (bytes32 salt) {
        for (uint256 candidate = 0; candidate < type(uint24).max; candidate++) {
            salt = bytes32(candidate);
            address predicted = vm.computeCreate2Address(salt, initCodeHash, address(this));
            if ((uint160(predicted) & ((1 << 14) - 1)) == flags) return salt;
        }

        revert("hook salt not found");
    }

    function _seedBalancedPool() internal {
        forexSwap.seedConsistentState(4e17, 1e18, 1e18, alice);
    }

    function test_owner() external view {
        assertEq(forexSwap.owner(), address(this));
    }

    function test_pauseFunctionality() external {
        forexSwap.emergencyPause();
        assertTrue(forexSwap.paused());

        forexSwap.emergencyUnpause();
        assertFalse(forexSwap.paused());
    }

    function test_updateLogNormalParams() external {
        forexSwap.updateLogNormalParams(12e17, 3e17, 4e15);
        (uint256 mu, uint256 sigma, uint256 baseHookFeeWad) = forexSwap.logNormalParams();
        assertEq(mu, 12e17);
        assertEq(sigma, 3e17);
        assertEq(baseHookFeeWad, 4e15);
    }

    function test_quoteHookFeeIncludesConfiguredInventoryAndVolatilityComponents() external {
        _seedBalancedPool();

        forexSwap.updateHookFeeModel(2e16, 5e17, 0, 9e16);
        forexSwap.setRealizedVolatilityWad(3e16);

        (uint256 hookFeeWad, uint256 hookFeeAmount) = forexSwap.quoteHookFee(1e18, true);

        assertGt(hookFeeWad, 3e15);
        assertEq(hookFeeAmount, (1e18 * hookFeeWad) / 1e18);
    }

    function test_updateInventoryResponseWad() external {
        forexSwap.updateInventoryResponseWad(5e17);
        assertEq(forexSwap.inventoryResponseWad(), 5e17);
    }

    function test_inventorySkewIncreasesFeeForImbalanceWorseningSide() external {
        forexSwap.seedState(9e17, 1e17, 1e18, 1e18, alice);
        forexSwap.updateHookFeeModel(5e16, 0, 0, 9e16);
        forexSwap.updateInventorySkewWad(5e17);

        (uint256 feeZeroForOne,) = forexSwap.quoteHookFee(1e16, true);
        (uint256 feeOneForZero,) = forexSwap.quoteHookFee(1e16, false);

        assertGt(feeZeroForOne, feeOneForZero);
    }

    function test_maxTradeSizeGuardRevertsWhenExceeded() external {
        _seedBalancedPool();
        forexSwap.updateMaxTradeSizeWad(1e16);

        vm.expectRevert(ForexSwap.MaxTradeSizeExceeded.selector);
        forexSwap.calculateAmountOut(5e16, true);
    }

    function test_staleAnchorGuardPausesTradingWhenConfigured() external {
        _seedBalancedPool();
        forexSwap.updateAnchorGuard(1, true, 0);
        vm.warp(block.timestamp + 2);

        vm.expectRevert(ForexSwap.StaleAnchor.selector);
        forexSwap.calculateAmountOut(1e16, true);
    }

    function test_staleAnchorEmergencyWidenAppliesWhenPauseDisabled() external {
        _seedBalancedPool();

        (uint256 feeBefore,) = forexSwap.quoteHookFee(1e16, true);
        forexSwap.updateAnchorGuard(1, false, 2e16);
        vm.warp(block.timestamp + 2);
        (uint256 feeAfter,) = forexSwap.quoteHookFee(1e16, true);

        assertGt(feeAfter, feeBefore);
    }

    function test_anchorTimestampUpdatesOnMarketParamUpdateAndManualTouch() external {
        uint256 initialAnchorUpdatedAt = forexSwap.anchorUpdatedAt();

        vm.warp(block.timestamp + 10);
        forexSwap.updateLogNormalParams(12e17, 3e17, 4e15);
        uint256 afterParamUpdate = forexSwap.anchorUpdatedAt();
        assertGt(afterParamUpdate, initialAnchorUpdatedAt);
        assertEq(afterParamUpdate, block.timestamp);

        vm.warp(block.timestamp + 10);
        forexSwap.updateAnchorTimestamp();
        assertEq(forexSwap.anchorUpdatedAt(), block.timestamp);
    }

    function test_mixedDecimalsSixAndEighteenPreserveRawFacingQuotes() external {
        _seedBalancedPool();

        (uint256 reserve0Normalized, uint256 reserve1Normalized, uint256 liquidityNormalized) = forexSwap.poolState();
        uint256 priceNormalized = forexSwap.currentPrice();

        uint256 zeroForOneInNormalized = 5e16;
        uint256 oneForZeroInNormalized = 2e17;
        uint256 zeroForOneOutNormalized = forexSwap.calculateAmountOut(zeroForOneInNormalized, true);
        uint256 oneForZeroOutNormalized = forexSwap.calculateAmountOut(oneForZeroInNormalized, false);
        vm.pauseGasMetering();
        uint256 zeroForOnePreviewNormalized = forexSwap.previewExactOutput(1e17, true);
        uint256 oneForZeroPreviewNormalized = forexSwap.previewExactOutput(5e16, false);
        vm.resumeGasMetering();

        forexSwap.configureTokenDecimalsForTest(6, 18);

        (uint256 reserve0Raw, uint256 reserve1Raw,,,) = forexSwap.getPoolInfo();
        assertEq(reserve0Raw, reserve0Normalized / 1e12);
        assertEq(reserve1Raw, reserve1Normalized);
        assertEq(forexSwap.currentPrice(), priceNormalized);
        (,, uint256 liquidityAfterScaling) = forexSwap.poolState();
        assertEq(liquidityAfterScaling, liquidityNormalized);

        uint256 zeroForOneOutRaw = forexSwap.calculateAmountOut(zeroForOneInNormalized / 1e12, true);
        uint256 oneForZeroOutRaw = forexSwap.calculateAmountOut(oneForZeroInNormalized, false);
        assertEq(zeroForOneOutRaw, zeroForOneOutNormalized);
        assertEq(oneForZeroOutRaw, oneForZeroOutNormalized / 1e12);

        vm.pauseGasMetering();
        uint256 zeroForOnePreviewRaw = forexSwap.previewExactOutput(1e17, true);
        uint256 oneForZeroPreviewRaw = forexSwap.previewExactOutput(5e16 / 1e12, false);
        vm.resumeGasMetering();
        assertEq(zeroForOnePreviewRaw, ((zeroForOnePreviewNormalized - 1) / 1e12) + 1);
        assertEq(oneForZeroPreviewRaw, oneForZeroPreviewNormalized);
    }

    function test_bootstrapPlanUsesPoolPriceAndReturnsLPShares() external view {
        (uint256 amount0, uint256 amount1, uint256 shares, uint256 deltaL) =
            forexSwap.planBootstrap(79_228_162_514_264_337_593_543_950_336, 4e17, 5e17);

        assertEq(amount0, 4e17);
        assertGt(amount1, 0);
        assertEq(shares, deltaL);
        assertGt(deltaL, 0);
    }

    function test_bootstrapPlanRejectsNearZeroXRatio() external {
        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.planBootstrap(type(uint160).max, 1e18, type(uint128).max);
    }

    function test_bootstrapTailMassGuardRejectsXRatioBelowOrAtEps() external {
        uint256 eps = forexSwap.strictEps();

        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.enforceBootstrapTailMass(eps - 1, 5e17);

        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.enforceBootstrapTailMass(eps, 5e17);
    }

    function test_bootstrapTailMassGuardAcceptsXRatioAboveEps() external view {
        uint256 eps = forexSwap.strictEps();
        forexSwap.enforceBootstrapTailMass(eps + 1, 5e17);
    }

    function test_bootstrapTailMassGuardRejectsYRatioBelowOrAtEps() external {
        uint256 eps = forexSwap.strictEps();

        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.enforceBootstrapTailMass(5e17, eps - 1);

        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.enforceBootstrapTailMass(5e17, eps);
    }

    function test_bootstrapTailMassGuardAcceptsYRatioAboveEps() external view {
        uint256 eps = forexSwap.strictEps();
        forexSwap.enforceBootstrapTailMass(5e17, eps + 1);
    }

    function test_bootstrapAmount0PathLiquidityAmplificationIsBoundedByXRatioFloor() external view {
        uint256 eps = forexSwap.strictEps();
        uint256 targetXRatio = eps + 1;
        uint256 priceWad = forexSwap.priceWadForXRatio(targetXRatio);
        (uint256 xRatio,) = forexSwap.bootstrapRatiosForPrice(priceWad);

        assertGt(xRatio, eps);

        uint256 amount0Desired = 1e18;
        (uint256 amount0,,, uint256 deltaL) =
            forexSwap.planBootstrapFromPrice(priceWad, amount0Desired, type(uint128).max);

        assertEq(amount0, amount0Desired);
        assertLe(deltaL, FullMath.mulDiv(amount0Desired, 1e18, eps));
    }

    function test_stableBootstrapPreservesRequestedAmountsForSixDecimalPair() external {
        forexSwap.configureTokenDecimalsForTest(6, 6);

        uint256 anchorCngnPerUsdcWad = 1_380_349_891_090_393_592_967;
        (, uint256 width, uint256 baseHookFeeWad) = forexSwap.logNormalParams();
        forexSwap.updateLogNormalParams(anchorCngnPerUsdcWad, width, baseHookFeeWad);

        uint256 amount0Desired = 579_560 * 1e12;
        uint256 amount1Desired = 800_000_000 * 1e12;
        (uint256 amount0, uint256 amount1,,) =
            forexSwap.planBootstrapFromPrice(anchorCngnPerUsdcWad, amount0Desired, amount1Desired);

        assertEq(amount0, amount0Desired);
        assertEq(amount1, amount1Desired);
    }

    function test_stableBootstrapRevertsWhenNearAnchorRequestWouldClipTooMuch() external {
        forexSwap.configureTokenDecimalsForTest(6, 6);

        uint256 anchorCngnPerUsdcWad = 1_380_349_891_090_393_592_967;
        (, uint256 width, uint256 baseHookFeeWad) = forexSwap.logNormalParams();
        forexSwap.updateLogNormalParams(anchorCngnPerUsdcWad, width, baseHookFeeWad);

        vm.expectRevert(ForexSwap.BootstrapClipTooLarge.selector);
        forexSwap.planBootstrapFromPrice(anchorCngnPerUsdcWad, 579_560 * 1e12, 808_000_000 * 1e12);
    }

    function test_quoteAndExecuteExactInputZeroForOneMoveState() external {
        _seedBalancedPool();

        uint256 quote = forexSwap.quoteExactInput(1e16, true);
        assertGt(quote, 0);

        uint256 beforeReserve0;
        uint256 beforeReserve1;
        uint256 beforeLiquidity;
        (beforeReserve0, beforeReserve1, beforeLiquidity,) = _state();

        uint256 amountOut = forexSwap.executeExactInput(1e16, true);
        assertEq(amountOut, quote);

        (uint256 reserve0, uint256 reserve1, uint256 liquidityL,) = _state();
        assertEq(reserve0, beforeReserve0 + 1e16);
        assertEq(reserve1 + amountOut, beforeReserve1);
        assertGe(liquidityL, beforeLiquidity);
    }

    function test_quoteAndExecuteExactInputOneForZeroMoveState() external {
        _seedBalancedPool();

        uint256 quote = forexSwap.quoteExactInput(1e16, false);
        assertGt(quote, 0);

        uint256 beforeReserve0;
        uint256 beforeReserve1;
        uint256 beforeLiquidity;
        (beforeReserve0, beforeReserve1, beforeLiquidity,) = _state();

        uint256 amountOut = forexSwap.executeExactInput(1e16, false);
        assertEq(amountOut, quote);

        (uint256 reserve0, uint256 reserve1, uint256 liquidityL,) = _state();
        assertEq(reserve1, beforeReserve1 + 1e16);
        assertEq(reserve0 + amountOut, beforeReserve0);
        assertGe(liquidityL, beforeLiquidity);
    }

    function test_previewExactOutputZeroForOneReturnsLeastInput() external {
        _seedBalancedPool();

        uint256 targetOut = 1e16;
        uint256 amountIn = forexSwap.previewExactOutput(targetOut, true);

        assertGe(forexSwap.quoteExactInput(amountIn, true), targetOut);
        assertLt(forexSwap.quoteExactInput(amountIn - 1, true), targetOut);
    }

    function test_previewExactOutputOneForZeroReturnsLeastInput() external {
        _seedBalancedPool();

        uint256 targetOut = 1e16;
        uint256 amountIn = forexSwap.previewExactOutput(targetOut, false);

        assertGe(forexSwap.quoteExactInput(amountIn, false), targetOut);
        assertLt(forexSwap.quoteExactInput(amountIn - 1, false), targetOut);
    }

    function test_removePlanScalesWithShares() external {
        _seedBalancedPool();

        (uint256 amount0, uint256 amount1, uint256 deltaL) = forexSwap.planRemove(5e17);
        (uint256 reserve0, uint256 reserve1, uint256 liquidityL,) = _state();

        assertEq(deltaL, 5e17);
        assertEq(amount0, reserve0 / 2);
        assertEq(amount1, reserve1 / 2);
        assertEq(deltaL, liquidityL / 2);
    }

    function test_currentInvariantIsNearZeroOnSeededState() external {
        _seedBalancedPool();
        int256 invariantValue = forexSwap.currentInvariant();
        assertApproxEqAbs(invariantValue, 0, 1e15);
    }

    function test_tailSensitiveReadsRejectNearBoundaryState() external {
        uint256 liquidityL = 1e18;
        uint256 eps = forexSwap.strictEps();
        uint256 reserve0 = liquidityL - eps;
        uint256 reserve1 = forexSwap.maxReserve1ForLiquidity(liquidityL) - eps;

        forexSwap.seedState(reserve0, reserve1, liquidityL, 1e18, alice);

        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.currentPrice();

        vm.expectRevert(ForexSwap.DomainExceeded.selector);
        forexSwap.currentInvariant();
    }

    function test_expWadToUintRejectsExponentBelowBound() external {
        vm.expectRevert(ForexSwap.ExponentOutOfBounds.selector);
        forexSwap.expWadToUint(-20e18 - 1);
    }

    function test_expWadToUintRejectsExponentAboveBound() external {
        vm.expectRevert(ForexSwap.ExponentOutOfBounds.selector);
        forexSwap.expWadToUint(20e18 + 1);
    }

    function test_toInt256RejectsOverflow() external {
        vm.expectRevert(ForexSwap.Int256CastOverflow.selector);
        forexSwap.toInt256(uint256(type(int256).max) + 1);
    }

    function test_checkedCastsAcceptBoundaryValues() external view {
        uint256 minExp = forexSwap.expWadToUint(-20e18);
        assertGt(minExp, 0);
        assertLt(minExp, 1e18);
        assertEq(forexSwap.expWadToUint(0), 1e18);
        assertEq(forexSwap.toInt256(uint256(type(int256).max)), type(int256).max);
    }

    function test_expWadRemainsContinuousJustInsideBounds() external view {
        int256 delta = 1e14;

        uint256 upperNear = forexSwap.expWadToUint(20e18 - delta);
        uint256 upperEdge = forexSwap.expWadToUint(20e18);
        assertGt(upperEdge, upperNear);
        assertApproxEqRel(upperEdge, upperNear, 2e14);

        uint256 lowerEdge = forexSwap.expWadToUint(-20e18);
        uint256 lowerNear = forexSwap.expWadToUint(-20e18 + delta);
        assertGt(lowerNear, lowerEdge);
        assertApproxEqRel(lowerNear, lowerEdge, 2e14);
    }

    function test_feeAccrualDoesNotReducePoolValuePerShare_zeroForOne() external {
        _seedBalancedPool();

        uint256 beforeValuePerShare = forexSwap.poolValuePerShare();
        forexSwap.executeExactInput(1e16, true);
        uint256 afterValuePerShare = forexSwap.poolValuePerShare();

        assertGe(afterValuePerShare, beforeValuePerShare);
    }

    function test_feeAccrualDoesNotReducePoolValuePerShare_oneForZero() external {
        _seedBalancedPool();

        uint256 beforeValuePerShare = forexSwap.poolValuePerShare();
        forexSwap.executeExactInput(1e16, false);
        uint256 afterValuePerShare = forexSwap.poolValuePerShare();

        assertGe(afterValuePerShare, beforeValuePerShare);
    }

    function testFuzz_feeAccrualDoesNotReducePoolValuePerShare_zeroForOne(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 5e17, 5e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 10, (liquidityL * 8) / 10);
        uint256 amountIn = bound(amountInSeed, 1e15, liquidityL / 50);

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 beforeValuePerShare = forexSwap.poolValuePerShare();
        uint256 quoted = forexSwap.quoteExactInput(amountIn, true);
        vm.assume(quoted > 0);

        forexSwap.executeExactInput(amountIn, true);
        uint256 afterValuePerShare = forexSwap.poolValuePerShare();

        assertGe(afterValuePerShare + 1, beforeValuePerShare);
    }

    function testFuzz_feeAccrualDoesNotReducePoolValuePerShare_oneForZero(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 5e17, 5e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 10, (liquidityL * 8) / 10);
        uint256 amountIn = bound(amountInSeed, 1e15, liquidityL / 50);

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 beforeValuePerShare = forexSwap.poolValuePerShare();
        uint256 quoted = forexSwap.quoteExactInput(amountIn, false);
        vm.assume(quoted > 0);

        forexSwap.executeExactInput(amountIn, false);
        uint256 afterValuePerShare = forexSwap.poolValuePerShare();

        assertGe(afterValuePerShare + 1, beforeValuePerShare);
    }

    function testFuzz_previewExactOutputZeroForOneReturnsLeastInput(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 5e17, 5e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 10, (liquidityL * 8) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 quotedOut = forexSwap.quoteExactInput(bound(amountInSeed, 1e15, liquidityL / 50), true);
        vm.assume(quotedOut > 1);

        uint256 targetOut = bound(amountInSeed >> 16, 1, quotedOut - 1);
        try forexSwap.previewExactOutput(targetOut, true) returns (uint256 amountIn) {
            assertGe(forexSwap.quoteExactInput(amountIn, true), targetOut);
            assertLt(forexSwap.quoteExactInput(amountIn - 1, true), targetOut);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ForexSwap.NonMonotonicQuote.selector);
        }
    }

    function testFuzz_previewExactOutputOneForZeroReturnsLeastInput(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 5e17, 5e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 10, (liquidityL * 8) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 quotedOut = forexSwap.quoteExactInput(bound(amountInSeed, 1e15, liquidityL / 50), false);
        vm.assume(quotedOut > 1);

        uint256 targetOut = bound(amountInSeed >> 16, 1, quotedOut - 1);
        try forexSwap.previewExactOutput(targetOut, false) returns (uint256 amountIn) {
            assertGe(forexSwap.quoteExactInput(amountIn, false), targetOut);
            assertLt(forexSwap.quoteExactInput(amountIn - 1, false), targetOut);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ForexSwap.NonMonotonicQuote.selector);
        }
    }

    function test_previewExactOutputMatchesBoundedOracle_zeroForOne() external {
        forexSwap.updateInventoryResponseWad(1e18);
        uint256[4] memory liquidityCases = [uint256(4_000_000_000), 7_500_000_000, 12_000_000_000, 20_000_000_000];
        uint256[4] memory reserveBps = [uint256(3000), 4000, 6000, 7400];
        uint256[4] memory targetBps = [uint256(1000), 2500, 5000, 7500];

        for (uint256 i = 0; i < liquidityCases.length; ++i) {
            uint256 reserve0 = FullMath.mulDiv(liquidityCases[i], reserveBps[i], 10_000);
            _assertPreviewOracleMatchesBoundedScan(reserve0, liquidityCases[i], targetBps[i], true);
        }
    }

    function test_previewExactOutputMatchesBoundedOracle_oneForZero() external {
        forexSwap.updateInventoryResponseWad(1e18);
        uint256[4] memory liquidityCases = [uint256(4_500_000_000), 8_000_000_000, 13_000_000_000, 18_000_000_000];
        uint256[4] memory reserveBps = [uint256(3000), 4500, 5500, 7000];
        uint256[4] memory targetBps = [uint256(1250), 3000, 5500, 7000];

        for (uint256 i = 0; i < liquidityCases.length; ++i) {
            uint256 reserve0 = FullMath.mulDiv(liquidityCases[i], reserveBps[i], 10_000);
            _assertPreviewOracleMatchesBoundedScan(reserve0, liquidityCases[i], targetBps[i], false);
        }
    }

    function testFuzz_repeatedSwapsPreserveDomainInvariantAndClosure(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 randomness
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 1 + (stateRand % MAX_FUZZ_SEQUENCE_STEPS);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;

            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 quoted) {
                if (quoted == 0) continue;
            } catch {
                continue;
            }

            forexSwap.executeExactInput(amountIn, zeroForOne);

            assertTrue(forexSwap.inStrictDomain());
            assertApproxEqAbs(forexSwap.currentInvariant(), 0, 2e16);
        }
    }

    function testFuzz_singleSwapInvariantDriftStaysWithinTolerance(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed,
        bool zeroForOne
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        uint256 amountIn = bound(amountInSeed, 1e15, liquidityL / 50);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        _assumeInteriorState();

        uint256 quoted;
        try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
            quoted = q;
        } catch {
            return;
        }

        vm.assume(quoted > 0);

        int256 invariantBefore = forexSwap.currentInvariant();
        forexSwap.executeExactInput(amountIn, zeroForOne);
        int256 invariantAfter = forexSwap.currentInvariant();

        assertTrue(forexSwap.inStrictDomain());
        _assertInvariantDriftWithinTolerance(
            invariantBefore, invariantAfter, INVARIANT_DRIFT_ABS_TOLERANCE, INVARIANT_DRIFT_REL_TOLERANCE
        );
    }

    function testFuzz_repeatedSwapInvariantDriftStaysBounded(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 randomness
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        _assumeInteriorState();

        int256 invariantStart = forexSwap.currentInvariant();
        uint256 stateRand = randomness;
        uint256 steps = 1 + (stateRand % MAX_FUZZ_SEQUENCE_STEPS);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;

            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quoted;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quoted = q;
            } catch {
                continue;
            }
            if (quoted == 0) continue;

            int256 invariantBefore = forexSwap.currentInvariant();
            forexSwap.executeExactInput(amountIn, zeroForOne);
            int256 invariantAfter = forexSwap.currentInvariant();

            assertTrue(forexSwap.inStrictDomain());
            _assumeInteriorState();
            _assertInvariantDriftWithinTolerance(
                invariantBefore, invariantAfter, INVARIANT_DRIFT_ABS_TOLERANCE, INVARIANT_DRIFT_REL_TOLERANCE
            );
        }

        _assertInvariantDriftWithinTolerance(
            invariantStart, forexSwap.currentInvariant(), MULTI_SWAP_DRIFT_ABS_TOLERANCE, MULTI_SWAP_DRIFT_REL_TOLERANCE
        );
    }

    function test_regression_repeatedSwapInvariantDriftCounterexample_reproduces() external {
        RegressionStep[] memory steps = _runRepeatedSwapRegression(0, 949000000000000000, 5181, false);
        assertGt(steps.length, 0);
        assertLe(steps[steps.length - 1].cumulativeDrift, MULTI_SWAP_DRIFT_ABS_TOLERANCE);
    }

    function test_regression_repeatedSwapInvariantDriftCounterexample_logsMirroredDirections() external {
        RegressionStep[] memory original = _runRepeatedSwapRegression(0, 949000000000000000, 5181, false);
        RegressionStep[] memory mirrored = _runRepeatedSwapRegression(0, 949000000000000000, 5181, true);

        assertGt(original.length, 0);
        assertGt(mirrored.length, 0);
    }

    function test_regression_step5Breakpoint_comparesOriginalAndMirroredBranches() external {
        ForexSwapHarness.SwapDebugTrace memory original = _runSingleStepTrace(
            589752028654710713,
            7302924914036034875,
            7950518664194677420,
            2333902037713231,
            true,
            "original-step5"
        );

        ForexSwapHarness.SwapDebugTrace memory mirrored = _runSingleStepTrace(
            1452108153087453701,
            6390912892028131150,
            7950662719889184434,
            119675782481879747,
            false,
            "mirrored-step5"
        );

        uint256 originalStepDrift = _absDiffInt(original.invariantBefore, original.invariantAfter);
        uint256 mirroredStepDrift = _absDiffInt(mirrored.invariantBefore, mirrored.invariantAfter);

        console2.log("step5DriftOriginal", originalStepDrift);
        console2.log("step5DriftMirrored", mirroredStepDrift);

        _logRootNeighborhood(
            "original-step5-reserve1",
            original.reserve0After,
            original.reserve1After,
            original.solvedLiquidity,
            false
        );
        _logRootNeighborhood(
            "mirrored-step5-reserve0",
            mirrored.reserve0After,
            mirrored.reserve1After,
            mirrored.solvedLiquidity,
            true
        );
        _logLiquidityNeighborhood(
            "original-step5-liquidity",
            original.reserve0Before,
            original.postFeeSpecifiedReserve,
            original.solvedLiquidity,
            true
        );
        _logLiquidityNeighborhood(
            "mirrored-step5-liquidity",
            mirrored.postFeeSpecifiedReserve,
            mirrored.reserve1Before,
            mirrored.solvedLiquidity,
            false
        );

        assertEq(original.quoteAmountOut, original.amountOut);
        assertEq(mirrored.quoteAmountOut, mirrored.amountOut);
        assertLe(originalStepDrift, INVARIANT_DRIFT_ABS_TOLERANCE);
        assertLe(mirroredStepDrift, INVARIANT_DRIFT_ABS_TOLERANCE);
    }

    function test_regression_step5ResidualNeighborhood_logsQuantization() external view {
        _logResidualNeighborhood(
            "original-step5-post",
            592085930692423944,
            7300426882874174262,
            7950526194903969864,
            false
        );
        _logResidualNeighborhood(
            "mirrored-step5-post",
            1338086839264135567,
            6510588674510010897,
            7951023667346455306,
            true
        );
    }

    function test_regression_step5InvPhiNeighborhood_logsDirectPpfSlope() external view {
        _logInvPhiNeighborhood("original-y", 918231913700694649);
        _logInvPhiNeighborhood("mirrored-x", 168291140266559366);
    }

    function test_regression_gaussianPpf_isMonotoneOnStep5BreakpointNeighborhood() external view {
        uint256 u = 918231913700694649;
        int256 below = forexSwap.debugInvPhi(u - 1);
        int256 exact = forexSwap.debugInvPhi(u);
        int256 above = forexSwap.debugInvPhi(u + 1);

        assertLe(below, exact);
        assertLe(exact, above);
    }

    function test_regression_gaussianPpf_isMonotoneOnLocalSweepAroundStep5Breakpoint() external view {
        uint256 center = 918231913700694649;
        int256 previous = forexSwap.debugInvPhi(center - 32);

        for (uint256 i = 31; i > 0; --i) {
            uint256 u = center - i;
            int256 current = forexSwap.debugInvPhi(u);
            assertLe(previous, current);
            previous = current;
        }

        int256 exact = forexSwap.debugInvPhi(center);
        assertLe(previous, exact);
        previous = exact;

        for (uint256 i = 1; i <= 32; ++i) {
            uint256 u = center + i;
            int256 current = forexSwap.debugInvPhi(u);
            assertLe(previous, current);
            previous = current;
        }
    }

    function testFuzz_previewAndExecuteInvariantDriftStayConsistent(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed,
        bool zeroForOne
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        uint256 amountIn = bound(amountInSeed, 1e15, liquidityL / 50);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        _assumeInteriorState();

        uint256 quoted;
        try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
            quoted = q;
        } catch {
            return;
        }
        vm.assume(quoted > 0);

        int256 invariantBefore = forexSwap.currentInvariant();
        (uint256 previewReserve0, uint256 previewReserve1, uint256 previewLiquidity) =
            forexSwap.previewPostSwapState(amountIn, zeroForOne);
        int256 previewInvariantAfter = forexSwap.residualForState(previewReserve0, previewReserve1, previewLiquidity);

        forexSwap.executeExactInput(amountIn, zeroForOne);
        int256 actualInvariantAfter = forexSwap.currentInvariant();

        assertTrue(forexSwap.inStrictDomain());
        _assertInvariantDriftWithinTolerance(
            previewInvariantAfter, actualInvariantAfter, INVARIANT_DRIFT_ABS_TOLERANCE, INVARIANT_DRIFT_REL_TOLERANCE
        );
        assertLe(
            _absDiffInt(invariantBefore, actualInvariantAfter),
            _absDiffInt(invariantBefore, previewInvariantAfter) + INVARIANT_DRIFT_ABS_TOLERANCE
        );
    }

    function testFuzz_roundTripSwapReturnsStateNearBaseline(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 amountInSeed,
        bool zeroForOne
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        _assumeInteriorState();

        (uint256 mean, uint256 sigma,) = forexSwap.logNormalParams();
        forexSwap.updateLogNormalParams(mean, sigma, 0);

        (,, uint256 baseLiquidity,) = _state();
        uint256 amountIn = bound(amountInSeed, 1e15, baseLiquidity / 50);
        try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 quoted) {
            vm.assume(quoted > 0);
        } catch {
            return;
        }
        uint256[3] memory baseline;
        (baseline[0], baseline[1], baseline[2],) = _state();
        int256 invariantBefore = forexSwap.currentInvariant();

        forexSwap.executeExactInput(amountIn, zeroForOne);

        uint256 unwindInput;
        try forexSwap.previewExactOutput(amountIn, !zeroForOne) returns (uint256 previewedInput) {
            unwindInput = previewedInput;
        } catch {
            return;
        }
        vm.assume(unwindInput > 0);
        uint256 unwindOutput = forexSwap.executeExactInput(unwindInput, !zeroForOne);
        assertGe(unwindOutput, amountIn);
        _assertRoundTripNearBaseline(baseline, invariantBefore);
    }

    function test_invariantTelemetryLogsWorstObservedDrift() external {
        vm.pauseGasMetering();
        uint256[4] memory reserve0Seeds = [uint256(2e17), 35e16, 5e17, 65e16];
        uint256[4] memory liquiditySeeds = [uint256(1e18), 2e18, 4e18, 8e18];

        uint256 maxStepDrift;
        uint256 maxCumulativeDrift;
        uint256 maxPreviewGap;

        for (uint256 scenario = 0; scenario < reserve0Seeds.length; ++scenario) {
            forexSwap.seedConsistentState(reserve0Seeds[scenario], liquiditySeeds[scenario], 1e18, alice);
            assertTrue(_isInteriorState());

            int256 invariantStart = forexSwap.currentInvariant();
            uint256 stateRand =
                uint256(keccak256(abi.encode(scenario, reserve0Seeds[scenario], liquiditySeeds[scenario])));
            uint256 steps = 20;

            for (uint256 i = 0; i < steps; ++i) {
                stateRand = uint256(keccak256(abi.encode(stateRand, i)));
                bool zeroForOne = (stateRand & 1) == 0;

                (,, uint256 currentLiquidity,) = _state();
                uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);
                (bool executed, uint256 stepDrift, uint256 cumulativeDrift, uint256 previewGap) =
                    _executeSwapAndMeasure(amountIn, zeroForOne, invariantStart);
                if (!executed) continue;

                if (stepDrift > maxStepDrift) maxStepDrift = stepDrift;
                if (cumulativeDrift > maxCumulativeDrift) maxCumulativeDrift = cumulativeDrift;
                if (previewGap > maxPreviewGap) maxPreviewGap = previewGap;

                assertTrue(forexSwap.inStrictDomain());
                if (!_isInteriorState()) break;
            }
        }

        console2.log("maxStepDrift", maxStepDrift);
        console2.log("maxCumulativeDrift", maxCumulativeDrift);
        console2.log("maxPreviewExecuteGap", maxPreviewGap);
        vm.resumeGasMetering();
    }

    function test_previewExactOutputBoundaryHarness_zeroForOne_logsFrontierAndMonotonicity() external {
        _runPreviewBoundaryHarness(true);
    }

    function test_previewExactOutputBoundaryHarness_oneForZero_logsFrontierAndMonotonicity() external {
        _runPreviewBoundaryHarness(false);
    }

    function _runPreviewBoundaryHarness(bool zeroForOne) internal {
        vm.pauseGasMetering();
        uint256 liquidityL = 1e18;
        uint256[4] memory xRatios = [uint256(5.1e16), 6e16, 94e16, 94.9e16];
        console2.log("--- preview frontier dir ---", zeroForOne ? 0 : 1);

        for (uint256 s = 0; s < xRatios.length; ++s) {
            uint256 reserve0 = FullMath.mulDiv(liquidityL, xRatios[s], 1e18);
            try this.logPreviewBoundaryCaseExternal(s, reserve0, liquidityL, zeroForOne) { }
            catch {
                console2.log("state", s);
                console2.log("stateProbeReverted");
            }
        }
        vm.resumeGasMetering();
    }

    function logPreviewBoundaryCaseExternal(
        uint256 stateIndex,
        uint256 reserve0,
        uint256 liquidityL,
        bool zeroForOne
    )
        external
    {
        uint256[4] memory targetBps = [uint256(1), 5, 25, 100];
        _logPreviewBoundaryCase(stateIndex, reserve0, liquidityL, targetBps, zeroForOne);
    }

    function testFuzz_addRemoveRoundTripDoesNotCreateValue(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 addSeed
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        (uint256 startReserve0, uint256 startReserve1,,) = _state();
        uint256 add0 = bound(addSeed, 1e15, startReserve0 / 20);
        uint256 add1 = (startReserve1 * add0) / startReserve0;

        uint256 startPrice = forexSwap.currentPrice();
        (uint256 spent0, uint256 spent1, uint256 shares) = forexSwap.simulateAddLiquidity(add0, add1, attacker);
        (uint256 out0, uint256 out1) = forexSwap.simulateRemoveLiquidity(shares, attacker);

        uint256 spentValue = (spent0 * startPrice) / 1e18 + spent1;
        uint256 receivedValue = (out0 * startPrice) / 1e18 + out1;

        assertLe(receivedValue, spentValue + 1e12);
        assertTrue(forexSwap.inStrictDomain());
    }

    function testFuzz_swapAddSwapRemoveCycleDoesNotCreateLargeWindfall(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 swapSeed1,
        uint256 addSeed,
        uint256 swapSeed2
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        {
            bool firstZeroForOne = (swapSeed1 & 1) == 0;
            uint256 firstAmountIn = bound(swapSeed1 >> 8, 1e15, liquidityL / 50);
            try forexSwap.quoteExactInput(firstAmountIn, firstZeroForOne) returns (uint256 quoted1) {
                vm.assume(quoted1 > 0);
                forexSwap.executeExactInput(firstAmountIn, firstZeroForOne);
            } catch {
                return;
            }
        }

        (uint256 reserve0AfterFirst, uint256 reserve1AfterFirst,,) = _state();
        uint256 add0 = bound(addSeed, 1e15, reserve0AfterFirst / 25);
        uint256 add1 = (reserve1AfterFirst * add0) / reserve0AfterFirst;
        (uint256 spent0, uint256 spent1, uint256 shares) = forexSwap.simulateAddLiquidity(add0, add1, attacker);

        bool secondZeroForOne = (swapSeed2 & 1) == 0;
        uint256 secondAmountIn;
        uint256 beforeSecondPrice = forexSwap.currentPrice();
        {
            (,, uint256 liqBeforeSecond,) = _state();
            secondAmountIn = bound(swapSeed2 >> 8, 1e15, liqBeforeSecond / 50);
            try forexSwap.quoteExactInput(secondAmountIn, secondZeroForOne) returns (uint256 quoted2) {
                vm.assume(quoted2 > 0);
                forexSwap.executeExactInput(secondAmountIn, secondZeroForOne);
            } catch {
                return;
            }
        }

        (uint256 out0, uint256 out1) = forexSwap.simulateRemoveLiquidity(shares, attacker);
        uint256 finalPrice = forexSwap.currentPrice();
        (,, uint256 swapFee) = forexSwap.logNormalParams();

        uint256 spentValue = (spent0 * finalPrice) / 1e18 + spent1;
        uint256 receivedValue = (out0 * finalPrice) / 1e18 + out1;
        uint256 feeUpperBound = secondZeroForOne
            ? (secondAmountIn * beforeSecondPrice * swapFee) / 1e36
            : (secondAmountIn * swapFee) / 1e18;

        assertLe(receivedValue, spentValue + feeUpperBound + 5e12);
        assertTrue(forexSwap.inStrictDomain());
    }

    function test_reserveSolveSelfConsistency() external {
        uint256 liquidityL = 1e18;
        uint256[5] memory xs = [uint256(2e17), 3e17, 4e17, 5e17, 6e17];
        for (uint256 i = 0; i < xs.length; ++i) {
            uint256 y = forexSwap.solveReserve1(xs[i], liquidityL);
            uint256 x2 = forexSwap.solveReserve0(y, liquidityL);
            assertApproxEqAbs(x2, xs[i], 10);
        }

        uint256 reserve0 = 4e17;
        uint256 reserve1 = forexSwap.solveReserve1(reserve0, liquidityL);
        uint256[5] memory ys = [reserve1 / 2, (reserve1 * 3) / 4, reserve1, (reserve1 * 5) / 4, (reserve1 * 3) / 2];
        for (uint256 i = 0; i < ys.length; ++i) {
            uint256 x = forexSwap.solveReserve0(ys[i], liquidityL);
            uint256 y2 = forexSwap.solveReserve1(x, liquidityL);
            assertApproxEqAbs(y2, ys[i], 10);
        }
    }

    function test_priceMatchesFiniteDifferenceSlope() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 4e17;
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 dx = 1e12;
        uint256 price = forexSwap.currentPrice();
        uint256 yBefore = forexSwap.solveReserve1(reserve0, liquidityL);
        uint256 yAfter = forexSwap.solveReserve1(reserve0 + dx, liquidityL);
        uint256 slope = ((yBefore - yAfter) * 1e18) / dx;

        assertApproxEqRel(slope, price, 5e15);
    }

    function test_traceObservedExponentRange_knownSequence() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707_110_000_000_000_000;
        uint256 randomness = 15_627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        int256 minExponent = forexSwap.currentPriceExponent();
        int256 maxExponent = minExponent;

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 quote) {
                if (quote == 0) continue;
            } catch {
                continue;
            }

            int256 beforeExponent = forexSwap.currentPriceExponent();
            if (beforeExponent < minExponent) minExponent = beforeExponent;
            if (beforeExponent > maxExponent) maxExponent = beforeExponent;

            forexSwap.executeExactInput(amountIn, zeroForOne);

            int256 afterExponent = forexSwap.currentPriceExponent();
            if (afterExponent < minExponent) minExponent = afterExponent;
            if (afterExponent > maxExponent) maxExponent = afterExponent;
        }

        console2.logInt(minExponent);
        console2.logInt(maxExponent);
    }

    function testFuzz_repeatedSwapsKeepObservedExponentsWithinBounds(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 randomness
    )
        external
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 1 + (stateRand % MAX_FUZZ_SEQUENCE_STEPS);

        for (uint256 i = 0; i < steps; ++i) {
            int256 exponentBefore = forexSwap.currentPriceExponent();
            assertGe(exponentBefore, -20e18);
            assertLe(exponentBefore, 20e18);

            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 quote) {
                if (quote == 0) continue;
            } catch {
                continue;
            }

            forexSwap.executeExactInput(amountIn, zeroForOne);

            int256 exponentAfter = forexSwap.currentPriceExponent();
            assertGe(exponentAfter, -20e18);
            assertLe(exponentAfter, 20e18);
        }
    }

    function testFuzz_bootstrapDTermsStayFiniteAcrossValidWidths(uint256 priceSeed, uint256 widthSeed) external view {
        uint256 priceWad = bound(priceSeed, 1e14, 100e18);
        uint256 sigma = bound(widthSeed, 1, 2e18 - 1);
        (uint256 d1_, uint256 d2_) = forexSwap.bootstrapDTerms(priceWad, 1e18, sigma);

        assertGe(d1_, d2_);
    }

    function test_quoteExecuteIdentityOnFrozenState() external {
        _seedBalancedPool();
        uint256 amountIn = 1e16;
        uint256 quote = forexSwap.quoteExactInput(amountIn, true);

        (uint256 beforeReserve0, uint256 beforeReserve1, uint256 beforeLiquidity,) = _state();
        uint256 executed = forexSwap.executeExactInput(amountIn, true);
        assertEq(executed, quote);

        (uint256 afterReserve0, uint256 afterReserve1, uint256 afterLiquidity,) = _state();
        assertEq(afterReserve0, beforeReserve0 + amountIn);
        assertLt(afterReserve1, beforeReserve1);
        assertGe(afterLiquidity, beforeLiquidity);
    }

    function test_traceKnownFailingRepeatedSwapSequence() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707_110_000_000_000_000;
        uint256 randomness = 15_627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);
        (uint256 mean,,) = forexSwap.logNormalParams();

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quoted;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quoted = q;
            } catch {
                console2.log("step", i, "quote reverted");
                continue;
            }
            if (quoted == 0) {
                console2.log("step", i, "zero quote");
                continue;
            }

            TraceState memory beforeState;
            (beforeState.reserve0, beforeState.reserve1, beforeState.liquidity,) = _state();
            beforeState.xOverL = (beforeState.reserve0 * 1e18) / beforeState.liquidity;
            beforeState.yOverMuL = (beforeState.reserve1 * 1e18) / ((mean * beforeState.liquidity) / 1e18);
            beforeState.residual = forexSwap.currentInvariant();
            beforeState.price = forexSwap.currentPrice();
            beforeState.valuePerShare = forexSwap.poolValuePerShareWad();
            beforeState.quoted = quoted;
            {
                uint256 y1 = forexSwap.solveReserve1(beforeState.reserve0, beforeState.liquidity);
                uint256 x2 = forexSwap.solveReserve0(y1, beforeState.liquidity);
                uint256 x1 = forexSwap.solveReserve0(beforeState.reserve1, beforeState.liquidity);
                uint256 y2 = forexSwap.solveReserve1(x1, beforeState.liquidity);
                beforeState.xReconError =
                    x2 > beforeState.reserve0 ? x2 - beforeState.reserve0 : beforeState.reserve0 - x2;
                beforeState.yReconError =
                    y2 > beforeState.reserve1 ? y2 - beforeState.reserve1 : beforeState.reserve1 - y2;
            }
            beforeState.xClosureError = forexSwap.phiInvClosure(beforeState.xOverL);
            beforeState.yClosureError = forexSwap.phiInvClosure(beforeState.yOverMuL);

            uint256 executed = forexSwap.executeExactInput(amountIn, zeroForOne);
            (uint256 r0After, uint256 r1After, uint256 lAfter,) = _state();
            int256 residualAfter = forexSwap.currentInvariant();
            uint256 vpsAfter = forexSwap.poolValuePerShareWad();

            console2.log("--- step ---", i);
            console2.log("dir", zeroForOne ? 0 : 1);
            console2.log("reserve0", beforeState.reserve0);
            console2.log("reserve1", beforeState.reserve1);
            console2.log("liquidity", beforeState.liquidity);
            console2.log("xOverL", beforeState.xOverL);
            console2.log("yOverMuL", beforeState.yOverMuL);
            console2.logInt(beforeState.residual);
            console2.log("price", beforeState.price);
            console2.log("valuePerShareWad", beforeState.valuePerShare);
            console2.log("quoted", beforeState.quoted);
            console2.log("executed", executed);
            console2.log("x-reconstruct-error", beforeState.xReconError);
            console2.log("y-reconstruct-error", beforeState.yReconError);
            console2.logInt(beforeState.xClosureError);
            console2.logInt(beforeState.yClosureError);
            console2.log("reserve0 after", r0After);
            console2.log("reserve1 after", r1After);
            console2.log("liquidity after", lAfter);
            console2.logInt(residualAfter);
            console2.log("valuePerShareWad after", vpsAfter);
        }
    }

    function test_traceKnownFailingSequence_GaussianClosure() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707_110_000_000_000_000;
        uint256 randomness = 15_627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);
        uint256 maxClosure;

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quote;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quote = q;
            } catch {
                continue;
            }
            if (quote == 0) continue;

            (uint256 r0, uint256 r1, uint256 l,) = _state();
            (uint256 mean,,) = forexSwap.logNormalParams();
            uint256 ux = (r0 * 1e18) / l;
            uint256 uy = (r1 * 1e18) / ((mean * l) / 1e18);

            uint256 errX = _absInt(forexSwap.phiInvClosure(ux));
            uint256 errY = _absInt(forexSwap.phiInvClosure(uy));
            uint256 closure = errX + errY;
            if (closure > maxClosure) maxClosure = closure;

            console2.log("step", i);
            console2.log("closure", closure);
            console2.log("errX", errX);
            console2.log("errY", errY);
            forexSwap.executeExactInput(amountIn, zeroForOne);
        }

        console2.log("maxClosure", maxClosure);
    }

    function test_knownFailingSequence_compareSpotValueVsSymmetricLocalValue() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707_110_000_000_000_000;
        uint256 randomness = 15_627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quote;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quote = q;
            } catch {
                continue;
            }
            if (quote == 0) continue;

            uint256 spotBefore = forexSwap.poolValuePerShareWad();
            uint256 localBefore = forexSwap.symmetricLocalValuePerShareWad();
            forexSwap.executeExactInput(amountIn, zeroForOne);
            uint256 spotAfter = forexSwap.poolValuePerShareWad();
            uint256 localAfter = forexSwap.symmetricLocalValuePerShareWad();

            console2.log("step", i);
            console2.log("spotBefore", spotBefore);
            console2.log("spotAfter", spotAfter);
            console2.log("localBefore", localBefore);
            console2.log("localAfter", localAfter);
        }
    }

    function test_knownFailingSequenceHasNoClosureSpikes() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707_110_000_000_000_000;
        uint256 randomness = 15_627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quote;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quote = q;
            } catch {
                continue;
            }
            if (quote == 0) continue;

            assertEq(_currentClosureMagnitude(), 0);
            forexSwap.executeExactInput(amountIn, zeroForOne);
            assertTrue(forexSwap.inStrictDomain());
            assertApproxEqAbs(forexSwap.currentInvariant(), 0, 2e16);
            assertEq(_currentClosureMagnitude(), 0);
        }
    }

    function test_closureSweep_yBranch() external {
        uint256 start = 20e16;
        uint256 end = 29e16;
        uint256 step = 5e14;

        uint256 maxErr;
        uint256 first1e3;
        uint256 first1e4;
        uint256 first1e5;
        uint256 first1e6;

        for (uint256 u = start; u <= end; u += step) {
            uint256 err = _absInt(forexSwap.phiInvClosure(u));
            if (err > maxErr) maxErr = err;

            if (first1e3 == 0 && err > 1e3) first1e3 = u;
            if (first1e4 == 0 && err > 1e4) first1e4 = u;
            if (first1e5 == 0 && err > 1e5) first1e5 = u;
            if (first1e6 == 0 && err > 1e6) first1e6 = u;
        }

        console2.log("maxErr", maxErr);
        console2.log("first>1e3", first1e3);
        console2.log("first>1e4", first1e4);
        console2.log("first>1e5", first1e5);
        console2.log("first>1e6", first1e6);
    }

    function test_knownFailingSequencePreservesDomainInvariantAndClosure() external {
        uint256 liquidityL = 1e18;
        uint256 reserve0 = 707_110_000_000_000_000;
        uint256 randomness = 15_627;

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        uint256 stateRand = randomness;
        uint256 steps = 5 + (stateRand % 16);

        for (uint256 i = 0; i < steps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            uint256 quote;
            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
                quote = q;
            } catch {
                continue;
            }
            if (quote == 0) continue;

            forexSwap.executeExactInput(amountIn, zeroForOne);
            assertTrue(forexSwap.inStrictDomain());
            assertApproxEqAbs(forexSwap.currentInvariant(), 0, 2e16);
            assertEq(_currentClosureMagnitude(), 0);
        }
    }

    function test_nonOwnerCannotUpdateParams() external {
        vm.prank(alice);
        vm.expectRevert();
        forexSwap.updateLogNormalParams(1e18, 5e17, 3e15);
    }

    function _state() internal view returns (uint256 reserve0, uint256 reserve1, uint256 liquidityL, uint256 supply) {
        (reserve0, reserve1, liquidityL) = forexSwap.poolState();
        supply = forexSwap.totalSupply();
    }

    function _currentClosureMagnitude() internal view returns (uint256) {
        (uint256 r0, uint256 r1, uint256 l,) = _state();
        (uint256 mean,,) = forexSwap.logNormalParams();
        uint256 ux = (r0 * 1e18) / l;
        uint256 uy = (r1 * 1e18) / ((mean * l) / 1e18);
        return _absInt(forexSwap.phiInvClosure(ux)) + _absInt(forexSwap.phiInvClosure(uy));
    }

    function _assumeInteriorState() internal view {
        vm.assume(_isInteriorState());
    }

    function _isInteriorState() internal view returns (bool) {
        (uint256 reserve0, uint256 reserve1, uint256 liquidityL,) = _state();
        (uint256 mean,,) = forexSwap.logNormalParams();
        uint256 xOverL = (reserve0 * 1e18) / liquidityL;
        uint256 yOverMuL = (reserve1 * 1e18) / ((mean * liquidityL) / 1e18);

        return xOverL > DOMAIN_INTERIOR_EPS && xOverL < 1e18 - DOMAIN_INTERIOR_EPS && yOverMuL > DOMAIN_INTERIOR_EPS
            && yOverMuL < 1e18 - DOMAIN_INTERIOR_EPS;
    }

    function _assertInvariantDriftWithinTolerance(
        int256 beforeValue,
        int256 afterValue,
        uint256 absTol,
        uint256 relTol
    )
        internal
        pure
    {
        uint256 diff = _absDiffInt(beforeValue, afterValue);
        if (diff <= absTol) return;

        uint256 scale = _maxUint(_absInt(beforeValue), 1e18);
        assertLe(diff, FullMath.mulDiv(relTol, scale, 1e18));
    }

    function _assertRoundTripNearBaseline(uint256[3] memory baseline, int256 invariantBefore) internal view {
        (uint256 reserve0After, uint256 reserve1After, uint256 liquidityAfter,) = _state();
        int256 invariantAfter = forexSwap.currentInvariant();

        assertTrue(forexSwap.inStrictDomain());
        assertLe(_absDiffUint(baseline[0], reserve0After), ROUND_TRIP_STATE_ABS_TOLERANCE);
        assertLe(_absDiffUint(baseline[1], reserve1After), ROUND_TRIP_STATE_ABS_TOLERANCE);
        assertLe(_absDiffUint(baseline[2], liquidityAfter), ROUND_TRIP_STATE_ABS_TOLERANCE);
        _assertInvariantDriftWithinTolerance(
            invariantBefore, invariantAfter, INVARIANT_DRIFT_ABS_TOLERANCE, INVARIANT_DRIFT_REL_TOLERANCE
        );
    }

    function _executeSwapAndMeasure(
        uint256 amountIn,
        bool zeroForOne,
        int256 invariantStart
    )
        internal
        returns (bool executed, uint256 stepDrift, uint256 cumulativeDrift, uint256 previewGap)
    {
        uint256 quoted;
        try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 q) {
            quoted = q;
        } catch {
            return (false, 0, 0, 0);
        }
        if (quoted == 0) return (false, 0, 0, 0);

        int256 invariantBefore = forexSwap.currentInvariant();
        (uint256 previewReserve0, uint256 previewReserve1, uint256 previewLiquidity) =
            forexSwap.previewPostSwapState(amountIn, zeroForOne);
        int256 previewInvariantAfter = forexSwap.residualForState(previewReserve0, previewReserve1, previewLiquidity);

        forexSwap.executeExactInput(amountIn, zeroForOne);
        int256 actualInvariantAfter = forexSwap.currentInvariant();

        stepDrift = _absDiffInt(invariantBefore, actualInvariantAfter);
        cumulativeDrift = _absDiffInt(invariantStart, actualInvariantAfter);
        previewGap = _absDiffInt(previewInvariantAfter, actualInvariantAfter);
        return (true, stepDrift, cumulativeDrift, previewGap);
    }

    function _runRepeatedSwapRegression(
        uint256 reserve0Seed,
        uint256 liquiditySeed,
        uint256 randomness,
        bool invertDirections
    )
        internal
        returns (RegressionStep[] memory steps)
    {
        uint256 liquidityL = bound(liquiditySeed, 1e18, 8e18);
        uint256 reserve0 = bound(reserve0Seed, liquidityL / 8, (liquidityL * 7) / 10);

        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        assertTrue(_isInteriorState());

        int256 invariantStart = forexSwap.currentInvariant();
        uint256 stateRand = randomness;
        uint256 totalSteps = 5 + (stateRand % 16);
        steps = new RegressionStep[](totalSteps);

        if (DEBUG) {
            console2.log("--- repeated swap regression ---");
            console2.log("reserve0Seed", reserve0Seed);
            console2.log("liquiditySeed", liquiditySeed);
            console2.log("randomness", randomness);
            console2.log("invertDirections", invertDirections ? 1 : 0);
            console2.log("boundedReserve0", reserve0);
            console2.log("boundedLiquidity", liquidityL);
            console2.logInt(invariantStart);
        }

        for (uint256 i = 0; i < totalSteps; ++i) {
            stateRand = uint256(keccak256(abi.encode(stateRand, i)));
            bool zeroForOne = (stateRand & 1) == 0;
            if (invertDirections) zeroForOne = !zeroForOne;

            (,, uint256 currentLiquidity,) = _state();
            uint256 amountIn = bound(stateRand >> 8, 1e15, currentLiquidity / 40);

            try forexSwap.quoteExactInput(amountIn, zeroForOne) returns (uint256 quoted) {
                if (quoted == 0) {
                    if (DEBUG) console2.log("step skipped: zero quote", i);
                    continue;
                }

                ForexSwapHarness.SwapDebugTrace memory trace = forexSwap.debugExactInput(amountIn, zeroForOne);
                if (DEBUG) _logRepeatedSwapTrace(i, stateRand, trace, invariantStart);

                forexSwap.executeExactInput(amountIn, zeroForOne);

                int256 actualInvariantAfter = forexSwap.currentInvariant();
                uint256 stepDrift = _absDiffInt(trace.invariantBefore, actualInvariantAfter);
                uint256 cumulativeDrift = _absDiffInt(invariantStart, actualInvariantAfter);

                steps[i] = RegressionStep({
                    step: i,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    amountOut: trace.amountOut,
                    invariantBefore: trace.invariantBefore,
                    invariantAfter: actualInvariantAfter,
                    stepDrift: stepDrift,
                    cumulativeDrift: cumulativeDrift
                });

                if (DEBUG) {
                    console2.log("executed step", i);
                    console2.log("actualAmountOut", trace.amountOut);
                    console2.logInt(actualInvariantAfter);
                    console2.log("stepDrift", stepDrift);
                    console2.log("cumulativeDrift", cumulativeDrift);
                }
            } catch (bytes memory reason) {
                if (DEBUG) {
                    console2.log("step reverted", i);
                    console2.logBytes(reason);
                }
            }
        }
    }

    function _runSingleStepTrace(
        uint256 reserve0,
        uint256 reserve1,
        uint256 liquidityL,
        uint256 amountIn,
        bool zeroForOne,
        string memory label
    )
        internal
        returns (ForexSwapHarness.SwapDebugTrace memory trace)
    {
        forexSwap.seedState(reserve0, reserve1, liquidityL, 1e18, alice);
        trace = forexSwap.debugExactInput(amountIn, zeroForOne);

        console2.log("--- single step trace ---");
        console2.log(label);
        _logRepeatedSwapTrace(0, 0, trace, trace.invariantBefore);

        forexSwap.executeExactInput(amountIn, zeroForOne);
        int256 actualInvariantAfter = forexSwap.currentInvariant();

        console2.log("actualInvariantAfter", uint256(_absInt(actualInvariantAfter)));
        console2.log("previewExecuteGap", _absDiffInt(trace.invariantAfter, actualInvariantAfter));

        assertEq(trace.invariantAfter, actualInvariantAfter);
    }

    function _logRootNeighborhood(
        string memory label,
        uint256 reserve0,
        uint256 reserve1,
        uint256 liquidityL,
        bool varyReserve0
    )
        internal
        view
    {
        console2.log("--- root neighborhood ---");
        console2.log(label);

        if (varyReserve0) {
            if (reserve0 > 1) {
                console2.logInt(forexSwap.residualForState(reserve0 - 1, reserve1, liquidityL));
            }
            console2.logInt(forexSwap.residualForState(reserve0, reserve1, liquidityL));
            console2.logInt(forexSwap.residualForState(reserve0 + 1, reserve1, liquidityL));
        } else {
            if (reserve1 > 1) {
                console2.logInt(forexSwap.residualForState(reserve0, reserve1 - 1, liquidityL));
            }
            console2.logInt(forexSwap.residualForState(reserve0, reserve1, liquidityL));
            console2.logInt(forexSwap.residualForState(reserve0, reserve1 + 1, liquidityL));
        }
    }

    function _logResidualNeighborhood(
        string memory label,
        uint256 reserve0,
        uint256 reserve1,
        uint256 liquidityL,
        bool varyReserve0
    )
        internal
        view
    {
        console2.log("--- residual neighborhood ---");
        console2.log(label);

        if (varyReserve0) {
            if (reserve0 > 1) _logResidualPoint("minus1", forexSwap.debugResidual(reserve0 - 1, reserve1, liquidityL));
            _logResidualPoint("exact", forexSwap.debugResidual(reserve0, reserve1, liquidityL));
            _logResidualPoint("plus1", forexSwap.debugResidual(reserve0 + 1, reserve1, liquidityL));
        } else {
            if (reserve1 > 1) _logResidualPoint("minus1", forexSwap.debugResidual(reserve0, reserve1 - 1, liquidityL));
            _logResidualPoint("exact", forexSwap.debugResidual(reserve0, reserve1, liquidityL));
            _logResidualPoint("plus1", forexSwap.debugResidual(reserve0, reserve1 + 1, liquidityL));
        }
    }

    function _logResidualPoint(string memory label, ForexSwapHarness.ResidualDebugTrace memory trace) internal pure {
        console2.log(label);
        console2.log("reserve0", trace.reserve0);
        console2.log("reserve1", trace.reserve1);
        console2.log("liquidity", trace.liquidity);
        console2.log("maxReserve1", trace.maxReserve1);
        console2.log("xNumerator", trace.xNumerator);
        console2.log("xDenominator", trace.xDenominator);
        console2.log("xOverL", trace.xOverL);
        console2.logInt(trace.invPhiX);
        console2.log("yNumerator", trace.yNumerator);
        console2.log("yDenominator", trace.yDenominator);
        console2.log("yOverMuL", trace.yOverMuL);
        console2.logInt(trace.invPhiY);
        console2.log("effectiveWidth", trace.effectiveWidth);
        console2.logInt(trace.residual);
    }

    function _logInvPhiNeighborhood(string memory label, uint256 u) internal view {
        console2.log("--- invPhi neighborhood ---");
        console2.log(label);
        if (u > 1) console2.logInt(forexSwap.debugInvPhi(u - 1));
        console2.logInt(forexSwap.debugInvPhi(u));
        console2.logInt(forexSwap.debugInvPhi(u + 1));
    }

    function _logLiquidityNeighborhood(
        string memory label,
        uint256 reserve0,
        uint256 reserve1,
        uint256 liquidityL,
        bool originalOrientation
    )
        internal
        view
    {
        console2.log("--- liquidity neighborhood ---");
        console2.log(label);
        if (liquidityL > 1) {
            console2.logInt(forexSwap.residualForState(reserve0, reserve1, liquidityL - 1));
        }
        console2.logInt(forexSwap.residualForState(reserve0, reserve1, liquidityL));
        console2.logInt(forexSwap.residualForState(reserve0, reserve1, liquidityL + 1));

        if (originalOrientation) {
            console2.log("solvedReserve1AtLminus1", forexSwap.solveReserve1(reserve0, liquidityL - 1));
            console2.log("solvedReserve1AtL", forexSwap.solveReserve1(reserve0, liquidityL));
            console2.log("solvedReserve1AtLplus1", forexSwap.solveReserve1(reserve0, liquidityL + 1));
        } else {
            console2.log("solvedReserve0AtLminus1", forexSwap.solveReserve0(reserve1, liquidityL - 1));
            console2.log("solvedReserve0AtL", forexSwap.solveReserve0(reserve1, liquidityL));
            console2.log("solvedReserve0AtLplus1", forexSwap.solveReserve0(reserve1, liquidityL + 1));
        }
    }

    function _logRepeatedSwapTrace(
        uint256 step,
        uint256 stateRand,
        ForexSwapHarness.SwapDebugTrace memory trace,
        int256 invariantStart
    )
        internal
        pure
    {
        console2.log("step", step);
        console2.log("stateRand", stateRand);
        console2.log("branch zeroForOne", trace.zeroForOne ? 1 : 0);
        console2.log("amountIn", trace.amountIn);
        console2.log("quotedAmountOut", trace.quoteAmountOut);
        console2.log("reserve0Before", trace.reserve0Before);
        console2.log("reserve1Before", trace.reserve1Before);
        console2.log("liquidityBefore", trace.liquidityBefore);
        console2.logInt(trace.invariantBefore);
        console2.log("xOverLBefore", trace.xOverLBefore);
        console2.log("yOverMuLBefore", trace.yOverMuLBefore);
        console2.log("hookFeeWad", trace.hookFeeWad);
        console2.log("feeAmount", trace.feeAmount);
        console2.log("effectiveIn", trace.effectiveIn);
        console2.log("postFeeSpecifiedReserve", trace.postFeeSpecifiedReserve);
        console2.log("solvedLiquidity", trace.solvedLiquidity);
        console2.log("reserve0AfterPreview", trace.reserve0After);
        console2.log("reserve1AfterPreview", trace.reserve1After);
        console2.log("previewAmountOut", trace.amountOut);
        console2.logInt(trace.invariantAfter);
        console2.log("previewStepDrift", _absDiffInt(trace.invariantBefore, trace.invariantAfter));
        console2.log("previewCumulativeDrift", _absDiffInt(invariantStart, trace.invariantAfter));
        console2.log("xOverLAfter", trace.xOverLAfter);
        console2.log("yOverMuLAfter", trace.yOverMuLAfter);
    }

    function _safeQuoteExactInput(uint256 amountIn, bool zeroForOne)
        internal
        view
        returns (bool ok, uint256 amountOut)
    {
        try forexSwap.calculateAmountOut(amountIn, zeroForOne) returns (uint256 quoted) {
            return (true, quoted);
        } catch {
            return (false, 0);
        }
    }

    function _safeSolveQuoteExactInput(
        uint256 amountIn,
        bool zeroForOne
    )
        internal
        view
        returns (bool ok, bool domainExceeded, uint256 amountOut)
    {
        try forexSwap.quoteExactInputForSolve(amountIn, zeroForOne) returns (uint256 quoted) {
            return (true, false, quoted);
        } catch (bytes memory reason) {
            bytes4 selector = _revertSelector(reason);
            if (selector == ForexSwap.DomainExceeded.selector) return (false, true, 0);
            revert("unexpected quote revert");
        }
    }

    function _assertPreviewOracleMatchesBoundedScan(
        uint256 reserve0,
        uint256 liquidityL,
        uint256 targetBps,
        bool zeroForOne
    )
        internal
    {
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        (uint256 maxIn, uint256 maxQuote) = _findSolveUpperBound(zeroForOne);
        (bool maxOk,, uint256 observedQuote) = _safeSolveQuoteExactInput(maxIn, zeroForOne);
        assertTrue(maxOk);
        assertEq(observedQuote, maxQuote);
        assertGt(maxQuote, 1);

        uint256 targetOut = FullMath.mulDiv(maxQuote, targetBps, 10_000);
        if (targetOut == 0) targetOut = 1;
        if (targetOut >= maxQuote) targetOut = maxQuote - 1;
        (bool monotone, bool found, uint256 leastAmountIn) = _linearScanExactOutputOracle(maxIn, targetOut, zeroForOne);

        if (!monotone) {
            vm.expectRevert(ForexSwap.NonMonotonicQuote.selector);
            forexSwap.previewExactOutput(targetOut, zeroForOne);
            return;
        }

        assertTrue(found);
        uint256 previewed = forexSwap.previewExactOutput(targetOut, zeroForOne);
        assertEq(previewed, leastAmountIn);
    }

    function _linearScanExactOutputOracle(
        uint256 maxIn,
        uint256 targetOut,
        bool zeroForOne
    )
        internal
        view
        returns (bool monotone, bool found, uint256 leastAmountIn)
    {
        monotone = true;
        uint256 previousQuote = 0;
        bool seenValid;

        for (uint256 amountIn = 1; amountIn <= maxIn; ++amountIn) {
            (bool ok, bool domainExceeded, uint256 quote) = _safeSolveQuoteExactInput(amountIn, zeroForOne);
            if (!ok) {
                assertTrue(domainExceeded);
                if (!seenValid) continue;
                break;
            }

            seenValid = true;
            if (quote < previousQuote) return (false, false, 0);
            if (!found && quote >= targetOut) {
                found = true;
                leastAmountIn = amountIn;
            }
            previousQuote = quote;
        }
    }

    function _findSolveUpperBound(bool zeroForOne) internal view returns (uint256 amountIn, uint256 quoteOut) {
        amountIn = 1;

        for (uint256 i = 0; i < 24; ++i) {
            (bool ok,, uint256 quote) = _safeSolveQuoteExactInput(amountIn, zeroForOne);
            if (ok && quote > 1) return (amountIn, quote);
            amountIn *= 2;
        }

        revert("solve upper bound not found");
    }

    function _logPreviewBoundaryCase(
        uint256 stateIndex,
        uint256 reserve0,
        uint256 liquidityL,
        uint256[4] memory targetBps,
        bool zeroForOne
    )
        internal
    {
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);

        (uint256 r0, uint256 r1,,) = _state();
        (uint256 mean,,) = forexSwap.logNormalParams();
        uint256 xOverL = FullMath.mulDiv(r0, 1e18, liquidityL);
        uint256 yOverMuL = FullMath.mulDiv(r1, 1e18, mean * liquidityL / 1e18);
        console2.log("state", stateIndex);
        console2.log("xOverL", xOverL);
        console2.log("yOverMuL", yOverMuL);

        uint256 firstQuoteNonMonotoneInput = _findFirstQuoteNonMonotoneInput(liquidityL, zeroForOne);
        (uint256 firstPreviewDomainExceeded, uint256 firstPreviewNonMonotonic) =
            _findPreviewFailureFrontier(reserve0, liquidityL, targetBps, zeroForOne);
        (uint256 firstExecDomainExceeded, uint256 firstExecNonMonotonic) =
            _findExecuteFailureFrontier(reserve0, liquidityL, targetBps, zeroForOne);

        console2.log("firstPreviewDomainExceededBps", firstPreviewDomainExceeded);
        console2.log("firstPreviewNonMonotonicBps", firstPreviewNonMonotonic);
        console2.log("firstExecDomainExceededBps", firstExecDomainExceeded);
        console2.log("firstExecNonMonotonicBps", firstExecNonMonotonic);
        console2.log("firstQuoteNonMonotoneInput", firstQuoteNonMonotoneInput);
    }

    function _findFirstQuoteNonMonotoneInput(uint256 liquidityL, bool zeroForOne) internal view returns (uint256) {
        uint256 previousQuote = 0;
        for (uint256 i = 1; i <= 16; ++i) {
            uint256 sampleIn = FullMath.mulDiv(liquidityL / 8, i, 16);
            (bool ok, uint256 quoted) = _safeQuoteExactInput(sampleIn, zeroForOne);
            if (!ok) break;
            if (quoted < previousQuote) return sampleIn;
            previousQuote = quoted;
        }
        return 0;
    }

    function _findPreviewFailureFrontier(
        uint256 reserve0,
        uint256 liquidityL,
        uint256[4] memory targetBps,
        bool zeroForOne
    )
        internal
        returns (uint256 firstDomainExceededBps, uint256 firstNonMonotonicBps)
    {
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        (uint256 r0, uint256 r1,,) = _state();
        uint256 stateAmountOut = zeroForOne ? r1 : r0;

        for (uint256 t = 0; t < targetBps.length; ++t) {
            uint256 targetOut = FullMath.mulDiv(stateAmountOut, targetBps[t], 10_000);
            if (targetOut == 0) continue;

            forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
            try forexSwap.previewExactOutput(targetOut, zeroForOne) returns (uint256) { }
            catch (bytes memory reason) {
                bytes4 selector = _revertSelector(reason);
                if (selector == ForexSwap.DomainExceeded.selector && firstDomainExceededBps == 0) {
                    firstDomainExceededBps = targetBps[t];
                }
                if (selector == ForexSwap.NonMonotonicQuote.selector && firstNonMonotonicBps == 0) {
                    firstNonMonotonicBps = targetBps[t];
                }
            }
        }
    }

    function _findExecuteFailureFrontier(
        uint256 reserve0,
        uint256 liquidityL,
        uint256[4] memory targetBps,
        bool zeroForOne
    )
        internal
        returns (uint256 firstDomainExceededBps, uint256 firstNonMonotonicBps)
    {
        forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
        (uint256 r0, uint256 r1,,) = _state();
        uint256 stateAmountOut = zeroForOne ? r1 : r0;

        for (uint256 t = 0; t < targetBps.length; ++t) {
            uint256 targetOut = FullMath.mulDiv(stateAmountOut, targetBps[t], 10_000);
            if (targetOut == 0) continue;

            forexSwap.seedConsistentState(reserve0, liquidityL, 1e18, alice);
            try forexSwap.executeExactOutput(targetOut, zeroForOne) returns (uint256) { }
            catch (bytes memory reason) {
                bytes4 selector = _revertSelector(reason);
                if (selector == ForexSwap.DomainExceeded.selector && firstDomainExceededBps == 0) {
                    firstDomainExceededBps = targetBps[t];
                }
                if (selector == ForexSwap.NonMonotonicQuote.selector && firstNonMonotonicBps == 0) {
                    firstNonMonotonicBps = targetBps[t];
                }
            }
        }
    }

    function _absInt(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }

    function _absDiffInt(int256 a, int256 b) internal pure returns (uint256) {
        return a >= b ? _absInt(a - b) : _absInt(b - a);
    }

    function _maxUint(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function _absDiffUint(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }

    function _revertSelector(bytes memory reason) internal pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(reason, 32))
        }
    }
}
