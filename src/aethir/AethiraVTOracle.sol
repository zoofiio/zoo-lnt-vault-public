// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolOwner} from "src/ProtocolOwner.sol";
import {IAethiraVTOracle} from "src/interfaces/aethir/IAethiraVTOracle.sol";

contract AethiraVTOracle is IAethiraVTOracle, ProtocolOwner, ReentrancyGuard {

    uint256 public athRewardsPerNodePerDay;
    uint256 public athRewardsEndTime;

    constructor(address protocol, uint256 _athRewardsPerNodePerDay, uint256 _athRewardsEndTime) ProtocolOwner(protocol) {
        athRewardsPerNodePerDay = _athRewardsPerNodePerDay;
        athRewardsEndTime = _athRewardsEndTime;
    }

    function aVT() external view returns (uint256) {
        if (block.timestamp >= athRewardsEndTime) {
            return 0;
        }
        uint256 remainingDays = (athRewardsEndTime - block.timestamp) / 1 days;
        return athRewardsPerNodePerDay * remainingDays;
    }

    function updateATHRewardsPerNodePerDay(uint256 newATHRewardsPerNodePerDay) external nonReentrant onlyOwner {
        uint256 previous = athRewardsPerNodePerDay;
        athRewardsPerNodePerDay = newATHRewardsPerNodePerDay;
        emit UpdateATHRewardsPerNodePerDay(previous, newATHRewardsPerNodePerDay);
    }

    function updateATHRewardsEndTime(uint256 newATHRewardsEndTime) external nonReentrant onlyOwner {
        uint256 previous = athRewardsEndTime;
        athRewardsEndTime = newATHRewardsEndTime;
        emit UpdateATHRewardsEndTime(previous, newATHRewardsEndTime);
    }
    
}
