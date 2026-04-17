// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/src/console.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
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
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

contract Create2FactorySepolia {
    error DeploymentFailed();

    function deploy(bytes32 salt, bytes memory creationCode) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }

        if (deployed == address(0)) revert DeploymentFailed();
    }
}

contract BaseSepoliaE2E is BaseScript {
    struct RunState {
        IPoolManager poolManager;
        PoolSwapTest swapRouter;
        MockERC20 tokenA;
        MockERC20 tokenB;
        ForexSwap hook;
        Create2FactorySepolia factory;
        PoolKey key;
        bytes32 salt;
        address predictedHook;
    }

    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_SEPOLIA_POOL_SWAP_TEST = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;
    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant TOKEN_SUPPLY = 1_000_000e18;
    uint256 internal constant ADD_AMOUNT0_DESIRED = 100e18;
    uint256 internal constant ADD_AMOUNT1_DESIRED = 250e18;
    uint256 internal constant SWAP_AMOUNT_IN = 1e18;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -120;
    int24 internal constant TICK_UPPER = 120;

    function run() public broadcast returns (ForexSwap hook) {
        RunState memory s;
        s.poolManager = IPoolManager(BASE_SEPOLIA_POOL_MANAGER);
        s.swapRouter = PoolSwapTest(BASE_SEPOLIA_POOL_SWAP_TEST);
        s.tokenA = new MockERC20("ForexSwap Base Sepolia A", "FXA", 18);
        s.tokenB = new MockERC20("ForexSwap Base Sepolia B", "FXB", 18);
        s.tokenA.mint(broadcaster, TOKEN_SUPPLY);
        s.tokenB.mint(broadcaster, TOKEN_SUPPLY);

        (Currency currency0, Currency currency1) = _sortCurrencies(address(s.tokenA), address(s.tokenB));
        (s.hook, s.factory, s.salt, s.predictedHook) = _deployHook(s.poolManager);

        s.key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(s.hook))
        });

        s.poolManager.initialize(s.key, SQRT_PRICE_1_1);
        uint256 deadline = block.timestamp + 1 hours;
        (uint256 amount0, uint256 amount1, uint256 shares) = _bootstrapLiquidity(s.hook, s.tokenA, s.tokenB, deadline);
        uint256 quotedOut = _executeSwap(s.hook, s.swapRouter, s.key, currency1, s.tokenA, s.tokenB);
        _removeHalfLiquidity(s.hook, shares, deadline);

        (uint256 reserve0, uint256 reserve1, uint256 liquidityL, uint256 priceWad, bool paused_) = s.hook.getPoolInfo();
        require(!paused_, "hook paused");
        require(reserve0 > 0 && reserve1 > 0 && liquidityL > 0 && priceWad > 0, "post-state invalid");

        console.log("PoolManager:", address(s.poolManager));
        console.log("PoolSwapTest:", address(s.swapRouter));
        console.log("TokenA:", address(s.tokenA));
        console.log("TokenB:", address(s.tokenB));
        console.log("CREATE2 factory:", address(s.factory));
        console.log("Hook salt:", uint256(s.salt));
        console.log("Predicted hook:", s.predictedHook);
        console.log("Deployed hook:", address(s.hook));
        console.log("Bootstrap amount0:", amount0);
        console.log("Bootstrap amount1:", amount1);
        console.log("Liquidity shares:", shares);
        console.log("Quoted swap output:", quotedOut);
        console.log("Final reserve0:", reserve0);
        console.log("Final reserve1:", reserve1);
        console.log("Final liquidity:", liquidityL);
        console.log("Final priceWad:", priceWad);
        hook = s.hook;
    }

    function _deployHook(IPoolManager poolManager)
        internal
        returns (ForexSwap hook, Create2FactorySepolia factory, bytes32 salt, address predictedHook)
    {
        factory = new Create2FactorySepolia();
        bytes memory creationCode = abi.encodePacked(type(ForexSwap).creationCode, abi.encode(poolManager));
        bytes32 initCodeHash = keccak256(creationCode);
        (salt, predictedHook) = _mineHookSalt(address(factory), initCodeHash);
        hook = ForexSwap(factory.deploy(salt, creationCode));
    }

    function _bootstrapLiquidity(ForexSwap hook, MockERC20 tokenA, MockERC20 tokenB, uint256 deadline)
        internal
        returns (uint256 amount0, uint256 amount1, uint256 shares)
    {
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);

        (amount0, amount1, shares) =
            hook.addLiquidityWithSlippage(ADD_AMOUNT0_DESIRED, ADD_AMOUNT1_DESIRED, 0, 0, deadline);
        require(amount0 > 0 && amount1 > 0 && shares > 0, "bootstrap quote failed");

        hook.addLiquidity(
            BaseCustomAccounting.AddLiquidityParams({
                amount0Desired: ADD_AMOUNT0_DESIRED,
                amount1Desired: ADD_AMOUNT1_DESIRED,
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

    function _executeSwap(
        ForexSwap hook,
        PoolSwapTest swapRouter,
        PoolKey memory key,
        Currency currency1,
        MockERC20 tokenA,
        MockERC20 tokenB
    ) internal returns (uint256 quotedOut) {
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);

        quotedOut = hook.calculateAmountOut(SWAP_AMOUNT_IN, true);
        require(quotedOut > 0, "swap quote failed");

        uint256 token1BalanceBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(broadcaster);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(SWAP_AMOUNT_IN),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 token1BalanceAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(broadcaster);
        require(token1BalanceAfter > token1BalanceBefore, "swap output missing");
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

    function _sortCurrencies(address tokenA, address tokenB) internal pure returns (Currency currency0, Currency currency1) {
        currency0 = Currency.wrap(tokenA);
        currency1 = Currency.wrap(tokenB);
        if (Currency.unwrap(currency0) > Currency.unwrap(currency1)) {
            (currency0, currency1) = (currency1, currency0);
        }
    }

    function _mineHookSalt(address deployer, bytes32 initCodeHash) internal view returns (bytes32 salt, address hook) {
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
