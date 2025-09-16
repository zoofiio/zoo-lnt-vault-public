// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

import {ProtocolOwner} from "src/ProtocolOwner.sol";
import {IAethirRedeemStrategy} from "src/interfaces/aethir/IAethirRedeemStrategy.sol";

contract AethirRedeemStrategy is IAethirRedeemStrategy, ProtocolOwner, ReentrancyGuard {
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    RedeemStrategy public redeemStrategy;

    uint256 internal _nextRedeemTimeWindowId;
    mapping(uint256 => RedeemTimeWindow) internal _redeemTimeWindowsById;
    DoubleEndedQueue.Bytes32Deque internal _orderedRedeemTimeWindows;

    constructor(address protocol) ProtocolOwner(protocol) {
        redeemStrategy = RedeemStrategy.ONLY_WITHIN_REDEEM_TIME_WINDOW;

        _appendRedeemTimeWindow(1757721600, 15 days);  // 2025.9.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1765584000, 15 days);  // 2025.12.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1773360000, 15 days);  // 2026.3.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1781308800, 15 days);  // 2026.6.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1789257600, 15 days);  // 2026.9.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1797120000, 15 days);  // 2026.12.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1804896000, 15 days);  // 2027.3.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1812844800, 15 days);  // 2027.6.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1820793600, 15 days);  // 2027.9.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1828656000, 15 days);  // 2027.12.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1836518400, 15 days);  // 2028.3.13 00:00:00 GMT+0000
        _appendRedeemTimeWindow(1844467200, 15 days);  // 2028.6.13 00:00:00 GMT+0000
    }

    function redeemTimeWindowsCount() external view returns (uint256) {
        return _orderedRedeemTimeWindows.length();
    }

    function redeemTimeWindows(uint256 index, uint256 count) external view returns (uint256[] memory startTimes, uint256[] memory durations) {
        require(index >=0 && index < _orderedRedeemTimeWindows.length(), "Index out of bounds");
        require(count > 0 && index + count <= _orderedRedeemTimeWindows.length(), "Invalid count");

        startTimes = new uint256[](count);
        durations = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 redeemTimeWindowId = uint256(_orderedRedeemTimeWindows.at(index + i));
            RedeemTimeWindow memory window = _redeemTimeWindowsById[redeemTimeWindowId];
            startTimes[i] = window.startTime;
            durations[i] = window.duration;
        }
    }

    function canRedeem() external view returns (bool) {
        if (redeemStrategy == RedeemStrategy.ALLOWED) {
            return true;
        }
        else if (redeemStrategy == RedeemStrategy.FORBIDDEN) {
            return false;
        }
        else {
            return _isWithinTimeWindow(block.timestamp);
        }
    }

    function updateRedeemStrategy(RedeemStrategy newStrategy) external nonReentrant onlyOwner {
        require(newStrategy != redeemStrategy, "New strategy must differ from current");
        RedeemStrategy previous = redeemStrategy;
        redeemStrategy = newStrategy;
        emit UpdateRedeemStrategy(previous, newStrategy);
    }

    function appendRedeemTimeWindow(uint256 startTime, uint256 duration) external nonReentrant onlyOwner {
        _appendRedeemTimeWindow(startTime, duration);
    }

    function removeLastRedeemTimeWindow() external nonReentrant onlyOwner {
        require(_orderedRedeemTimeWindows.length() > 0, "No redeem time windows to remove");
        uint256 lastRedeemTimeWindowId = uint256(_orderedRedeemTimeWindows.popBack());
        RedeemTimeWindow memory lastWindow = _redeemTimeWindowsById[lastRedeemTimeWindowId];
        emit RemoveRedeemTimeWindow(lastWindow.startTime, lastWindow.duration);
    }

    function _appendRedeemTimeWindow(uint256 startTime, uint256 duration) internal {
        require(startTime > 0 && duration > 0, "Start time and duration must be positive");

        if (_orderedRedeemTimeWindows.length() > 0) {
            uint256 lastRedeemTimeWindowId = uint256(_orderedRedeemTimeWindows.back());
            RedeemTimeWindow memory lastWindow = _redeemTimeWindowsById[lastRedeemTimeWindowId];
            require(startTime >= lastWindow.startTime + lastWindow.duration, "New time window must start after the last one ends");
        }

        _nextRedeemTimeWindowId++;
        _redeemTimeWindowsById[_nextRedeemTimeWindowId] = RedeemTimeWindow({
            id: _nextRedeemTimeWindowId,
            startTime: startTime,
            duration: duration
        });
        _orderedRedeemTimeWindows.pushBack(bytes32(_nextRedeemTimeWindowId));
        
        emit AddRedeemTimeWindow(startTime, duration);
    }


    function _isWithinTimeWindow(uint256 timestamp) internal view returns (bool) {
        uint256 length = _orderedRedeemTimeWindows.length();
        if (length == 0) return false;
        
        uint256 left = 0;
        uint256 right = length - 1;
        
        while (left <= right) {
            uint256 mid = left + (right - left) / 2;
            uint256 redeemTimeWindowId = uint256(_orderedRedeemTimeWindows.at(mid));
            RedeemTimeWindow memory window = _redeemTimeWindowsById[redeemTimeWindowId];
            uint256 windowEndTime = window.startTime + window.duration;
            
            if (timestamp >= window.startTime && timestamp < windowEndTime) {
                return true;
            } else if (timestamp < window.startTime) {
                if (mid == 0) break;
                right = mid - 1;
            } else {
                left = mid + 1;
            }
        }
        
        return false;
    }

}
