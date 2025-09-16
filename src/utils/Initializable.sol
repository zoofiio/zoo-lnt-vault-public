// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

abstract contract Initializable {

    bool public initialized;

    /* ============== MODIFIERS =============== */

    modifier initializer() {
        require(!initialized, "Already initialized");
        _;
        initialized = true;
        emit Initialized();
    }

    modifier onlyInitialized() {
        require(initialized, "Not initialized");
        _;
    }

    /* =============== EVENTS ============= */

    event Initialized();
  
}