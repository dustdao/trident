pragma solidity ^0.8.2;
pragma abicoder v2;

import "../../contracts/SwapRouter.sol";
import "../../contracts/interfaces/IBentoBox.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SwapRouterHarness is SwapRouter {
    IERC20 public tokenA;

    constructor(address WETH, IBentoBoxV1 bento)
        SwapRouter(WETH, bento) public { }

    // A wrapper for exactInput
    function callExactInputSingle(address tokenIn, address tokenOut, address pool, address recipient, bool unwrapBento, uint256 deadline, uint256 amountIn, uint256 amountOutMinimum) public returns (uint256) {
        ExactInputSingleParams memory exactInputSingleParams;
        exactInputSingleParams = ExactInputSingleParams({tokenIn:tokenIn, tokenOut:tokenOut, pool:pool, recipient:recipient,unwrapBento:unwrapBento,deadline:deadline,amountIn:amountIn,amountOutMinimum:amountOutMinimum});
        return super.exactInputSingle(exactInputSingleParams);
    }

    // Override with empty function
    function exactInputSingle(ExactInputSingleParams memory params)
        public
        override
        payable
        returns (uint256 amountOut) { }



    function callExactInput(address tokenIn1, address pool1, address tokenIn2, address pool2,
        address tokenOut,
        address recipient,
        bool unwrapBento,
        uint256 deadline,
        uint256 amountIn,
        uint256 amountOutMinimum)
        public
        virtual
        payable
        returns (uint256 amount)
    { 
        Path[] memory paths = new Path[](2);
        paths[0] = Path({tokenIn : tokenIn1, pool: pool1});
        paths[1] = Path({tokenIn : tokenIn2, pool: pool2});
        ExactInputParams memory exactInputParams = ExactInputParams({
                path : paths, 
                tokenOut : tokenOut, 
                recipient: recipient,
                unwrapBento : unwrapBento,
                deadline : deadline,
                amountIn : amountIn,
                amountOutMinimum : amountOutMinimum });
        return super.exactInput(exactInputParams);
    }


    function exactInput(ExactInputParams memory params)
        public
        override
        payable
        returns (uint256 amount)
    { }



    // A wrapper and override for addLiquidityUnbalance
    function callAddLiquidityUnbalanced(address tokenIn, uint256 amount, address pool,  address to, uint256 deadline,uint256 minliquidity) public returns (uint256) {
        IPool.liquidityInputOptimal[] memory liquidityInput = new IPool.liquidityInputOptimal[](1);
        liquidityInput[0] = IPool.liquidityInputOptimal({token: tokenIn, native : false , amount : amount });
        return super.addLiquidityUnbalanced(liquidityInput, pool, to, deadline, minliquidity);
    }

    function addLiquidityUnbalanced(
        IPool.liquidityInputOptimal[] memory liquidityInput,
        address pool,
        address to,
        uint256 deadline,
        uint256 minLiquidity
    ) public override returns (uint256 liquidity) { }


    function callAddLiquidityBalanced(
        address tokenIn, 
        uint256 amount,
        address pool,
        address to,
        uint256 deadline
    ) external checkDeadline(deadline) returns (IPool.liquidityAmount[] memory liquidityOptimal, uint256 liquidity) {
        IPool.liquidityInput[] memory liquidityInput = new IPool.liquidityInput[](1);
        liquidityInput[0] = IPool.liquidityInput({token: tokenIn , native : false , amountDesired : amount , amountMin : 0});
        return super.addLiquidityBalanced(liquidityInput, pool, to, deadline);
    }

    function addLiquidityBalanced(
        IPool.liquidityInput[] memory liquidityInput,
        address pool,
        address to,
        uint256 deadline
    ) public override returns (IPool.liquidityAmount[] memory liquidityOptimal, uint256 liquidity) {

    }
    
    function tokenBalanceOf(address token, address user) public returns (uint256) {
        return IERC20(token).balanceOf(user);
    }

    function ethBalance(address user) public returns (uint256) {
        return user.balance;
    }
}