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

contract Create2FactorySepoliaCNGNSwap {
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

contract BaseSepoliaCNGNSwapE2E is BaseScript {
    struct RunState {
        IPoolManager poolManager;
        PoolSwapTest swapRouter;
        IERC20Like usdc;
        IERC20Like cngn;
        ForexSwap hook;
        Create2FactorySepoliaCNGNSwap factory;
        PoolKey key;
        bytes32 salt;
        address predictedHook;
        uint160 sqrtPriceX96;
        uint256 usdcPerCngnWad;
        uint256 cngnPerUsdcWad;
        uint256 amount0Desired;
        uint256 amount1Desired;
    }

    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_SEPOLIA_POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant BASE_SEPOLIA_CNGN = 0xe2387F04d3858e7Cb64Ef5Ed6617f9B2fcEEAfa2;
    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BASELINE_FEE_WAD = 3e15;
    uint256 internal constant DEFAULT_INVENTORY_RESPONSE_WAD = 25e16;
    uint256 internal constant DEFAULT_USDC_PER_CNGN_WAD = 724_454_000_000_000;
    uint256 internal constant DEFAULT_ADD_AMOUNT0_DESIRED = 579_560;
    uint256 internal constant DEFAULT_ADD_AMOUNT1_DESIRED = 800_000_000;
    uint256 internal constant DEFAULT_BUY_SMALL = 1_000;
    uint256 internal constant DEFAULT_BUY_MEDIUM = 5_000;
    uint256 internal constant DEFAULT_BUY_LARGE = 10_000;
    uint256 internal constant DEFAULT_SELL_SMALL = 1_000_000;
    uint256 internal constant DEFAULT_SELL_MEDIUM = 5_000_000;
    uint256 internal constant DEFAULT_SELL_LARGE = 10_000_000;
    int24 internal constant TICK_SPACING = 60;
    // BaseCustomAccounting integration in this repo uses the canonical full-range sentinel ticks (0, 0).
    int24 internal constant TICK_LOWER = 0;
    int24 internal constant TICK_UPPER = 0;

    function run() public broadcast returns (ForexSwap hook) {
        RunState memory s;
        s.poolManager = IPoolManager(BASE_SEPOLIA_POOL_MANAGER);
        s.swapRouter = PoolSwapTest(BASE_SEPOLIA_POOL_SWAP_TEST);
        s.usdc = IERC20Like(BASE_SEPOLIA_USDC);
        s.cngn = IERC20Like(BASE_SEPOLIA_CNGN);
        s.usdcPerCngnWad = vm.envOr("ANCHOR_USDC_PER_CNGN_WAD", DEFAULT_USDC_PER_CNGN_WAD);
        s.cngnPerUsdcWad = FullMath.mulDiv(WAD, WAD, s.usdcPerCngnWad);
        s.sqrtPriceX96 = _sqrtPriceX96FromPriceWad(s.cngnPerUsdcWad);
        s.amount0Desired = vm.envOr("ADD_AMOUNT0_DESIRED", DEFAULT_ADD_AMOUNT0_DESIRED);
        s.amount1Desired = vm.envOr("ADD_AMOUNT1_DESIRED", DEFAULT_ADD_AMOUNT1_DESIRED);
        uint256 buySmall = vm.envOr("BUY_SMALL", DEFAULT_BUY_SMALL);
        uint256 buyMedium = vm.envOr("BUY_MEDIUM", DEFAULT_BUY_MEDIUM);
        uint256 buyLarge = vm.envOr("BUY_LARGE", DEFAULT_BUY_LARGE);
        uint256 sellSmall = vm.envOr("SELL_SMALL", DEFAULT_SELL_SMALL);
        uint256 sellMedium = vm.envOr("SELL_MEDIUM", DEFAULT_SELL_MEDIUM);
        uint256 sellLarge = vm.envOr("SELL_LARGE", DEFAULT_SELL_LARGE);
        address existingHookAddress = vm.envOr("EXISTING_HOOK", address(0));
        bool useExistingHook = vm.envOr("USE_EXISTING_HOOK", false) || existingHookAddress != address(0);
        bool skipAdminUpdates = vm.envOr("SKIP_ADMIN_UPDATES", useExistingHook);
        bool forceInitializePool = vm.envOr("FORCE_INITIALIZE_POOL", false);

        _requireBalances(
            s.usdc, s.cngn, s.amount0Desired, s.amount1Desired, buySmall, buyMedium, buyLarge, sellSmall, sellMedium, sellLarge
        );

        (Currency currency0, Currency currency1) = _sortCurrencies(BASE_SEPOLIA_USDC, BASE_SEPOLIA_CNGN);
        require(Currency.unwrap(currency0) == BASE_SEPOLIA_USDC, "unexpected currency0");
        require(Currency.unwrap(currency1) == BASE_SEPOLIA_CNGN, "unexpected currency1");

        if (useExistingHook) {
            require(existingHookAddress != address(0), "EXISTING_HOOK required");
            s.hook = ForexSwap(existingHookAddress);
            s.predictedHook = existingHookAddress;
        } else {
            (s.hook, s.factory, s.salt, s.predictedHook) = _deployHook(s.poolManager);
        }

        if (!skipAdminUpdates) {
            _anchorHookMean(s.hook, s.cngnPerUsdcWad);
            _tuneInventoryResponse(s.hook);
        } else {
            console.log("Skipping admin updates (anchor/inventory tuning)");
        }

        s.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(s.hook))
        });

        _initializePoolIfNeeded(s.poolManager, s.key, s.sqrtPriceX96, forceInitializePool);

        uint256 deadline = block.timestamp + 1 hours;
        (uint256 amount0, uint256 amount1, uint256 shares) =
            _bootstrapLiquidity(s.hook, s.usdc, s.cngn, deadline, s.amount0Desired, s.amount1Desired);

        _logSwapScenario("buy-small", s.hook, s.swapRouter, s.key, s.usdc, s.cngn, buySmall, true, s.usdcPerCngnWad);
        _logSwapScenario("buy-medium", s.hook, s.swapRouter, s.key, s.usdc, s.cngn, buyMedium, true, s.usdcPerCngnWad);
        _logSwapScenario("buy-large", s.hook, s.swapRouter, s.key, s.usdc, s.cngn, buyLarge, true, s.usdcPerCngnWad);
        _logSwapScenario(
            "sell-small", s.hook, s.swapRouter, s.key, s.cngn, s.usdc, sellSmall, false, s.usdcPerCngnWad
        );
        _logSwapScenario(
            "sell-medium", s.hook, s.swapRouter, s.key, s.cngn, s.usdc, sellMedium, false, s.usdcPerCngnWad
        );
        _logSwapScenario(
            "sell-large", s.hook, s.swapRouter, s.key, s.cngn, s.usdc, sellLarge, false, s.usdcPerCngnWad
        );

        _removeAllLiquidity(s.hook, shares, deadline);

        (uint256 reserve0, uint256 reserve1, uint256 liquidityL, uint256 priceWad, bool paused_) = s.hook.getPoolInfo();
        require(!paused_, "hook paused");
        require(reserve0 == 0 && reserve1 == 0 && liquidityL == 0 && priceWad == 0, "post-remove state invalid");

        console.log("PoolManager:", address(s.poolManager));
        console.log("PoolSwapTest:", address(s.swapRouter));
        console.log("USDC:", BASE_SEPOLIA_USDC);
        console.log("cNGN:", BASE_SEPOLIA_CNGN);
        console.log("Anchor usdcPerCngnWad:", s.usdcPerCngnWad);
        console.log("Inventory response WAD:", s.hook.inventoryResponseWad());
        console.log("Init cngnPerUsdcWad:", s.cngnPerUsdcWad);
        console.log("Init sqrtPriceX96:", uint256(s.sqrtPriceX96));
        console.log("CREATE2 factory:", address(s.factory));
        console.log("Hook salt:", uint256(s.salt));
        console.log("Predicted hook:", s.predictedHook);
        console.log("Deployed hook:", address(s.hook));
        console.log("Bootstrap amount0 (USDC):", amount0);
        console.log("Bootstrap amount1 (cNGN):", amount1);
        console.log("Liquidity shares:", shares);
        hook = s.hook;
    }

    function _deployHook(IPoolManager poolManager)
        internal
        returns (ForexSwap hook, Create2FactorySepoliaCNGNSwap factory, bytes32 salt, address predictedHook)
    {
        factory = new Create2FactorySepoliaCNGNSwap();
        bytes memory creationCode = abi.encodePacked(type(ForexSwap).creationCode, abi.encode(poolManager));
        bytes32 initCodeHash = keccak256(creationCode);
        (salt, predictedHook) = _mineHookSalt(address(factory), initCodeHash);
        hook = ForexSwap(factory.deploy(salt, creationCode, broadcaster));
    }

    function _bootstrapLiquidity(
        ForexSwap hook,
        IERC20Like usdc,
        IERC20Like cngn,
        uint256 deadline,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint256 amount0, uint256 amount1, uint256 shares) {
        require(usdc.approve(address(hook), type(uint256).max), "USDC approve failed");
        require(cngn.approve(address(hook), type(uint256).max), "cNGN approve failed");

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

    function _initializePoolIfNeeded(IPoolManager poolManager, PoolKey memory key, uint160 sqrtPriceX96, bool forceInitialize)
        internal
    {
        if (forceInitialize) {
            poolManager.initialize(key, sqrtPriceX96);
            return;
        }

        try poolManager.initialize(key, sqrtPriceX96) {
            console.log("Pool initialized");
        } catch {
            console.log("Pool initialize skipped (already initialized or invalid)");
        }
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
        uint256 anchorUsdcPerCngnWad
    ) internal {
        require(tokenIn.approve(address(swapRouter), type(uint256).max), "tokenIn router approve failed");
        require(tokenOut.approve(address(swapRouter), type(uint256).max), "tokenOut router approve failed");

        (uint256 reserve0Before, uint256 reserve1Before,, uint256 spotBeforeCngnPerUsdcWad,) = hook.getPoolInfo();
        uint256 spotBeforeUsdcPerCngnWad = FullMath.mulDiv(WAD, WAD, spotBeforeCngnPerUsdcWad);
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

        (uint256 reserve0After, uint256 reserve1After, uint256 liquidityL, uint256 spotAfterCngnPerUsdcWad,) =
            hook.getPoolInfo();
        uint256 spotAfterUsdcPerCngnWad = FullMath.mulDiv(WAD, WAD, spotAfterCngnPerUsdcWad);
        uint256 impliedUsdcPerCngnWad = zeroForOne
            ? FullMath.mulDiv(amountIn, WAD, executedOut)
            : FullMath.mulDiv(executedOut, WAD, amountIn);
        uint256 impliedCngnPerUsdcWad = FullMath.mulDiv(WAD, WAD, impliedUsdcPerCngnWad);
        uint256 anchorOut = _anchorOutput(amountIn, zeroForOne, anchorUsdcPerCngnWad);
        uint256 baselineOut = _baselineStableOutput(amountIn, zeroForOne, anchorUsdcPerCngnWad);

        console.log("swap label:", label);
        console.log("swap direction zeroForOne:", zeroForOne);
        console.log("swap amountIn:", amountIn);
        console.log("swap quoteOut:", quotedOut);
        console.log("swap executedOut:", executedOut);
        console.log("swap anchorOut noFee:", anchorOut);
        console.log("swap baselineOut 30bps:", baselineOut);
        console.log("spot before cngnPerUsdcWad:", spotBeforeCngnPerUsdcWad);
        console.log("spot before usdcPerCngnWad:", spotBeforeUsdcPerCngnWad);
        console.log("spot after cngnPerUsdcWad:", spotAfterCngnPerUsdcWad);
        console.log("spot after usdcPerCngnWad:", spotAfterUsdcPerCngnWad);
        console.log("implied execution cngnPerUsdcWad:", impliedCngnPerUsdcWad);
        console.log("implied execution usdcPerCngnWad:", impliedUsdcPerCngnWad);
        console.log("executed vs anchor bps:", _signedDiffBps(executedOut, anchorOut));
        console.log("executed vs baseline bps:", _signedDiffBps(executedOut, baselineOut));
        console.log("quoted vs executed bps:", _signedDiffBps(quotedOut, executedOut));
        console.log("swap hookFeeWad:", feeWad);
        console.log("swap hookFeeAmount:", feeAmount);
        console.log("pre reserve0 USDC:", reserve0Before);
        console.log("pre reserve1 cNGN:", reserve1Before);
        console.log("post reserve0 USDC:", reserve0After);
        console.log("post reserve1 cNGN:", reserve1After);
        console.log("post liquidity:", liquidityL);
        console.log("post cngnPerUsdcWad:", spotAfterCngnPerUsdcWad);
        console.log("post usdcPerCngnWad:", spotAfterUsdcPerCngnWad);
    }

    function _removeAllLiquidity(ForexSwap hook, uint256 shares, uint256 deadline) internal {
        require(shares > 0, "remove amount too small");
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                userInputSalt: ZERO_SALT
            })
        );
    }

    function _requireBalances(
        IERC20Like usdc,
        IERC20Like cngn,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 buySmall,
        uint256 buyMedium,
        uint256 buyLarge,
        uint256 sellSmall,
        uint256 sellMedium,
        uint256 sellLarge
    )
        internal
        view
    {
        uint256 minUsdc = amount0Desired + buySmall + buyMedium + buyLarge;
        uint256 minCngn = amount1Desired + sellSmall + sellMedium + sellLarge;
        require(usdc.balanceOf(broadcaster) >= minUsdc, "insufficient USDC");
        require(cngn.balanceOf(broadcaster) >= minCngn, "insufficient cNGN");
    }

    function _anchorOutput(uint256 amountIn, bool zeroForOne, uint256 anchorUsdcPerCngnWad)
        internal
        pure
        returns (uint256)
    {
        return zeroForOne
            ? FullMath.mulDiv(amountIn, WAD, anchorUsdcPerCngnWad)
            : FullMath.mulDiv(amountIn, anchorUsdcPerCngnWad, WAD);
    }

    function _baselineStableOutput(uint256 amountIn, bool zeroForOne, uint256 anchorUsdcPerCngnWad)
        internal
        pure
        returns (uint256)
    {
        uint256 amountAfterFee = FullMath.mulDiv(amountIn, WAD - BASELINE_FEE_WAD, WAD);
        return _anchorOutput(amountAfterFee, zeroForOne, anchorUsdcPerCngnWad);
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
