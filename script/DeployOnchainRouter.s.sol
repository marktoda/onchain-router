// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console2} from "forge-std/Script.sol";
import {OnchainRouter} from "../src/OnchainRouter.sol";

contract DeployOnchainRouter is Script {
    address constant v2Factory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant v3Factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {}

    /// @dev Owner is read from the ROUTER_OWNER env var, not msg.sender: under some forge
    /// invocations (multiple keys, certain keystore/hardware flows, a dry run promoted to
    /// broadcast without --sender) msg.sender falls back to Foundry's DEFAULT_SENDER,
    /// which would make an unrecoverable address the owner (Ownable2Step has no renounce
    /// or reset path), permanently freezing the intermediate set.
    function run() public {
        address initialOwner = vm.envAddress("ROUTER_OWNER");
        vm.startBroadcast();
        OnchainRouter router = new OnchainRouter(v2Factory, v3Factory, poolManager, weth, initialOwner);
        console2.log("OnchainRouter deployed at", address(router));
        console2.log("Initial owner", initialOwner);
    }
}
