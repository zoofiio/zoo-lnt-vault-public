// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {ILntMarket} from "src/interfaces/ILntMarket.sol";
import {IVTSwapHook} from "src/interfaces/IVTSwapHook.sol";

import {Constants} from "src/libraries/Constants.sol";
import {TokenHelper} from "src/libraries/TokenHelper.sol";

contract LntMarket is ILntMarket, TokenHelper, Context, ReentrancyGuard  {
    using StateLibrary for IPoolManager;

    address public poolManager;
    address public permit2;
    address public universalRouter;

    constructor(address _poolManager, address _permit2, address _universalRouter) {
        require(_poolManager != address(0), "Zero address detected");
        require(_permit2 != address(0), "Zero address detected");
        require(_universalRouter != address(0), "Zero address detected");
        poolManager = _poolManager;
        permit2 = _permit2;
        universalRouter = _universalRouter;
    }

    receive() external payable {}

    function buildPoolKey(address VT, address T, address hooks) public pure returns (PoolKey memory key) {
        // Sort token addresses to determine which is currency0/currency1
        address token0;
        address token1;
        
        if (uint160(VT) < uint160(T)) {
            token0 = VT;
            token1 = T;
        } else {
            token0 = T;
            token1 = VT;
        }
        
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0, // No fee as we use custom curve
            tickSpacing: 1, // Minimal tick spacing
            hooks: IHooks(hooks)
        });
    }

    function poolInitialized(address VT, address T, address hooks) external view returns (bool) {
        PoolKey memory poolKey = buildPoolKey(VT, T, hooks);
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(poolKey.toId());
        return sqrtPriceX96 > 0;
    }

    function ensurePoolInitialized(address VT, address T, address hooks) external nonReentrant {
        PoolKey memory poolKey = buildPoolKey(VT, T, hooks);
        (uint160 sqrtPriceX96,,,) = IPoolManager(poolManager).getSlot0(poolKey.toId());
        if (sqrtPriceX96 == 0) {
            uint160 initSqrtPriceX96 = Constants.SQRT_PRICE_1_1;
            IPoolManager(poolManager).initialize(poolKey, initSqrtPriceX96);
        }
    }

    function swapExactTforVT(
        address VT, address T, address hooks,
        uint256 amountInT, uint256 minAmountOutVT
    ) external payable nonReentrant returns (uint256 amountOutVT) {
        _transferIn(T, _msgSender(), amountInT);
        console.log("LntMarket.swapExactTforVT, transfering in $T: ", amountInT / 10 ** _decimals(T));

        uint256 prevBalanceTbeforeSwap = _selfBalance(T);
        uint256 prevBlanceVT = _selfBalance(VT);

        // Build the pool key for the T-VT pair
        PoolKey memory poolKey = buildPoolKey(VT, T, hooks);
        
        // Determine if VT is token0 or token1 based on address comparison
        bool isVTToken0 = uint160(VT) < uint160(T);
        
        // Set swap direction
        bool zeroForOne = !isVTToken0;
        
        // Set a reasonable deadline (e.g., 30 minutes from now)
        uint256 deadline = block.timestamp + 30 minutes;
        
        _doSwap(
            poolKey,
            zeroForOne,
            T,
            amountInT,
            minAmountOutVT,
            deadline
        );

        uint256 swappedAmountT = prevBalanceTbeforeSwap - _selfBalance(T);
        console.log("LntMarket.swapTForExactVT, used $T: ", swappedAmountT);

        amountOutVT = _selfBalance(VT) - prevBlanceVT;
        console.log("LntMarket.swapTForExactVT, got $VT: ", amountOutVT);
        _transferOut(VT, _msgSender(), _selfBalance(VT) - prevBlanceVT);
        
        return amountOutVT;
    }

    function swapExactVTforT(
        address VT, address T, address hooks,
        uint256 amountInVT, uint256 minAmountOutT
    ) external payable returns (uint256 amountOutT) {
        _transferIn(VT, _msgSender(), amountInVT);
        console.log("LntMarket.swapExactVTforT, transfering in $VT: ", amountInVT / 10 ** _decimals(VT));

        uint256 prevBalanceVTbeforeSwap = _selfBalance(VT);
        uint256 prevBlanceT = _selfBalance(T);

        // Build the pool key for the VT-T pair
        PoolKey memory poolKey = buildPoolKey(VT, T, hooks);
        
        // Determine if VT is token0 or token1 based on address comparison
        bool isVTToken0 = uint160(VT) < uint160(T);
        
        // Set swap direction
        bool zeroForOne = isVTToken0;
        
        // Set a reasonable deadline (e.g., 30 minutes from now)
        uint256 deadline = block.timestamp + 30 minutes;
        
        _doSwap(
            poolKey,
            zeroForOne,
            VT,
            amountInVT,
            minAmountOutT,
            deadline
        );

        uint256 swappedAmountVT = prevBalanceVTbeforeSwap - _selfBalance(VT);
        console.log("LntMarket.swapExactVTforT, used $VT: ", swappedAmountVT / 10 ** _decimals(VT));

        amountOutT = _selfBalance(T) - prevBlanceT;
        console.log("LntMarket.swapExactVTforT, got $T: ", amountOutT / (10 ** _decimals(T)));
        _transferOut(T, _msgSender(), _selfBalance(T) - prevBlanceT);
        
        return amountOutT;
    }

    function _doSwap(
        PoolKey memory poolKey,
        bool zeroForOne,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal virtual {
        // Record balances before swap
        uint256 balanceBeforeTokenIn = _balance(address(this), tokenIn);
        address tokenOut = Currency.unwrap(poolKey.currency0) == tokenIn ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);
        uint256 balanceBeforeTokenOut = _balance(address(this), tokenOut);
        
        console.log("Before swap: token in balance: %s, token out balance: %s", 
            balanceBeforeTokenIn / (10 ** _decimals(tokenIn)),
            balanceBeforeTokenOut / (10 ** _decimals(tokenOut))
        );

        // Approve token in for the router using Permit2
        if (tokenIn != Constants.NATIVE_TOKEN) {
            _approveWithPermit2(tokenIn, uint160(amountIn), uint48(deadline));
        }
        
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        
        // Encode V4Router actions for exact output swap
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        
        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minAmountOut),
                hookData: Constants.ZERO_BYTES
            })
        );
        
        // Parameters for SETTLE_ALL and TAKE_ALL
        params[1] = abi.encode(zeroForOne ? poolKey.currency0 : poolKey.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? poolKey.currency1 : poolKey.currency0, 0);
        
        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);
        
        // Execute the swap
        uint256 msgValue = (tokenIn == Constants.NATIVE_TOKEN) ? amountIn : 0;
        IUniversalRouter(universalRouter).execute{value: msgValue}(commands, inputs, deadline);

        uint256 balanceAfterTokenIn = _balance(address(this), tokenIn);
        uint256 balanceAfterTokenOut = _balance(address(this), tokenOut);
        
        uint256 actualTokenInUsed = balanceBeforeTokenIn - balanceAfterTokenIn;
        uint256 actualTokenOutReceived = balanceAfterTokenOut - balanceBeforeTokenOut;
        
        console.log("After swap: token in balance: %s, token out balance: %s", 
            balanceAfterTokenIn / (10 ** _decimals(tokenIn)),
            balanceAfterTokenOut / (10 ** _decimals(tokenOut))
        );
        console.log("Actual token in used: %s, Actual token out received: %s", 
            actualTokenInUsed / (10 ** _decimals(tokenIn)),
            actualTokenOutReceived / (10 ** _decimals(tokenOut))
        );
    }

    function _approveWithPermit2(address token, uint160 amount, uint48 expiration) internal {
        // First approve Permit2 to spend our tokens
        _safeApprove(token, permit2, type(uint256).max);
        
        // Then approve the router via Permit2
        IPermit2(permit2).approve(token, universalRouter, amount, expiration);
    }
}