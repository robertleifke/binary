// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/src/console.sol";
import {BaseScript} from "./Base.s.sol";
import {ForexSwap} from "../src/ForexSwap.sol";
import {BaseCustomAccounting} from "uniswap-hooks/src/base/BaseCustomAccounting.sol";
import {CurrencySettler} from "uniswap-hooks/src/utils/CurrencySettler.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract Create2FactoryMinimal {
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

contract SimplePoolSwapRouter {
    using CurrencySettler for Currency;

    IPoolManager internal immutable manager;

    struct CallbackData {
        address sender;
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey memory key, SwapParams memory params) external returns (BalanceDelta delta) {
        delta = abi.decode(manager.unlock(abi.encode(CallbackData({sender: msg.sender, key: key, params: params}))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");

        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta = manager.swap(data.key, data.params, "");

        if (delta.amount0() < 0) {
            data.key.currency0.settle(manager, data.sender, uint256(int256(-delta.amount0())), false);
        } else if (delta.amount0() > 0) {
            data.key.currency0.take(manager, data.sender, uint256(int256(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            data.key.currency1.settle(manager, data.sender, uint256(int256(-delta.amount1())), false);
        } else if (delta.amount1() > 0) {
            data.key.currency1.take(manager, data.sender, uint256(int256(delta.amount1())), false);
        }

        return abi.encode(delta);
    }
}

contract MinimalCycle is BaseScript {
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint160 private constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint256 private constant DEFAULT_ADD0 = 1_000_000;
    uint256 private constant DEFAULT_ADD1 = 1_000_000;
    uint256 private constant DEFAULT_SWAP_IN = 10_000;

    function run() public broadcast {
        uint256 add0 = vm.envOr("ADD_AMOUNT0", DEFAULT_ADD0);
        uint256 add1 = vm.envOr("ADD_AMOUNT1", DEFAULT_ADD1);
        uint256 swapIn = vm.envOr("SWAP_IN", DEFAULT_SWAP_IN);

        PoolManager manager = new PoolManager(broadcaster);
        SimplePoolSwapRouter router = new SimplePoolSwapRouter(manager);

        MockERC20 tokenA = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 tokenB = new MockERC20("cNGN", "cNGN", 6);
        tokenA.mint(broadcaster, 1_000_000_000_000);
        tokenB.mint(broadcaster, 1_000_000_000_000);

        (Currency currency0, Currency currency1) = _sortCurrencies(address(tokenA), address(tokenB));

        Create2FactoryMinimal factory = new Create2FactoryMinimal();
        bytes memory creationCode = abi.encodePacked(type(ForexSwap).creationCode, abi.encode(IPoolManager(address(manager))));
        bytes32 initCodeHash = keccak256(creationCode);
        (bytes32 salt, address predictedHook) = _mineHookSalt(address(factory), initCodeHash);
        ForexSwap hook = ForexSwap(factory.deploy(salt, creationCode, broadcaster));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, SQRT_PRICE_1_1);

        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);

        uint256 amount0Desired = Currency.unwrap(currency0) == address(tokenA) ? add0 : add1;
        uint256 amount1Desired = Currency.unwrap(currency1) == address(tokenB) ? add1 : add0;

        // 1) addLiquidity
        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: ZERO_SALT
            })
        );

        // 2) one small swap
        bool zeroForOne = Currency.unwrap(currency0) == address(tokenA);
        BalanceDelta delta = router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(swapIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // 3) removeLiquidity (all shares)
        uint256 shares = hook.balanceOf(broadcaster);
        hook.removeLiquidity(
            BaseCustomAccounting.RemoveLiquidityParams({
                liquidity: shares,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 hours,
                tickLower: 0,
                tickUpper: 0,
                userInputSalt: ZERO_SALT
            })
        );

        (uint256 reserve0After, uint256 reserve1After, uint256 liquidityAfter, uint256 priceAfter, bool paused_) = hook.getPoolInfo();

        console.log("PoolManager:", address(manager));
        console.log("Factory:", address(factory));
        console.log("Hook salt:", uint256(salt));
        console.log("Predicted hook:", predictedHook);
        console.log("Deployed hook:", address(hook));
        console.log("TokenA:", address(tokenA));
        console.log("TokenB:", address(tokenB));
        console.log("Swap delta amount0:", uint256(int256(delta.amount0() > 0 ? delta.amount0() : -delta.amount0())));
        console.log("Swap delta amount1:", uint256(int256(delta.amount1() > 0 ? delta.amount1() : -delta.amount1())));
        console.log("Final reserve0:", reserve0After);
        console.log("Final reserve1:", reserve1After);
        console.log("Final liquidity:", liquidityAfter);
        console.log("Final priceWad:", priceAfter);
        console.log("Paused:", paused_);
    }

    function _sortCurrencies(address tokenA, address tokenB) internal pure returns (Currency currency0, Currency currency1) {
        currency0 = Currency.wrap(tokenA);
        currency1 = Currency.wrap(tokenB);
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }
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

