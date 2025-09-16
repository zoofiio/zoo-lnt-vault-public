// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IProtocol} from "src/interfaces/IProtocol.sol";
import {IProtocolSettings} from "src/interfaces/IProtocolSettings.sol";

import {ProtocolOwner} from "src/ProtocolOwner.sol";
import {Constants} from "src/libraries/Constants.sol";

contract ProtocolSettings is IProtocolSettings, ProtocolOwner, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    address public treasury;

    EnumerableSet.Bytes32Set internal _paramsSet;
    mapping(bytes32 => ParamConfig) internal _paramConfigs;

    mapping(address => mapping(bytes32 => bool)) internal _vaultParamsSet;
    mapping(address => mapping(bytes32 => uint256)) internal _vaultParams;

    constructor(address _protocol, address _treasury) ProtocolOwner(_protocol) {
        require(_treasury != address(0), "Zero address detected");
        treasury = _treasury;

        // VT commission rate. Default to 5%, [0%, 20%]
        _upsertParamConfig("VTC", 0.05e18, 0, 0.2e18);

        // Buyback $T -> $VT discount threshold. Default to 90%, [0%, 100%]
        _upsertParamConfig("BuybackDiscountThreshold", 0.9e18, 0, 1e18);

        // Buyback profit commission rate. Default to 50%, [0%, 100%]
        _upsertParamConfig("BuybackProfitCommissionRate", 0.5e18, 0, 1e18);

        // Default to 1.2, [1, 5]
        _upsertParamConfig("initialAnchor", 1.2e18, 1e18, 5e18);

        // Default to 1, [0.01, 10000]
        _upsertParamConfig("scalarRoot", 1e18, 0.01e18, 10000e18);

        // Default to 0.3%, [0, 0.1]
        _upsertParamConfig("vtSwapFee", 0.003e18, 0, 0.1e18);

        // Default to 3, [0.1, 100]
        _upsertParamConfig("R", 3e18, 0.1e18, 100e18);
    }

    /* ============== VIEWS =============== */

    function decimals() public pure returns (uint256) {
        return Constants.PROTOCOL_DECIMALS;
    }

    function params() public view returns (bytes32[] memory) {
        return _paramsSet.values();
    }

    function isValidParam(bytes32 param, uint256 value) public view returns (bool) {
        if (!_paramsSet.contains(param)) {
            return false;
        }

        ParamConfig memory config = _paramConfigs[param];
        return config.min <= value && value <= config.max;
    }

    function paramConfig(bytes32 param) public view returns(ParamConfig memory) {
        require(param.length > 0, "Empty param name");
        require(_paramsSet.contains(param), "Invalid param name");
        return _paramConfigs[param];
    }

    function paramDefaultValue(bytes32 param) public view returns (uint256) {
        require(param.length > 0, "Empty param name");
        require(_paramsSet.contains(param), "Invalid param name");
        return paramConfig(param).defaultValue;
    }

    function vaultParamValue(address vault, bytes32 param) public view returns (uint256) {
        require(vault != address(0), "Zero address detected");
        require(param.length > 0, "Empty param name");

        if (_vaultParamsSet[vault][param]) {
            return _vaultParams[vault][param];
        }
        return paramDefaultValue(param);
    }

    /* ============ MUTATIVE FUNCTIONS =========== */

    function updateTreasury(address newTreasury) external nonReentrant onlyOwner {
        require(newTreasury != address(0), "Zero address detected");
        require(newTreasury != treasury, "Same treasury");

        address prevTreasury = treasury;
        treasury = newTreasury;
        emit UpdateTreasury(prevTreasury, treasury);
    }

    function upsertParamConfig(bytes32 param, uint256 defaultValue, uint256 min, uint256 max) external nonReentrant onlyOwner {
        _upsertParamConfig(param, defaultValue, min, max);
    }

    function _upsertParamConfig(bytes32 param, uint256 defaultValue, uint256 min, uint256 max) internal {
        require(param.length > 0, "Empty param name");
        require(min <= defaultValue && defaultValue <= max, "Invalid default value");

        if (_paramsSet.contains(param)) {
            ParamConfig storage config = _paramConfigs[param];
            config.defaultValue = defaultValue;
            config.min = min;
            config.max = max;
        }
        else {
            _paramsSet.add(param);
            _paramConfigs[param] = ParamConfig(defaultValue, min, max);
        }
        emit UpsertParamConfig(param, defaultValue, min, max);
    }

    function updateVaultParamValue(address vault, bytes32 param, uint256 value) external nonReentrant onlyOwner {
        require(vault != address(0), "Zero address detected");
        require(isValidParam(param, value), "Invalid param or value");

        _vaultParamsSet[vault][param] = true;
        _vaultParams[vault][param] = value;
        emit UpdateVaultParamValue(vault, param, value);
    }

}