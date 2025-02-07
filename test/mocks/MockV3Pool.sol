// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;
pragma abicoder v2;

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "v3-core/contracts/libraries/TickMath.sol";

contract MockV3Pool is IUniswapV3Pool {
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override fee;
    int24 public override tickSpacing;

    uint160 public sqrtPriceX96;
    int24 public tick;
    uint128 public override liquidity;

    uint256 private constant Q96 = 2**96;
    uint256 private constant FEE_DENOMINATOR = 1000000;

    // Add a mapping to store tick bitmap
    mapping(int16 => uint256) private _tickBitmap;

    constructor(address _token0, address _token1, uint24 _fee) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _fee == 500 ? 10 : _fee == 3000 ? 60 : 200;
        
        // Initialize with some reasonable values for testing
        sqrtPriceX96 = 79228162514264337593543950336; // 1:1 price
        tick = 0;
        liquidity = 1000000 * 2**96; // Some reasonable liquidity

        // Initialize some ticks for testing
        int24 tickLower = -10 * tickSpacing;
        int24 tickUpper = 10 * tickSpacing;
        
        // Initialize tick bitmap for the range
        for (int24 t = tickLower; t <= tickUpper; t += tickSpacing) {
            (int16 wordPos, uint8 bitPos) = position(t / tickSpacing);
            _tickBitmap[wordPos] |= 1 << bitPos;
        }
    }

    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick) % 256);
    }

    function tickBitmap(int16 wordPos) external view override returns (uint256) {
        return _tickBitmap[wordPos];
    }

    function slot0() external view override returns (
        uint160 sqrtPriceX96_,
        int24 tick_,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    ) {
        return (sqrtPriceX96, tick, 0, 1, 1, 0, true);
    }

    function observations(uint256)
        external
        view
        override
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        )
    {
        return (uint32(block.timestamp), 0, 0, true);
    }

    function observe(uint32[] calldata) external pure override returns (int56[] memory, uint160[] memory) {
        int56[] memory tickCumulatives = new int56[](1);
        uint160[] memory secondsPerLiquidityCumulativeX128s = new uint160[](1);
        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }

    function snapshotCumulativesInside(int24, int24)
        external
        pure
        override
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        return (0, 0, 0);
    }

    function factory() external view override returns (address) { return msg.sender; }
    function maxLiquidityPerTick() external pure override returns (uint128) { return uint128((2**128) - 1); }
    function positions(bytes32) external pure override returns (uint128, uint256, uint256, uint128, uint128) {
        return (0, 0, 0, 0, 0);
    }

    function initialize(uint160 _sqrtPriceX96) external override {
        require(sqrtPriceX96 == 0, 'AI');
        sqrtPriceX96 = _sqrtPriceX96;
    }

    function mint(address, int24, int24, uint128, bytes calldata) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function collect(address, int24, int24, uint128, uint128) external pure override returns (uint128, uint128) {
        return (0, 0);
    }

    function burn(int24, int24, uint128) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external override returns (int256 amount0, int256 amount1) {
        require(amountSpecified != 0, 'AS');
        bool exactInput = amountSpecified > 0;

        uint256 state_sqrtPriceX96 = sqrtPriceX96;
        uint256 price = (state_sqrtPriceX96 * state_sqrtPriceX96) / Q96;
        uint256 absAmount = uint256(amountSpecified > 0 ? amountSpecified : -amountSpecified);
        uint256 feeAmount = (absAmount * fee) / FEE_DENOMINATOR;

        if (exactInput) {
            if (zeroForOne) {
                amount0 = int256(absAmount);
                amount1 = -int256((absAmount - feeAmount) * Q96 / price);
            } else {
                amount0 = -int256((absAmount - feeAmount) * price / Q96);
                amount1 = int256(absAmount);
            }
        } else {
            if (zeroForOne) {
                amount0 = int256((absAmount * price / Q96) / (FEE_DENOMINATOR - fee) * FEE_DENOMINATOR);
                amount1 = -int256(absAmount);
            } else {
                amount0 = -int256(absAmount);
                amount1 = int256((absAmount * Q96 / price) / (FEE_DENOMINATOR - fee) * FEE_DENOMINATOR);
            }
        }

        recipient;
        sqrtPriceLimitX96;
        data;
    }

    function flash(address, uint256, uint256, bytes calldata) external pure override {}
    function increaseObservationCardinalityNext(uint16) external pure override {}
    function setFeeProtocol(uint8, uint8) external pure override {}

    function collectProtocol(address, uint128, uint128) external pure override returns (uint128, uint128) {
        return (0, 0);
    }

    function feeGrowthGlobal0X128() external pure override returns (uint256) {
        return 0;
    }

    function feeGrowthGlobal1X128() external pure override returns (uint256) {
        return 0;
    }

    function protocolFees() external pure override returns (uint128, uint128) {
        return (0, 0);
    }

    function ticks(int24) external pure override returns (
        uint128 liquidityGross,
        int128 liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        int56 tickCumulativeOutside,
        uint160 secondsPerLiquidityOutsideX128,
        uint32 secondsOutside,
        bool initialized
    ) {
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
} 