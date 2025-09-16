// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {IProtocolOwner} from "src/interfaces/IProtocolOwner.sol";

interface IAethirRedeemStrategy is IProtocolOwner {
    enum RedeemStrategy {
        ONLY_WITHIN_REDEEM_TIME_WINDOW,
        ALLOWED,
        FORBIDDEN
    }

    struct RedeemTimeWindow {
        uint256 id;
        uint256 startTime;
        uint256 duration;
    }

    event UpdateRedeemStrategy(RedeemStrategy previous, RedeemStrategy current);

    event AddRedeemTimeWindow(uint256 startTime, uint256 duration);

    event RemoveRedeemTimeWindow(uint256 startTime, uint256 duration);

    function canRedeem() external view returns (bool);
    
}
