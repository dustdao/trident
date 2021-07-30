// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.0;

import "../deployer/MasterDeployer.sol";
import "../interfaces/IBentoBoxMinimal.sol";
import "../interfaces/IPool.sol";
import "../interfaces/ITridentCallee.sol";
import "../libraries/TridentMath.sol";
import "../libraries/RebaseLibrary.sol";
import "./TridentERC20.sol";
import "hardhat/console.sol";

/// @notice Trident exchange pool template with constant product formula for swapping between an ERC-20 token pair.
/// @dev The reserves are stored as bento shares. However, the constant product curve is applied to the underlying amounts.
///      The API uses the underlying amounts.
/*IPool,*/
contract ConstantProductPool is TridentERC20 {
    using RebaseLibrary for Rebase;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Sync(uint256 reserveShares0, uint256 reserveShares4);

    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    uint8 internal constant PRECISION = 112;
    uint256 internal constant MAX_FEE = 10000; // @dev 100%.
    uint256 internal constant MAX_FEE_SQUARE = 100000000;
    uint256 public immutable swapFee;
    uint256 internal immutable MAX_FEE_MINUS_SWAP_FEE;

    address internal immutable barFeeTo;
    IBentoBoxMinimal internal immutable bento;
    MasterDeployer internal immutable masterDeployer;
    address public immutable token0;
    address public immutable token1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast;

    uint112 internal reserveShares0;
    uint112 internal reserveShares1;
    uint32 internal blockTimestampLast;

    uint256 public constant poolType = 2;
    uint256 public constant assetsCount = 2;
    address[] public assets;

    uint256 private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, "MIRIN: LOCKED");
        unlocked = 2;
        _;
        unlocked = 1;
    }

    struct Holdings {
        uint256 shares0;
        uint256 shares1;
        uint256 amount0;
        uint256 amount1;
    }

    struct Rebases {
        Rebase total0;
        Rebase total1;
    }

    /// @dev Only set immutable variables here - state changes made here will not be used.
    constructor(bytes memory _deployData, address _masterDeployer) {
        (address tokenA, address tokenB, uint256 _swapFee, bool _twapSupport) = abi.decode(
            _deployData,
            (address, address, uint256, bool)
        );

        require(tokenA != address(0), "ConstantProductPoolWithTWAP: ZERO_ADDRESS");
        require(tokenB != address(0), "ConstantProductPoolWithTWAP: ZERO_ADDRESS");
        require(tokenA != tokenB, "ConstantProductPoolWithTWAP: IDENTICAL_ADDRESSES");
        require(_swapFee <= MAX_FEE, "ConstantProductPoolWithTWAP: INVALID_SWAP_FEE");

        token0 = tokenA;
        token1 = tokenB;
        assets.push(tokenA);
        assets.push(tokenB);
        swapFee = _swapFee;
        MAX_FEE_MINUS_SWAP_FEE = MAX_FEE - _swapFee;
        bento = IBentoBoxMinimal(MasterDeployer(_masterDeployer).bento());
        barFeeTo = MasterDeployer(_masterDeployer).barFeeTo();
        masterDeployer = MasterDeployer(_masterDeployer);
        unlocked = 1;
        if (_twapSupport) {
            blockTimestampLast = 1;
        }
    }

    function mint(address to) public lock returns (uint256 liquidity) {
        (Holdings memory reserves, uint32 _blockTimestampLast, Rebases memory rebase) = _getReserves();
        Holdings memory balances = _balance(rebase);
        uint256 _totalSupply = totalSupply;
        _mintFee(reserves.amount0, reserves.amount1, _totalSupply);

        uint256 amount0 = balances.amount0 - reserves.amount0;
        uint256 amount1 = balances.amount1 - reserves.amount1;

        uint256 computed = TridentMath.sqrt(balances.amount0 * balances.amount1);
        if (_totalSupply == 0) {
            liquidity = computed - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            uint256 k = TridentMath.sqrt(reserves.amount0 * reserves.amount1);
            liquidity = ((computed - k) * _totalSupply) / k;
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _update(reserves, balances, _blockTimestampLast);
        kLast = computed;
        emit Mint(msg.sender, amount0, amount1, to);
    }

    // function burn(address to, bool unwrapBento)
    //     public
    //     override
    //     lock
    //     returns (TokenAmount[] memory withdrawnAmounts)
    // {
    //     (uint256 reserveAmount0, uint256 reserveAmount1, uint32 _blockTimestampLast, Rebase total0, Rebase total1) = _getReserves();
    //     uint256 _totalSupply = totalSupply;
    //     _mintFee(reserveAmount0, reserveAmount1, _totalSupply);

    //     uint256 liquidity = balanceOf[address(this)];
    //     (uint256 balanceShares0, uint256 balanceShares1) = _balance();
    //     uint256 amount0 = (liquidity * balanceShares0) / _totalSupply;
    //     uint256 amount1 = (liquidity * balanceShares1) / _totalSupply;

    //     _burn(address(this), liquidity);

    //     _transfer(token0, amount0, to, unwrapBento);
    //     _transfer(token1, amount1, to, unwrapBento);

    //     balanceShares0 -= amount0;
    //     balanceShares1 -= amount1;

    //     _update(balanceShares0, balanceShares1, _reserveShares0, _reserveShares1, _blockTimestampLast);
    //     kLast = TridentMath.sqrt(balanceShares0 * balanceShares1);

    //     withdrawnAmounts = new TokenAmount[](2);
    //     withdrawnAmounts[0] = TokenAmount({token: address(token0), amount: amount0});
    //     withdrawnAmounts[1] = TokenAmount({token: address(token1), amount: amount1});

    //     emit Burn(msg.sender, amount0, amount1, to);
    // }

    // function burnLiquiditySingle(
    //     address tokenOut,
    //     address to,
    //     bool unwrapBento
    // ) public override lock returns (uint256 amount) {
    //     (uint256 reserveAmount0, uint256 reserveAmount1, uint32 _blockTimestampLast, Rebase total0, Rebase total1) = _getReserves();
    //     uint256 _totalSupply = totalSupply;
    //     _mintFee(_reserveShares0, _reserveShares1, _totalSupply);

    //     uint256 liquidity = balanceOf[address(this)];
    //     (uint256 balanceShares0, uint256 balanceShares1) = _balance();
    //     uint256 amount0 = (liquidity * balanceShares0) / _totalSupply;
    //     uint256 amount1 = (liquidity * balanceShares1) / _totalSupply;

    //     _burn(address(this), liquidity);

    //     if (tokenOut == address(token0)) {
    //         // @dev Swap token1 for token0.
    //         // @dev Calculate amountOut as if the user first withdrew balanced liquidity and then swapped token1 for token0.
    //         amount0 += _getAmountOut(amount1, _reserveShares1 - amount1, _reserveShares0 - amount0);
    //         _transfer(token0, amount0, to, unwrapBento);
    //         balanceShares0 -= amount0;
    //         amount = amount0;
    //     } else {
    //         // @dev Swap token0 for token1.
    //         require(tokenOut == address(token1), "ConstantProductPoolWithTWAP: INVALID_OUTPUT_TOKEN");
    //         amount1 += _getAmountOut(amount0, _reserveShares0 - amount0, _reserveShares1 - amount1);
    //         _transfer(token1, amount1, to, unwrapBento);
    //         balanceShares1 -= amount1;
    //         amount = amount1;
    //     }

    //     _update(balanceShares0, balanceShares1, _reserveShares0, _reserveShares1, _blockTimestampLast);
    //     kLast = TridentMath.sqrt(balanceShares0 * balanceShares1);
    //     emit Burn(msg.sender, amount0, amount1, to);
    // }

    // function swapWithoutContext(
    //     address tokenIn,
    //     address tokenOut,
    //     address recipient,
    //     bool unwrapBento
    // ) external override lock returns (uint256 amountOut) {
    //     (uint256 reserveAmount0, uint256 reserveAmount1, uint32 _blockTimestampLast, Rebase total0, Rebase total1) = _getReserves();
    //     (uint256 balanceShares0, uint256 balanceShares1) = _balance();
    //     uint256 amountIn;

    //     if (tokenIn == address(token0)) {
    //         require(tokenOut == address(token1), "ConstantProductPoolWithTWAP: INVALID_OUTPUT_TOKEN");
    //         amountIn = balanceShares0 - _reserveShares0;
    //         amountOut = _getAmountOut(amountIn, _reserveShares0, _reserveShares1);
    //         _transfer(token1, amountOut, recipient, unwrapBento);
    //         _update(balanceShares0, balanceShares1 - amountOut, _reserveShares0, _reserveShares1, _blockTimestampLast);
    //     } else {
    //         require(tokenIn == address(token1), "ConstantProductPoolWithTWAP: INVALID_INPUT_TOKEN");
    //         require(tokenOut == address(token0), "ConstantProductPoolWithTWAP: INVALID_OUTPUT_TOKEN");
    //         amountIn = balanceShares1 - _reserveShares1;
    //         amountOut = _getAmountOut(amountIn, _reserveShares1, _reserveShares0);
    //         _transfer(token0, amountOut, recipient, unwrapBento);
    //         _update(balanceShares0 - amountOut, balanceShares1, _reserveShares0, _reserveShares1, _blockTimestampLast);
    //     }
    //     emit Swap(recipient, tokenIn, tokenOut, amountIn, amountOut);
    // }

    // function swapWithContext(
    //     address tokenIn,
    //     address tokenOut,
    //     bytes calldata context,
    //     address recipient,
    //     bool unwrapBento,
    //     uint256 amountIn
    // ) public override lock returns (uint256 amountOut) {
    //     (uint256 reserveAmount0, uint256 reserveAmount1, uint32 _blockTimestampLast, Rebase total0, Rebase total1) = _getReserves();

    //     if (tokenIn == address(token0)) {
    //         require(tokenOut == address(token1), "ConstantProductPoolWithTWAP: INVALID_OUTPUT_TOKEN");

    //         amountOut = _getAmountOut(amountIn, _reserveShares0, _reserveShares1);
    //         _processSwap(tokenIn, tokenOut, recipient, amountIn, amountOut, context, unwrapBento);

    //         (uint256 balanceShares0, uint256 balanceShares1) = _balance();
    //         require(balanceShares0 - _reserveShares0 >= amountIn, "ConstantProductPoolWithTWAP: INSUFFICIENT_AMOUNT_IN");

    //         _update(balanceShares0, balanceShares1 - amountOut, _reserveShares0, _reserveShares1, _blockTimestampLast);
    //     } else {
    //         require(tokenIn == address(token1), "ConstantProductPoolWithTWAP: INVALID_INPUT_TOKEN");
    //         require(tokenOut == address(token0), "ConstantProductPoolWithTWAP: INVALID_OUTPUT_TOKEN");

    //         amountOut = _getAmountOut(amountIn, _reserveShares1, _reserveShares0);
    //         _processSwap(tokenIn, tokenOut, recipient, amountIn, amountOut, context, unwrapBento);

    //         (uint256 balanceShares0, uint256 balanceShares1) = _balance();
    //         require(balanceShares1 - _reserveShares1 >= amountIn, "ConstantProductPoolWithTWAP: INSUFFICIENT_AMOUNT_IN");

    //         _update(balanceShares0 - amountOut, balanceShares1, _reserveShares0, _reserveShares1, _blockTimestampLast);
    //     }

    //     emit Swap(recipient, tokenIn, tokenOut, amountIn, amountOut);
    // }

    // function _processSwap(
    //     address tokenIn,
    //     address tokenOut,
    //     address to,
    //     uint256 amountIn,
    //     uint256 amountOut,
    //     bytes calldata data,
    //     bool unwrapBento
    // ) internal {
    //     _transfer(tokenOut, amountOut, to, unwrapBento);
    //     if (data.length > 0) ITridentCallee(to).tridentCallback(tokenIn, tokenOut, amountIn, amountOut, data);
    // }

    function _getReserves()
        internal
        view
        returns (
            Holdings memory _reserves,
            uint32 _blockTimestampLast,
            Rebases memory _rebase
        )
    {
        uint112 _reserveShares0 = reserveShares0;
        uint112 _reserveShares1 = reserveShares1;
        _blockTimestampLast = blockTimestampLast;
        _rebase = Rebases({total0: bento.totals(token0), total1: bento.totals(token1)});
        _reserves = Holdings({
            shares0: _reserveShares0,
            shares1: _reserveShares1,
            amount0: _rebase.total0.toElastic(_reserveShares0),
            amount1: _rebase.total1.toElastic(_reserveShares1)
        });
    }

    function _balance() internal view returns (uint256 balanceShares0, uint256 balanceShares1) {
        balanceShares0 = bento.balanceOf(token0, address(this));
        balanceShares1 = bento.balanceOf(token1, address(this));
    }

    function _balance(Rebases memory _rebase) internal view returns (Holdings memory _balances) {
        (uint256 balanceShares0, uint256 balanceShares1) = _balance();
        _balances = Holdings({
            shares0: balanceShares0,
            shares1: balanceShares1,
            amount0: _rebase.total0.toElastic(balanceShares0),
            amount1: _rebase.total1.toElastic(balanceShares1)
        });
    }

    function _update(
        Holdings memory _reserves,
        Holdings memory _balances,
        uint32 _blockTimestampLast
    ) internal {
        require(_balances.shares0 <= type(uint112).max && _balances.shares1 <= type(uint112).max, "SAHRES_OVERFLOW");
        require(_balances.amount0 < type(uint128).max && _balances.amount1 < type(uint128).max, "AMOUNT_OVERFLOW");

        if (blockTimestampLast == 0) {
            // TWAP support is disabled for gas efficiency
            reserveShares0 = uint112(_balances.shares0);
            reserveShares1 = uint112(_balances.shares1);
        } else {
            uint32 blockTimestamp = uint32(block.timestamp % 2**32);
            if (blockTimestamp != _blockTimestampLast && _reserves.amount0 != 0 && _reserves.amount1 != 0) {
                unchecked {
                    uint32 timeElapsed = blockTimestamp - _blockTimestampLast;
                    uint256 price0 = (_reserves.amount1 << PRECISION) / _reserves.amount0;
                    price0CumulativeLast += price0 * timeElapsed;
                    uint256 price1 = (_reserves.amount0 << PRECISION) / _reserves.amount1;
                    price1CumulativeLast += price1 * timeElapsed;
                }
            }
            reserveShares0 = uint112(_balances.shares0);
            reserveShares1 = uint112(_balances.shares1);
            blockTimestampLast = blockTimestamp;
        }

        emit Sync(_balances.amount0, _balances.amount1);
    }

    function _mintFee(
        uint256 _reserveAmount0,
        uint256 _reserveAmount1,
        uint256 _totalSupply
    ) internal returns (uint256 computed) {
        uint256 _kLast = kLast;
        if (_kLast != 0) {
            computed = TridentMath.sqrt(_reserveAmount0 * _reserveAmount1);
            if (computed > _kLast) {
                // @dev barFee % of increase in liquidity.
                // @dev NB It's going to be slightly less than barFee % in reality due to the Math.
                uint256 barFee = MasterDeployer(masterDeployer).barFee();
                uint256 liquidity = (_totalSupply * (computed - _kLast) * barFee) / computed / MAX_FEE;
                if (liquidity > 0) {
                    _mint(barFeeTo, liquidity);
                }
            }
        }
    }

    // function _getAmountOut(
    //     uint256 amountIn,
    //     uint256 reserveIn,
    //     uint256 reserveOut
    // ) internal view returns (uint256 amountOut) {
    //     uint256 amountInWithFee = amountIn * MAX_FEE_MINUS_SWAP_FEE;
    //     amountOut = (amountInWithFee * reserveOut) / (reserveIn * MAX_FEE + amountInWithFee);
    // }

    // function _transfer(
    //     address token,
    //     uint256 amount,
    //     address to,
    //     bool unwrapBento
    // ) internal {
    //     if (unwrapBento) {
    //         bento.withdraw(token, address(this), to, 0, amount);
    //     } else {
    //         bento.transfer(token, address(this), to, amount);
    //     }
    // }

    // function getAmountOut(
    //     address tokenIn,
    //     address, /*tokenOut*/
    //     uint256 amountIn
    // ) external view returns (uint256 amountOut) {
    //     (uint256 reserveAmount0, uint256 reserveAmount1, , Rebase total0, Rebase total1) = _getReserves();
    //     if (tokenIn == token0) {
    //         amountOut = _getAmountOut(amountIn, _reserveShares0, _reserveShares1);
    //     } else {
    //         amountOut = _getAmountOut(amountIn, _reserveShares1, _reserveShares0);
    //     }
    // }

    // function getOptimalLiquidityInAmounts(liquidityInput[] memory liquidityInputs)
    //     external
    //     view
    //     override
    //     returns (TokenAmount[] memory)
    // {
    //     if (liquidityInputs[0].token == token1) {
    //         // @dev Swap tokens to be in order.
    //         (liquidityInputs[0], liquidityInputs[1]) = (liquidityInputs[1], liquidityInputs[0]);
    //     }
    //     uint112 _reserveShares0;
    //     uint112 _reserveShares1;
    //     TokenAmount[] memory liquidityOptimal = new TokenAmount[](2);
    //     liquidityOptimal[0] = TokenAmount({
    //         token: liquidityInputs[0].token,
    //         amount: liquidityInputs[0].amountDesired
    //     });
    //     liquidityOptimal[1] = TokenAmount({
    //         token: liquidityInputs[1].token,
    //         amount: liquidityInputs[1].amountDesired
    //     });

    //     (_reserveShares0, _reserveShares1) = (reserveShares0, reserveShares4);

    //     if (_reserveShares0 == 0) {
    //         return liquidityOptimal;
    //     }

    //     uint256 amount1Optimal = (liquidityInputs[0].amountDesired * _reserveShares1) / _reserveShares0;
    //     if (amount1Optimal <= liquidityInputs[1].amountDesired) {
    //         require(
    //             amount1Optimal >= liquidityInputs[1].amountMin,
    //             "ConstantProductPoolWithTWAP: INSUFFICIENT_B_AMOUNT"
    //         );
    //         liquidityOptimal[1].amount = amount1Optimal;
    //     } else {
    //         uint256 amount0Optimal = (liquidityInputs[1].amountDesired * _reserveShares0) / _reserveShares1;
    //         require(
    //             amount0Optimal >= liquidityInputs[0].amountMin,
    //             "ConstantProductPoolWithTWAP: INSUFFICIENT_A_AMOUNT"
    //         );
    //         liquidityOptimal[0].amount = amount0Optimal;
    //     }

    //     return liquidityOptimal;
    // }
}
