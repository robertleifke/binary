// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/src/console.sol";
import {ForexSwap} from "../src/ForexSwap.sol";
import {BaseScript} from "./Base.s.sol";
import {BaseCustomAccounting} from "uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Math} from "v4-core/lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Create2FactorySepoliaStable {
    error DeploymentFailed();
    error OwnershipTransferFailed();

    function deploy(bytes32 salt, bytes memory creationCode, address owner) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }

        if (deployed == address(0)) revert DeploymentFailed();

        (bool ok,) = deployed.call(abi.encodeWithSignature("transferOwnership(address)", owner));
        if (!ok) revert OwnershipTransferFailed();
    }
}

contract BaseSepoliaStableE2E is BaseScript {
    struct RunState {
        IPoolManager poolManager;
        PoolSwapTest swapRouter;
        IERC20Like usdc;
        IERC20Like eurc;
        ForexSwap hook;
        Create2FactorySepoliaStable factory;
        PoolKey key;
        bytes32 salt;
        address predictedHook;
        uint160 sqrtPriceX96;
        uint256 usdcPerEurcWad;
        uint256 eurcPerUsdcWad;
        uint256 amount0Desired;
        uint256 amount1Desired;
    }

    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_SEPOLIA_POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant BASE_SEPOLIA_EURC = 0x808456652fdb597867f38412077A9182bf77359F;
    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOKEN_SCALE = 1e6;
    uint256 internal constant BASELINE_FEE_WAD = 3e15;
    uint256 internal constant DEFAULT_INVENTORY_RESPONSE_WAD = 25e16;
    // ECB euro reference exchange rate as of 2 April 2026: 1 EUR = 1.1525 USD.
    uint256 internal constant DEFAULT_USDC_PER_EURC_WAD = 1_152_500_000_000_000_000;
    uint256 internal constant DEFAULT_ADD_AMOUNT0_DESIRED = 10 * TOKEN_SCALE;
    uint256 internal constant DEFAULT_ADD_AMOUNT1_DESIRED = 10 * TOKEN_SCALE;
    uint256 internal constant SWAP_SMALL = 100_000;
    uint256 internal constant SWAP_MEDIUM = 1_000_000;
    uint256 internal constant SWAP_LARGE = 5_000_000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -120;
    int24 internal constant TICK_UPPER = 120;

    function run() public broadcast returns (ForexSwap hook) {
        RunState memory s;
        s.poolManager = IPoolManager(BASE_SEPOLIA_POOL_MANAGER);
        s.swapRouter = PoolSwapTest(BASE_SEPOLIA_POOL_SWAP_TEST);
        s.usdc = IERC20Like(BASE_SEPOLIA_USDC);
        s.eurc = IERC20Like(BASE_SEPOLIA_EURC);
        s.usdcPerEurcWad = vm.envOr("ANCHOR_USDC_PER_EURC_WAD", DEFAULT_USDC_PER_EURC_WAD);
        s.eurcPerUsdcWad = FullMath.mulDiv(WAD, WAD, s.usdcPerEurcWad);
        s.sqrtPriceX96 = _sqrtPriceX96FromPriceWad(s.eurcPerUsdcWad);
        s.amount0Desired = vm.envOr("ADD_AMOUNT0_DESIRED", DEFAULT_ADD_AMOUNT0_DESIRED);
        s.amount1Desired = vm.envOr("ADD_AMOUNT1_DESIRED", DEFAULT_ADD_AMOUNT1_DESIRED);

        _requireBalances(s.usdc, s.eurc, s.amount0Desired, s.amount1Desired);

        (Currency currency0, Currency currency1) = _sortCurrencies(BASE_SEPOLIA_USDC, BASE_SEPOLIA_EURC);
        require(Currency.unwrap(currency0) == BASE_SEPOLIA_USDC, "unexpected currency0");
        require(Currency.unwrap(currency1) == BASE_SEPOLIA_EURC, "unexpected currency1");

        (s.hook, s.factory, s.salt, s.predictedHook) = _deployHook(s.poolManager);
        _anchorHookMean(s.hook, s.eurcPerUsdcWad);
        _tuneInventoryResponse(s.hook);
        s.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(s.hook))
        });

        s.poolManager.initialize(s.key, s.sqrtPriceX96);

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 amount0, uint256 amount1, uint256 shares) =
            _bootstrapLiquidity(s.hook, s.usdc, s.eurc, deadline, s.amount0Desired, s.amount1Desired);

        _logSwapScenario("buy-small", s.hook, s.swapRouter, s.key, s.usdc, s.eurc, SWAP_SMALL, true, s.usdcPerEurcWad);
        _logSwapScenario("buy-medium", s.hook, s.swapRouter, s.key, s.usdc, s.eurc, SWAP_MEDIUM, true, s.usdcPerEurcWad);
        _logSwapScenario("buy-large", s.hook, s.swapRouter, s.key, s.usdc, s.eurc, SWAP_LARGE, true, s.usdcPerEurcWad);
        _logSwapScenario("sell-small", s.hook, s.swapRouter, s.key, s.eurc, s.usdc, SWAP_SMALL, false, s.usdcPerEurcWad);
        _logSwapScenario("sell-medium", s.hook, s.swapRouter, s.key, s.eurc, s.usdc, SWAP_MEDIUM, false, s.usdcPerEurcWad);
        _logSwapScenario("sell-large", s.hook, s.swapRouter, s.key, s.eurc, s.usdc, SWAP_LARGE, false, s.usdcPerEurcWad);

        _removeHalfLiquidity(s.hook, shares, deadline);

        (uint256 reserve0, uint256 reserve1, uint256 liquidityL, uint256 priceWad, bool paused_) = s.hook.getPoolInfo();
        require(!paused_, "hook paused");
        require(reserve0 > 0 && reserve1 > 0 && liquidityL > 0 && priceWad > 0, "post-state invalid");

        console.log("PoolManager:", address(s.poolManager));
        console.log("PoolSwapTest:", address(s.swapRouter));
        console.log("USDC:", BASE_SEPOLIA_USDC);
        console.log("EURC:", BASE_SEPOLIA_EURC);
        console.log("Anchor usdcPerEurcWad:", s.usdcPerEurcWad);
        console.log("Inventory response WAD:", s.hook.inventoryResponseWad());
        console.log("Init eurcPerUsdcWad:", s.eurcPerUsdcWad);
        console.log("Init sqrtPriceX96:", uint256(s.sqrtPriceX96));
        console.log("CREATE2 factory:", address(s.factory));
        console.log("Hook salt:", uint256(s.salt));
        console.log("Predicted hook:", s.predictedHook);
        console.log("Deployed hook:", address(s.hook));
        console.log("Bootstrap amount0 (USDC):", amount0);
        console.log("Bootstrap amount1 (EURC):", amount1);
        console.log("Liquidity shares:", shares);
        console.log("Final reserve0 (USDC):", reserve0);
        console.log("Final reserve1 (EURC):", reserve1);
        console.log("Final liquidity:", liquidityL);
        console.log("Final eurcPerUsdcWad:", priceWad);
        console.log("Final usdcPerEurcWad:", FullMath.mulDiv(WAD, WAD, priceWad));
        hook = s.hook;
    }

    function _deployHook(IPoolManager poolManager)
        internal
        returns (ForexSwap hook, Create2FactorySepoliaStable factory, bytes32 salt, address predictedHook)
    {
        factory = new Create2FactorySepoliaStable();
        bytes memory creationCode = abi.encodePacked(type(ForexSwap).creationCode, abi.encode(poolManager));
        bytes32 initCodeHash = keccak256(creationCode);
        (salt, predictedHook) = _mineHookSalt(address(factory), initCodeHash);
        hook = ForexSwap(factory.deploy(salt, creationCode, broadcaster));
    }

    function _bootstrapLiquidity(ForexSwap hook, IERC20Like usdc, IERC20Like eurc, uint256 deadline)
        internal
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        return _bootstrapLiquidity(hook, usdc, eurc, deadline, DEFAULT_ADD_AMOUNT0_DESIRED, DEFAULT_ADD_AMOUNT1_DESIRED);
    }

    function _bootstrapLiquidity(
        ForexSwap hook,
        IERC20Like usdc,
        IERC20Like eurc,
        uint256 deadline,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint256 amount0, uint256 amount1, uint256 shares) {
        require(usdc.approve(address(hook), type(uint256).max), "USDC approve failed");
        require(eurc.approve(address(hook), type(uint256).max), "EURC approve failed");

        (amount0, amount1, shares) = hook.addLiquidityWithSlippage(amount0Desired, amount1Desired, 0, 0, deadline);
        require(amount0 > 0 && amount1 > 0 && shares > 0, "bootstrap quote failed");

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                userInputSalt: ZERO_SALT
            })
        );

        require(hook.balanceOf(broadcaster) == shares, "liquidity shares mismatch");
    }

    function _anchorHookMean(ForexSwap hook, uint256 anchoredMeanWad) internal {
        (, uint256 width, uint256 baseHookFeeWad) = hook.logNormalParams();
        hook.updateLogNormalParams(anchoredMeanWad, width, baseHookFeeWad);
    }

    function _tuneInventoryResponse(ForexSwap hook) internal {
        uint256 responseWad = vm.envOr("INVENTORY_RESPONSE_WAD", DEFAULT_INVENTORY_RESPONSE_WAD);
        hook.updateInventoryResponseWad(responseWad);
    }

    function _logSwapScenario(
        string memory label,
        ForexSwap hook,
        PoolSwapTest swapRouter,
        PoolKey memory key,
        IERC20Like tokenIn,
        IERC20Like tokenOut,
        uint256 amountIn,
        bool zeroForOne,
        uint256 anchorUsdcPerEurcWad
    ) internal {
        require(tokenIn.approve(address(swapRouter), type(uint256).max), "tokenIn router approve failed");
        require(tokenOut.approve(address(swapRouter), type(uint256).max), "tokenOut router approve failed");

        (uint256 reserve0Before, uint256 reserve1Before,, uint256 spotBeforeEurcPerUsdcWad,) = hook.getPoolInfo();
        uint256 spotBeforeUsdcPerEurcWad = FullMath.mulDiv(WAD, WAD, spotBeforeEurcPerUsdcWad);
        (uint256 feeWad, uint256 feeAmount) = hook.quoteHookFee(amountIn, zeroForOne);
        uint256 quotedOut = hook.calculateAmountOut(amountIn, zeroForOne);
        require(quotedOut > 0, "swap quote failed");

        uint256 outBefore = tokenOut.balanceOf(broadcaster);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 outAfter = tokenOut.balanceOf(broadcaster);
        uint256 executedOut = outAfter - outBefore;

        (uint256 reserve0After, uint256 reserve1After, uint256 liquidityL, uint256 spotAfterEurcPerUsdcWad,) = hook.getPoolInfo();
        uint256 spotAfterUsdcPerEurcWad = FullMath.mulDiv(WAD, WAD, spotAfterEurcPerUsdcWad);
        uint256 impliedUsdcPerEurcWad = zeroForOne
            ? FullMath.mulDiv(amountIn, WAD, executedOut)
            : FullMath.mulDiv(executedOut, WAD, amountIn);
        uint256 impliedEurcPerUsdcWad = FullMath.mulDiv(WAD, WAD, impliedUsdcPerEurcWad);
        uint256 anchorOut = _anchorOutput(amountIn, zeroForOne, anchorUsdcPerEurcWad);
        uint256 baselineOut = _baselineStableOutput(amountIn, zeroForOne, anchorUsdcPerEurcWad);

        console.log("swap label:", label);
        console.log("swap direction zeroForOne:", zeroForOne);
        console.log("swap amountIn:", amountIn);
        console.log("swap quoteOut:", quotedOut);
        console.log("swap executedOut:", executedOut);
        console.log("swap anchorOut noFee:", anchorOut);
        console.log("swap baselineOut 30bps:", baselineOut);
        console.log("spot before eurcPerUsdcWad:", spotBeforeEurcPerUsdcWad);
        console.log("spot before usdcPerEurcWad:", spotBeforeUsdcPerEurcWad);
        console.log("spot after eurcPerUsdcWad:", spotAfterEurcPerUsdcWad);
        console.log("spot after usdcPerEurcWad:", spotAfterUsdcPerEurcWad);
        console.log("implied execution eurcPerUsdcWad:", impliedEurcPerUsdcWad);
        console.log("implied execution usdcPerEurcWad:", impliedUsdcPerEurcWad);
        console.log("executed vs anchor bps:", _signedDiffBps(executedOut, anchorOut));
        console.log("executed vs baseline bps:", _signedDiffBps(executedOut, baselineOut));
        console.log("quoted vs executed bps:", _signedDiffBps(quotedOut, executedOut));
        console.log("swap hookFeeWad:", feeWad);
        console.log("swap hookFeeAmount:", feeAmount);
        console.log("pre reserve0 USDC:", reserve0Before);
        console.log("pre reserve1 EURC:", reserve1Before);
        console.log("post reserve0 USDC:", reserve0After);
        console.log("post reserve1 EURC:", reserve1After);
        console.log("post liquidity:", liquidityL);
        console.log("post eurcPerUsdcWad:", spotAfterEurcPerUsdcWad);
        console.log("post usdcPerEurcWad:", spotAfterUsdcPerEurcWad);
    }

    function _removeHalfLiquidity(ForexSwap hook, uint256 shares, uint256 deadline) internal {
        uint256 sharesToRemove = shares / 2;
        require(sharesToRemove > 0, "remove amount too small");
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: sharesToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                userInputSalt: ZERO_SALT
            })
        );
    }

    function _requireBalances(IERC20Like usdc, IERC20Like eurc, uint256 amount0Desired, uint256 amount1Desired)
        internal
        view
    {
        uint256 minUsdc = amount0Desired + SWAP_SMALL + SWAP_MEDIUM + SWAP_LARGE;
        uint256 minEurc = amount1Desired + SWAP_SMALL + SWAP_MEDIUM + SWAP_LARGE;
        require(usdc.balanceOf(broadcaster) >= minUsdc, "insufficient USDC");
        require(eurc.balanceOf(broadcaster) >= minEurc, "insufficient EURC");
    }

    function _anchorOutput(uint256 amountIn, bool zeroForOne, uint256 anchorUsdcPerEurcWad)
        internal
        pure
        returns (uint256)
    {
        return zeroForOne
            ? FullMath.mulDiv(amountIn, WAD, anchorUsdcPerEurcWad)
            : FullMath.mulDiv(amountIn, anchorUsdcPerEurcWad, WAD);
    }

    function _baselineStableOutput(uint256 amountIn, bool zeroForOne, uint256 anchorUsdcPerEurcWad)
        internal
        pure
        returns (uint256)
    {
        uint256 amountAfterFee = FullMath.mulDiv(amountIn, WAD - BASELINE_FEE_WAD, WAD);
        return _anchorOutput(amountAfterFee, zeroForOne, anchorUsdcPerEurcWad);
    }

    function _signedDiffBps(uint256 actual, uint256 referenceValue) internal pure returns (int256) {
        if (referenceValue == 0) return 0;
        if (actual >= referenceValue) {
            return int256(FullMath.mulDiv(actual - referenceValue, 10_000, referenceValue));
        }
        return -int256(FullMath.mulDiv(referenceValue - actual, 10_000, referenceValue));
    }

    function _sortCurrencies(address tokenA, address tokenB) internal pure returns (Currency currency0, Currency currency1) {
        currency0 = Currency.wrap(tokenA);
        currency1 = Currency.wrap(tokenB);
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }
    }

    function _sqrtPriceX96FromPriceWad(uint256 priceWad) internal pure returns (uint160 sqrtPriceX96) {
        uint256 q192 = uint256(FixedPoint96.Q96) * uint256(FixedPoint96.Q96);
        uint256 ratioX192 = FullMath.mulDiv(priceWad, q192, WAD);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
    }

    function _mineHookSalt(address deployer, bytes32 initCodeHash) internal pure returns (bytes32 salt, address hook) {
        for (uint256 candidate = 0; candidate < type(uint24).max; candidate++) {
            salt = bytes32(candidate);
            hook = vm.computeCreate2Address(salt, initCodeHash, deployer);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == REQUIRED_HOOK_FLAGS) {
                return (salt, hook);
            }
        }

        revert("No hook salt found");
    }
}
