// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script } from "forge-std/src/Script.sol";
import { console } from "forge-std/src/console.sol";
import { PoolManager } from "v4-core/src/PoolManager.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { ForexSwap } from "../src/ForexSwap.sol";

contract Create2Factory {
    error DeploymentFailed();

    function deploy(bytes32 salt, bytes memory creationCode) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }

        if (deployed == address(0)) revert DeploymentFailed();
    }
}

/// @notice Minimal Anvil script that deploys PoolManager and ForexSwap at a hook-valid address.
contract AnvilScript is Script {
    uint160 private constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager public manager;

    function run() public {
        vm.startBroadcast();
        manager = IPoolManager(address(new PoolManager(msg.sender)));
        Create2Factory factory = new Create2Factory();
        bytes memory creationCode = abi.encodePacked(type(ForexSwap).creationCode, abi.encode(manager));
        bytes32 initCodeHash = keccak256(creationCode);
        (bytes32 salt, address hookAddress) = _mineHookSalt(address(factory), initCodeHash);
        address deployed = factory.deploy(salt, creationCode);
        vm.stopBroadcast();

        console.log("PoolManager:", address(manager));
        console.log("CREATE2 factory:", address(factory));
        console.log("Hook salt:", uint256(salt));
        console.log("ForexSwap:", deployed);
        console.log("Predicted hook address:", hookAddress);
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
