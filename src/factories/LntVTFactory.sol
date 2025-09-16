// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {ILntVTFactory} from "src/interfaces/ILntVTFactory.sol";

import {ProtocolOwner} from "src/ProtocolOwner.sol";
import {VestingToken} from "src/tokens/VestingToken.sol";

contract LntVTFactory is ILntVTFactory, ProtocolOwner, ReentrancyGuard {

    constructor(address _protocol) ProtocolOwner(_protocol) {

    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function createVestingToken(
        address vault,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) external nonReentrant returns (address token) {
        require(vault != address(0), "Zero address detected");

        token = address(new VestingToken(
            vault, name, symbol, decimals
        ));
        
        emit VestingTokenCreated(token, vault, name, symbol, decimals);
    }

}