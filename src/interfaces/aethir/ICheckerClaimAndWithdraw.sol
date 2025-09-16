// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface ICheckerClaimAndWithdraw {
  
    function claim(
        uint256 orderId,
        uint48 cliffSeconds,
        uint48 expiryTimestamp,
        uint256 amount,
        bytes[] memory signatureArray
    ) external;

    function withdraw(
        uint256[] memory orderIdArray,
        uint48 expiryTimestamp,
        bytes[] memory signatureArray
    ) external;
    
}