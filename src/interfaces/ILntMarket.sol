// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface ILntMarket {

    function poolManager() external view returns (address);

    function permit2() external view returns (address);

    function universalRouter() external view returns (address);

    function buildPoolKey(address VT, address T, address hooks) external pure returns (PoolKey memory key);

    function poolInitialized(address VT, address T,  address hooks) external view returns (bool);

    function ensurePoolInitialized(address VT, address T, address hooks) external;

    function swapExactTforVT(
        address VT, address T, address hooks,
        uint256 amountInT, uint256 minAmountOutVT
    ) external payable returns (uint256 amountOutVT);

    function swapExactVTforT(
        address VT, address T, address hooks,
        uint256 amountInVT, uint256 minAmountOutT
    ) external payable returns (uint256 amountOutT);

}