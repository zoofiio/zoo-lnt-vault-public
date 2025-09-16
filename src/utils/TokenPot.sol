// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TokenHelper} from "src/libraries/TokenHelper.sol";

contract TokenPot is Ownable, ReentrancyGuard, TokenHelper {

    constructor() Ownable(_msgSender()) {}

    receive() external payable {}

    function balance(address token) public view returns (uint256) {
        return _selfBalance(token);
    }

    function withdraw(address recipient, address token, uint256 amount) external nonReentrant onlyOwner {
        require(recipient != address(0), "Zero address detected");
        require(amount > 0 && amount <= balance(token), "Invalid amount");

        _transferOut(token, recipient, amount);
        emit Withdrawn(_msgSender(), recipient, token, amount);
    }

    /* =============== EVENTS ============= */

    event Withdrawn(address indexed withdrawer, address indexed recipient, address indexed token, uint256 amount);

}