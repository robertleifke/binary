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
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {Math} from "v4-core/lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Create2FactorySepoliaCNGN {
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

contract BaseSepoliaCNGNPool is BaseScript {
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant BASE_SEPOLIA_CNGN = 0xe2387F04d3858e7Cb64Ef5Ed6617f9B2fcEEAfa2;

    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant DEFAULT_USDC_PER_CNGN_WAD = 724_454_000_000_000;
    uint256 internal constant DEFAULT_USDC_AMOUNT = 724_454;
    uint256 internal constant DEFAULT_CNGN_AMOUNT = 1_000_000_000;
    uint256 internal constant DEFAULT_INVENTORY_RESPONSE_WAD = 25e16;

    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -120;
    int24 internal constant TICK_UPPER = 120;

    function run() public broadcast returns (ForexSwap hook) {
        IPoolManager poolManager = IPoolManager(BASE_SEPOLIA_POOL_MANAGER);
        IERC20Like usdc = IERC20Like(BASE_SEPOLIA_USDC);
        IERC20Like cngn = IERC20Like(BASE_SEPOLIA_CNGN);

        uint256 usdcAmount = vm.envOr("ADD_AMOUNT0_DESIRED", DEFAULT_USDC_AMOUNT);
        uint256 cngnAmount = vm.envOr("ADD_AMOUNT1_DESIRED", DEFAULT_CNGN_AMOUNT);
        uint256 usdcPerCngnWad = vm.envOr("ANCHOR_USDC_PER_CNGN_WAD", DEFAULT_USDC_PER_CNGN_WAD);
        uint256 cngnPerUsdcWad = FullMath.mulDiv(WAD, WAD, usdcPerCngnWad);
        uint160 sqrtPriceX96 = _sqrtPriceX96FromPriceWad(cngnPerUsdcWad);

        _requireBalances(usdc, cngn, usdcAmount, cngnAmount);

        (Currency currency0, Currency currency1) = _sortCurrencies(BASE_SEPOLIA_USDC, BASE_SEPOLIA_CNGN);
        require(Currency.unwrap(currency0) == BASE_SEPOLIA_USDC, "unexpected currency0");
        require(Currency.unwrap(currency1) == BASE_SEPOLIA_CNGN, "unexpected currency1");

        Create2FactorySepoliaCNGN factory;
        bytes32 salt;
        address predictedHook;
        (hook, factory, salt, predictedHook) = _deployHook(poolManager);
        _anchorHookMean(hook, cngnPerUsdcWad);
        _tuneInventoryResponse(hook);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(key, sqrtPriceX96);

        uint256 deadline = block.timestamp + 1 hours;
        require(usdc.approve(address(hook), type(uint256).max), "USDC approve failed");
        require(cngn.approve(address(hook), type(uint256).max), "cNGN approve failed");

        ForexSwap.BootstrapTrace memory trace = hook.traceBootstrapPlan(sqrtPriceX96, usdcAmount, cngnAmount);
        uint256 walletUsdcBefore = usdc.balanceOf(broadcaster);
        uint256 walletCngnBefore = cngn.balanceOf(broadcaster);
        (uint256 reserve0Before, uint256 reserve1Before,,,) = hook.getPoolInfo();

        (uint256 amount0, uint256 amount1, uint256 shares) =
            hook.addLiquidityWithSlippage(usdcAmount, cngnAmount, 0, 0, deadline);
        require(amount0 > 0 && amount1 > 0 && shares > 0, "bootstrap quote failed");

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: usdcAmount,
                amount1Desired: cngnAmount,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                userInputSalt: ZERO_SALT
            })
        );

        uint256 walletUsdcAfter = usdc.balanceOf(broadcaster);
        uint256 walletCngnAfter = cngn.balanceOf(broadcaster);
        (uint256 reserve0, uint256 reserve1, uint256 liquidityL, uint256 priceWad, bool paused_) = hook.getPoolInfo();
        require(!paused_, "hook paused");

        console.log("PoolManager:", address(poolManager));
        console.log("USDC:", BASE_SEPOLIA_USDC);
        console.log("cNGN:", BASE_SEPOLIA_CNGN);
        console.log("Anchor usdcPerCngnWad:", usdcPerCngnWad);
        console.log("Inventory response WAD:", hook.inventoryResponseWad());
        console.log("Init cngnPerUsdcWad:", cngnPerUsdcWad);
        console.log("Init sqrtPriceX96:", uint256(sqrtPriceX96));
        console.log("CREATE2 factory:", address(factory));
        console.log("Hook salt:", uint256(salt));
        console.log("Predicted hook:", predictedHook);
        console.log("Deployed hook:", address(hook));
        console.log("Trace normalizedAmount0Desired:", trace.normalizedAmount0Desired);
        console.log("Trace normalizedAmount1Desired:", trace.normalizedAmount1Desired);
        console.log("Trace desiredPriceWad:", trace.desiredPriceWad);
        console.log("Trace xRatio:", trace.xRatio);
        console.log("Trace yRatio:", trace.yRatio);
        console.log("Trace requiredYForX:", trace.requiredYForX);
        console.log("Trace requiredXForY:", trace.requiredXForY);
        console.log("Trace amount0Limited:", trace.amount0Limited);
        console.log("Trace stableExact:", trace.stableExact);
        console.log("Trace quotedAmount0 normalized:", trace.amount0);
        console.log("Trace quotedAmount1 normalized:", trace.amount1);
        console.log("Trace quotedAmount0 raw:", trace.rawAmount0);
        console.log("Trace quotedAmount1 raw:", trace.rawAmount1);
        console.log("Trace clip0Bps:", trace.clip0Bps);
        console.log("Trace clip1Bps:", trace.clip1Bps);
        console.log("Trace deltaL:", trace.deltaL);
        console.log("Trace shares:", trace.shares);
        console.log("Bootstrap amount0 (USDC):", amount0);
        console.log("Bootstrap amount1 (cNGN):", amount1);
        console.log("Liquidity shares:", shares);
        console.log("Wallet USDC before:", walletUsdcBefore);
        console.log("Wallet cNGN before:", walletCngnBefore);
        console.log("Wallet USDC after:", walletUsdcAfter);
        console.log("Wallet cNGN after:", walletCngnAfter);
        console.log("Actual USDC transferred:", walletUsdcBefore - walletUsdcAfter);
        console.log("Actual cNGN transferred:", walletCngnBefore - walletCngnAfter);
        console.log("Reserve0 before:", reserve0Before);
        console.log("Reserve1 before:", reserve1Before);
        console.log("Reserve0 delta:", reserve0 - reserve0Before);
        console.log("Reserve1 delta:", reserve1 - reserve1Before);
        console.log("Final reserve0 (USDC):", reserve0);
        console.log("Final reserve1 (cNGN):", reserve1);
        console.log("Final liquidity:", liquidityL);
        console.log("Final cngnPerUsdcWad:", priceWad);
        console.log("Final usdcPerCngnWad:", FullMath.mulDiv(WAD, WAD, priceWad));
    }

    function _deployHook(IPoolManager poolManager)
        internal
        returns (ForexSwap hook, Create2FactorySepoliaCNGN factory, bytes32 salt, address predictedHook)
    {
        factory = new Create2FactorySepoliaCNGN();
        bytes memory creationCode = abi.encodePacked(type(ForexSwap).creationCode, abi.encode(poolManager));
        bytes32 initCodeHash = keccak256(creationCode);
        (salt, predictedHook) = _mineHookSalt(address(factory), initCodeHash);
        hook = ForexSwap(factory.deploy(salt, creationCode, broadcaster));
    }

    function _anchorHookMean(ForexSwap hook, uint256 anchoredMeanWad) internal {
        (, uint256 width, uint256 baseHookFeeWad) = hook.logNormalParams();
        hook.updateLogNormalParams(anchoredMeanWad, width, baseHookFeeWad);
    }

    function _tuneInventoryResponse(ForexSwap hook) internal {
        uint256 responseWad = vm.envOr("INVENTORY_RESPONSE_WAD", DEFAULT_INVENTORY_RESPONSE_WAD);
        hook.updateInventoryResponseWad(responseWad);
    }

    function _requireBalances(IERC20Like usdc, IERC20Like cngn, uint256 usdcAmount, uint256 cngnAmount) internal view {
        require(usdc.balanceOf(broadcaster) >= usdcAmount, "insufficient USDC");
        require(cngn.balanceOf(broadcaster) >= cngnAmount, "insufficient cNGN");
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
