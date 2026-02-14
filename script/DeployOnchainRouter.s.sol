// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";

contract DeployOnchainRouter is Script {
    address constant v2Factory = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address constant v3Factory = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant poolManager = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address constant weth = 0x4200000000000000000000000000000000000006;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();
        OnchainRouter router = new OnchainRouter(v2Factory, v3Factory, poolManager, weth);
        console2.log("OnchainRouter deployed at", address(router));
    }
}
