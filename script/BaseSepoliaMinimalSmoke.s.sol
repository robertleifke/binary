// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/src/console.sol";
import {BaseScript} from "./Base.s.sol";
import {ForexSwap} from "../src/ForexSwap.sol";
import {BaseCustomAccounting} from "uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {Math} from "v4-core/lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Create2FactoryBaseSepoliaMinimal {
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

contract BaseSepoliaMinimalSmoke is BaseScript {
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_SEPOLIA_POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant BASE_SEPOLIA_CNGN = 0xe2387F04d3858e7Cb64Ef5Ed6617f9B2fcEEAfa2;

    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant DEFAULT_USDC_PER_CNGN_WAD = 724_454_000_000_000;
    uint256 internal constant DEFAULT_ADD_AMOUNT0 = 579_560;
    uint256 internal constant DEFAULT_ADD_AMOUNT1 = 800_000_000;
    uint256 internal constant DEFAULT_SMALL_SWAP_IN = 10_000;
    uint256 internal constant DEFAULT_INVENTORY_RESPONSE_WAD = 25e16;

    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = 0;
    int24 internal constant TICK_UPPER = 0;

    function run() public broadcast returns (ForexSwap hook) {
        IPoolManager poolManager = IPoolManager(BASE_SEPOLIA_POOL_MANAGER);
        PoolSwapTest swapRouter = PoolSwapTest(BASE_SEPOLIA_POOL_SWAP_TEST);
        IERC20Like usdc = IERC20Like(BASE_SEPOLIA_USDC);
        IERC20Like cngn = IERC20Like(BASE_SEPOLIA_CNGN);

        uint256 usdcPerCngnWad = vm.envOr("ANCHOR_USDC_PER_CNGN_WAD", DEFAULT_USDC_PER_CNGN_WAD);
        uint256 cngnPerUsdcWad = FullMath.mulDiv(WAD, WAD, usdcPerCngnWad);
        uint160 sqrtPriceX96 = _sqrtPriceX96FromPriceWad(cngnPerUsdcWad);

        uint256 addAmount0 = vm.envOr("ADD_AMOUNT0_DESIRED", DEFAULT_ADD_AMOUNT0);
        uint256 addAmount1 = vm.envOr("ADD_AMOUNT1_DESIRED", DEFAULT_ADD_AMOUNT1);
        uint256 smallSwapIn = vm.envOr("SMALL_SWAP_IN", DEFAULT_SMALL_SWAP_IN);

        _requireBalances(usdc, cngn, addAmount0 + smallSwapIn, addAmount1);

        Create2FactoryBaseSepoliaMinimal factory = new Create2FactoryBaseSepoliaMinimal();
        bytes memory creationCode = abi.encodePacked(type(ForexSwap).creationCode, abi.encode(poolManager));
        bytes32 initCodeHash = keccak256(creationCode);
        (bytes32 salt, address predictedHook) = _mineHookSalt(address(factory), initCodeHash);
        hook = ForexSwap(factory.deploy(salt, creationCode, broadcaster));

        _anchorHookMean(hook, cngnPerUsdcWad);
        _tuneInventoryResponse(hook);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(BASE_SEPOLIA_USDC),
            currency1: Currency.wrap(BASE_SEPOLIA_CNGN),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(key, sqrtPriceX96);

        require(usdc.approve(address(hook), type(uint256).max), "USDC approve hook failed");
        require(cngn.approve(address(hook), type(uint256).max), "cNGN approve hook failed");
        require(usdc.approve(address(swapRouter), type(uint256).max), "USDC approve router failed");
        require(cngn.approve(address(swapRouter), type(uint256).max), "cNGN approve router failed");

        // 1) addLiquidity
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: addAmount0,
                amount1Desired: addAmount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                userInputSalt: ZERO_SALT
            })
        );

        // 2) small swap (USDC -> cNGN)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(smallSwapIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // 3) removeLiquidity (all shares)
        uint256 shares = hook.balanceOf(broadcaster);
        require(shares > 0, "no shares after add");
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                userInputSalt: ZERO_SALT
            })
        );

        (uint256 reserve0After, uint256 reserve1After, uint256 liquidityAfter, uint256 priceAfter, bool paused_) = hook.getPoolInfo();

        console.log("PoolManager:", address(poolManager));
        console.log("PoolSwapTest:", address(swapRouter));
        console.log("USDC:", BASE_SEPOLIA_USDC);
        console.log("cNGN:", BASE_SEPOLIA_CNGN);
        console.log("Factory:", address(factory));
        console.log("Hook salt:", uint256(salt));
        console.log("Predicted hook:", predictedHook);
        console.log("Deployed hook:", address(hook));
        console.log("addAmount0:", addAmount0);
        console.log("addAmount1:", addAmount1);
        console.log("smallSwapIn:", smallSwapIn);
        console.log("final reserve0:", reserve0After);
        console.log("final reserve1:", reserve1After);
        console.log("final liquidity:", liquidityAfter);
        console.log("final priceWad:", priceAfter);
        console.log("final paused:", paused_);
    }

    function _anchorHookMean(ForexSwap hook, uint256 anchoredMeanWad) internal {
        (, uint256 width, uint256 baseHookFeeWad) = hook.logNormalParams();
        hook.updateLogNormalParams(anchoredMeanWad, width, baseHookFeeWad);
    }

    function _tuneInventoryResponse(ForexSwap hook) internal {
        uint256 responseWad = vm.envOr("INVENTORY_RESPONSE_WAD", DEFAULT_INVENTORY_RESPONSE_WAD);
        hook.updateInventoryResponseWad(responseWad);
    }

    function _requireBalances(IERC20Like usdc, IERC20Like cngn, uint256 minUsdc, uint256 minCngn) internal view {
        require(usdc.balanceOf(broadcaster) >= minUsdc, "insufficient USDC");
        require(cngn.balanceOf(broadcaster) >= minCngn, "insufficient cNGN");
    }

    function _sqrtPriceX96FromPriceWad(uint256 priceWad) internal pure returns (uint160 sqrtPriceX96) {
        uint256 q192 = uint256(FixedPoint96.Q96) * uint256(FixedPoint96.Q96);
        uint256 ratioX192 = FullMath.mulDiv(priceWad, q192, WAD);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
    }

    function _mineHookSalt(address deployer, bytes32 initCodeHash) internal view returns (bytes32 salt, address hook) {
        for (uint256 candidate = 0; candidate < type(uint24).max; candidate++) {
            salt = bytes32(candidate);
            hook = vm.computeCreate2Address(salt, initCodeHash, deployer);
            if (uint160(hook) & Hooks.ALL_HOOK_MASK == REQUIRED_HOOK_FLAGS && hook.code.length == 0) {
                return (salt, hook);
            }
        }
        revert("No hook salt found");
    }
}
