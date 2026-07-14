// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Minimal V3 factory stand-in for tests that only exercise V4 pools.
/// @dev PathGenerator's constructor probes feeAmountTickSpacing for the default tiers
/// and its V3 path generation calls getPool; returning zero for both makes the router
/// see no V3 pools without needing a real factory deployment.
contract MockV3Factory {
    function feeAmountTickSpacing(uint24) external pure returns (int24) {
        return 0;
    }

    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

/// @notice Minimal V2 factory stand-in: no pairs exist.
contract MockV2Factory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }
}
