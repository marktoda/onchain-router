// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.6;

import {IUniswapV2Pair} from "v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockV2Pair is IUniswapV2Pair {
    address public override token0;
    address public override token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    bytes32 public override DOMAIN_SEPARATOR;
    bytes32 public constant override PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public override nonces;

    uint256 private constant _MINIMUM_LIQUIDITY = 1000;
    uint256 private constant RESERVE_FACTOR = 997;

    function initialize(address _token0, address _token1) external override {
        token0 = _token0;
        token1 = _token1;
        // Set initial reserves for testing
        reserve0 = 1000000 * 10 ** 18;
        reserve1 = 1000000 * 10 ** 18;
        totalSupply = 2000000 * 10 ** 18;
    }

    function getReserves()
        external
        view
        override
        returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast)
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function name() external pure override returns (string memory) {
        return "Mock V2 Pair";
    }

    function symbol() external pure override returns (string memory) {
        return "MOCKV2";
    }

    function decimals() external pure override returns (uint8) {
        return 18;
    }

    function MINIMUM_LIQUIDITY() external pure override returns (uint256) {
        return _MINIMUM_LIQUIDITY;
    }

    function factory() external view override returns (address) {
        return msg.sender;
    }

    function price0CumulativeLast() external pure override returns (uint256) {
        return 0;
    }

    function price1CumulativeLast() external pure override returns (uint256) {
        return 0;
    }

    function kLast() external pure override returns (uint256) {
        return 0;
    }

    function mint(address to) external override returns (uint256 liquidity) {
        to;
        return 0;
    }

    function burn(address to) external override returns (uint256 amount0, uint256 amount1) {
        to;
        return (0, 0);
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] = allowance[from][msg.sender] - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        balanceOf[from] = balanceOf[from] - value;
        balanceOf[to] = balanceOf[to] + value;
        emit Transfer(from, to, value);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external override {
        require(amount0Out > 0 || amount1Out > 0, "V2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = this.getReserves();
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "V2: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            if (amount0Out > 0) {
                balance0 = uint256(_reserve0) - amount0Out;
                uint256 amountIn = getAmountIn(amount0Out, uint256(_reserve1), uint256(_reserve0));
                balance1 = uint256(_reserve1) + amountIn;
            }
            if (amount1Out > 0) {
                balance1 = uint256(_reserve1) - amount1Out;
                uint256 amountIn = getAmountIn(amount1Out, uint256(_reserve0), uint256(_reserve1));
                balance0 = uint256(_reserve0) + amountIn;
            }
            require(balance0 * balance1 >= uint256(_reserve0) * uint256(_reserve1), "V2: K");
        }

        _update(uint112(balance0), uint112(balance1));

        if (amount0Out > 0) MockERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) MockERC20(token1).transfer(to, amount1Out);

        data; // Silence unused variable warning
    }

    function _update(uint112 _reserve0, uint112 _reserve1) private {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = uint32(block.timestamp);
    }

    function skim(address to) external override {
        to;
    }

    function sync() external override {}

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        require(deadline >= block.timestamp, "V2: EXPIRED");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, "V2: INVALID_SIGNATURE");
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    // Helper functions for exact output calculations
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "V2: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "V2: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * RESERVE_FACTOR;
        amountIn = (numerator / denominator) + 1;
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "V2: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "V2: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * RESERVE_FACTOR;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }
}

