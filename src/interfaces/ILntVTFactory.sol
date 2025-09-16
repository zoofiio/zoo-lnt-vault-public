// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

interface ILntVTFactory {

    event VestingTokenCreated(
        address indexed token, address vault, string name, string symbol, uint8 decimals
    );

    function createVestingToken(
        address vault,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) external returns (address token);
    
}