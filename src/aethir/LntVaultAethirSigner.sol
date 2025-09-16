// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolOwner} from "src/ProtocolOwner.sol";

contract LntVaultAethirSigner is ProtocolOwner, ReentrancyGuard {

    address public signer;

    event UpdateSigner(address indexed previousSigner, address indexed newSigner);

    constructor(address protocol) ProtocolOwner(protocol) {

    }

    function updateSigner(address newSigner) external nonReentrant onlyOwner {
        require(newSigner != address(0), "Signer cannot be zero address");
        address previous = signer;
        signer = newSigner;
        emit UpdateSigner(previous, newSigner);
    }
    
}
