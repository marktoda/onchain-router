// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";

contract RegisterV4Pool is Script {
    function run() public {
        address router = vm.envAddress("ROUTER");
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        uint24 fee = uint24(vm.envUint("FEE"));
        int24 tickSpacing = int24(int256(vm.envInt("TICK_SPACING")));
        address hooks = vm.envOr("HOOKS", address(0));

        vm.startBroadcast();
        OnchainRouter(payable(router)).registerV4Pool(tokenA, tokenB, fee, tickSpacing, hooks);
        console2.log("Registered V4 pool on router", router);
    }
}
