// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IProtocol} from "src/interfaces/IProtocol.sol";

import {Initializable} from "src/utils/Initializable.sol";

contract Protocol is IProtocol, Ownable2Step, ReentrancyGuard, Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public settings;
    address public lntMarket;
    address public vtSwapHookHelper;
    address public vtFactory;

    EnumerableSet.AddressSet internal _operators;
    EnumerableSet.AddressSet internal _upgraders;

    constructor() Ownable(_msgSender()) {

    }

    /* ========== VIEWS ========= */

    function owner() public view override(Ownable, IProtocol) returns (address) {
        return Ownable.owner();
    }

    function isOperator(address account) public view returns (bool) {
        return _operators.contains(account);
    }

    function isUpgrader(address account) public view returns (bool) {
        return _upgraders.contains(account);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function initialize(
        address _settings, address _lntMarket, address _vtSwapHookHelper, address _vtFactory
    ) external nonReentrant onlyOwner initializer {
        require(
            _settings != address(0) && _lntMarket != address(0) && _vtSwapHookHelper != address(0) && _vtFactory != address(0), 
            "Zero address detected"
        );

        settings = _settings;
        lntMarket = _lntMarket;
        vtSwapHookHelper = _vtSwapHookHelper;
        vtFactory = _vtFactory;
    }

    function addOperator(address operator) external nonReentrant onlyOwner {
        require(operator != address(0), "Zero address detected");
        require(!_operators.contains(operator), "Already an operator");

        _operators.add(operator);
        emit AddOperator(operator);
    }

    function removeOperator(address operator) external nonReentrant onlyOwner {
        require(operator != address(0), "Zero address detected");
        require(_operators.contains(operator), "Not an operator");

        _operators.remove(operator);
        emit RemoveOperator(operator);
    }

    function addUpgrader(address upgrader) external nonReentrant onlyOwner {
        require(upgrader != address(0), "Zero address detected");
        require(!_upgraders.contains(upgrader), "Already an upgrader");

        _upgraders.add(upgrader);
        emit AddUpgrader(upgrader);
    }

    function removeUpgrader(address upgrader) external nonReentrant onlyOwner {
        require(upgrader != address(0), "Zero address detected");
        require(_upgraders.contains(upgrader), "Not an upgrader");

        _upgraders.remove(upgrader);
        emit RemoveUpgrader(upgrader);
    }

    function updateSettings(address newSettings) external nonReentrant onlyInitialized onlyOwner {
        require(newSettings != address(0), "Zero address detected");
        require(newSettings != settings, "Same settings");

        address prevSettings = settings;
        settings = newSettings;
        emit UpdateSettings(prevSettings, settings);
    }

    function updateLntMarket(address newLntMarket) external nonReentrant onlyInitialized onlyOwner {
        require(newLntMarket != address(0), "Zero address detected");
        require(newLntMarket != lntMarket, "Same LNT market");

        address prevLntMarket = lntMarket;
        lntMarket = newLntMarket;
        emit UpdateLntMarket(prevLntMarket, lntMarket);
    }

    function updateVTSwapHookHelper(address newVTSwapHookHelper) external nonReentrant onlyInitialized onlyOwner {
        require(newVTSwapHookHelper != address(0), "Zero address detected");
        require(newVTSwapHookHelper != vtSwapHookHelper, "Same VTSwapHookHelper");

        address prevVTSwapHookHelper = vtSwapHookHelper;
        vtSwapHookHelper = newVTSwapHookHelper;
        emit UpdateVTSwapHookHelper(prevVTSwapHookHelper, vtSwapHookHelper);
    }

    function updateVTFactory(address newVTFactory) external nonReentrant onlyInitialized onlyOwner {
        require(newVTFactory != address(0), "Zero address detected");
        require(newVTFactory != vtFactory, "Same VTFactory");

        address prevVTFactory = vtFactory;
        vtFactory = newVTFactory;
        emit UpdateVTFactory(prevVTFactory, vtFactory);
    }
}