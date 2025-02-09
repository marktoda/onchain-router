// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

import {Pool, Quote} from "../base/OnchainRouterStructs.sol";

library QuoteLibrary {
    function combine(Quote memory firstLeg, Quote memory secondLeg) internal pure returns (Quote memory) {
        Pool[] memory path = new Pool[](firstLeg.path.length + secondLeg.path.length);
        for (uint256 i = 0; i < firstLeg.path.length; i++) {
            path[i] = firstLeg.path[i];
        }
        for (uint256 i = 0; i < secondLeg.path.length; i++) {
            path[firstLeg.path.length + i] = secondLeg.path[i];
        }
        return Quote({path: path, amountIn: firstLeg.amountIn, amountOut: secondLeg.amountOut});
    }

    function createQuoteSingle(Pool memory pool, uint256 amountIn, uint256 amountOut)
        internal
        pure
        returns (Quote memory)
    {
        Pool[] memory path = new Pool[](1);
        path[0] = pool;
        return Quote({path: path, amountIn: amountIn, amountOut: amountOut});
    }

    function better(Quote memory first, Quote memory second) internal pure returns (Quote memory) {
        if (first.amountIn == second.amountIn) {
            // exact input
            if (first.amountOut == 0) {
                return second;
            } else if (second.amountOut == 0) {
                return first;
            } else {
                return first.amountOut > second.amountOut ? first : second;
            }
        } else {
            // exact output
            if (first.amountIn == 0) {
                return second;
            } else if (second.amountIn == 0) {
                return first;
            } else {
                return first.amountIn < second.amountIn ? first : second;
            }
        }
    }
}
