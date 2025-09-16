// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IProtocolOwner} from "src/interfaces/IProtocolOwner.sol";

interface IAethiraVTOracle is IProtocolOwner {
    
    event UpdateATHRewardsPerNodePerDay(uint256 previous, uint256 current);

    event UpdateATHRewardsEndTime(uint256 previous, uint256 current);

    function aVT() external view returns (uint256);

    function athRewardsPerNodePerDay() external view returns (uint256);

    function athRewardsEndTime() external view returns (uint256);
    
}
