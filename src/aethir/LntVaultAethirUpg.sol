// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {UUPSUpgradeable} from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import {ERC721HolderUpgradeable} from "@openzeppelin-upgradeable/contracts/token/ERC721/utils/ERC721HolderUpgradeable.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

import {IProtocol} from "src/interfaces/IProtocol.sol";
import {IProtocolSettings} from "src/interfaces/IProtocolSettings.sol";
import {IVestingToken} from "src/interfaces/IVestingToken.sol";
import {ILntMarket} from "src/interfaces/ILntMarket.sol";
import {ILntVTFactory} from "src/interfaces/ILntVTFactory.sol";
import {IAethiraVTOracle} from "src/interfaces/aethir/IAethiraVTOracle.sol";
import {IAethirRedeemStrategy} from "src/interfaces/aethir/IAethirRedeemStrategy.sol";
import {ILntVaultAethir} from "src/interfaces/aethir/ILntVaultAethir.sol";
import {IAethirLicenseNFT} from "src/interfaces/aethir/IAethirLicenseNFT.sol";
import {IVTSwapHook} from "src/interfaces/IVTSwapHook.sol";

import {TokenPot} from "src/utils/TokenPot.sol";

import {Constants} from "src/libraries/Constants.sol";
import {TokenHelper} from "src/libraries/TokenHelper.sol";

contract LntVaultAethirUpg is ILntVaultAethir, UUPSUpgradeable, ReentrancyGuardUpgradeable, TokenHelper, ERC721HolderUpgradeable {
    using Math for uint256;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    address public protocol;  
    address public tokenPot;

    bool public expired;
    bool public pausedDeposit;
    bool public pausedRedeem;

    address public NFT;
    address public T;
    address public VT;
    address public aVTOracle;
    address public redeemStrategy;
    address public checkerNode;

    address public vtSwapHook;

    uint256 public vtPriceStartTime;
    uint256 public vtPriceEndTime;

    bool public autoBuyback;

    /**
     * @dev A sequence of token ids that have been called setUser on (including setUser with a zero address)
     * Note 
     * - a token id can be in this queue multiple times
     * - a token id remaining in the queue does not mean that the token is still owned by the vault
     */
    DoubleEndedQueue.Bytes32Deque internal _setUserRecordQueue;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _protocol, address _NFT, address _vATOracle, address _redeemStrategy,
        address _T, string memory _vtName, string memory _vtSymbol
    ) initializer public {
        require(
            _protocol != address(0) && _NFT != address(0) && _vATOracle != address(0) && _redeemStrategy != address(0),
            "Zero address detected"
        );
        require(IAethiraVTOracle(_vATOracle).protocol() == _protocol, "Invalid aVTOracle protocol");
        require(IAethirRedeemStrategy(_redeemStrategy).protocol() == _protocol, "Invalid redeem strategy protocol");

        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __ERC721Holder_init();

        protocol = _protocol;
        tokenPot = address(new TokenPot());

        NFT = _NFT;
        aVTOracle = _vATOracle;
        redeemStrategy = _redeemStrategy;
        T = _T;
        VT = ILntVTFactory(IProtocol(_protocol).vtFactory()).createVestingToken(
            address(this), _vtName, _vtSymbol, _decimals(_T)
        );

        vtPriceStartTime = block.timestamp;
        vtPriceEndTime = vtPriceStartTime + 30 days;
    }

    /* ================= VIEWS ================ */

    function owner() public view returns(address) {
        return IProtocol(protocol).owner();
    }

    function setUserRecordCount() external view returns (uint256) {
        return _setUserRecordQueue.length();
    }

    function setUserRecordsInfo(
        uint256 index, uint256 count
    ) external view returns (uint256[] memory tokenIds, address[] memory owners, address[] memory users, bool[] memory isBanned) {
        require(index >= 0 && index < _setUserRecordQueue.length(), "Invalid index");
        require(count > 0 && index + count <= _setUserRecordQueue.length(), "Invalid count");

        tokenIds = new uint256[](count);
        owners = new address[](count);
        users = new address[](count);
        isBanned = new bool[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = uint256(_setUserRecordQueue.at(index + i));
            owners[i] = IERC721(NFT).ownerOf(tokenIds[i]);
            users[i] = IAethirLicenseNFT(NFT).userOf(tokenIds[i]);
            isBanned[i] = IAethirLicenseNFT(NFT).isBanned(tokenIds[i]);
        }
    }

    function lastSetUserRecordInfo() external view returns (uint256 tokenId, address tokenOwner, address user, bool isBanned) {
        require(_setUserRecordQueue.length() > 0, "No set user records");
        tokenId = uint256(_setUserRecordQueue.back());
        tokenOwner = IERC721(NFT).ownerOf(tokenId);
        user = IAethirLicenseNFT(NFT).userOf(tokenId);
        isBanned = IAethirLicenseNFT(NFT).isBanned(tokenId);
    }

    function paramValue(bytes32 param) public view returns (uint256) {
        address settings = IProtocol(protocol).settings();
        return IProtocolSettings(settings).vaultParamValue(address(this), param);
    }

    function paramDecimals() public view returns (uint256) {
        address settings = IProtocol(protocol).settings();
        return IProtocolSettings(settings).decimals();
    }

    /**
    * @dev See {IERC165-supportsInterface}.
    */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(ILntVaultAethir).interfaceId;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function deposit(uint256 tokenId) external nonReentrant whenNotPausedDeposit {
        _deposit(tokenId);

        _onUserAction();
    }

    function batchDeposit(uint256[] calldata tokenIds) external nonReentrant whenNotPausedDeposit {
        require(tokenIds.length > 0, "Invalid input");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _deposit(tokenIds[i]);
        }

        _onUserAction();
    }

    function redeem() external nonReentrant whenNotPausedRedeem returns (uint256 tokenId) {
        tokenId = _redeem();

        _onUserAction();
    }

    function batchRedeem(uint256 count) external nonReentrant whenNotPausedRedeem returns (uint256[] memory tokenIds) {
        require(count > 0 && count <= IAethirLicenseNFT(NFT).balanceOf(address(this)), "Invalid redeem count");

        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            tokenIds[i] = _redeem();
        }

        _onUserAction();
    }

    function redeemT(uint256 amount) external nonReentrant noneZeroAmount(amount) {
        require(expired == true, "Vault is not expired");
        require(_balance(msg.sender, VT) >= amount, "Insufficient VT balance");
        require(TokenPot(payable(tokenPot)).balance(T) >= amount, "Insufficient token balance");

        IVestingToken(VT).burn(msg.sender, amount);
        TokenPot(payable(tokenPot)).withdraw(msg.sender, T, amount);

        emit RedeemT(msg.sender, amount);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _onUserAction() internal {
        if (!autoBuyback) {
            return;
        }

        // T should be auto transfered to this vault by Aethir after claiming and withdrawing rewards
        // Use all T token to swap, including T token remaining in the vault
        uint256 amountT = _selfBalance(T);
        if (amountT > 0) {
            _buybackVT(amountT, false);
        }
    }

    function _buybackVT(uint256 amountT, bool adminBuyback) internal {
        require(amountT > 0 && amountT <= _selfBalance(T), "Invalid amount of T");

        if (expired) {
            _transferOut(T, tokenPot, amountT);
            return;
        }
        
        // Get LntMarket contract from factory
        ILntMarket lntMarket = ILntMarket(IProtocol(protocol).lntMarket());
        bool poolInitialized = (vtSwapHook != address(0)) && lntMarket.poolInitialized(VT, T, vtSwapHook);
        if (!poolInitialized) {
            emit BuybackPoolUninitialized(VT, T, vtSwapHook);
            return;
        }

        uint256 a = _selfBalance(T);
        uint256 b;
        uint256 minAmountOutVT;
        if (adminBuyback) {
            b = amountT;  // specified by admin
            uint256 threshold = paramValue("BuybackDiscountThreshold");
            minAmountOutVT = b.mulDiv(Constants.ONE, threshold); // still enforce to meet the threshold
        }
        else {
            // auto buyback, estimate b, and check threshold
            uint256 targetVTAmount = amountT;
            try IVTSwapHook(vtSwapHook).getAmountOutVTforT(targetVTAmount) returns (uint256 amountTDesired) {
                b = amountTDesired;
            } catch {
                // If getAmountOutVTforT fails, treat as unfavorable conditions and skip buyback
                emit BuybackQuoteFailed(VT, T, vtSwapHook, targetVTAmount);
                return;
            }
            console.log("LntVaultAethirUpg._buybackVT, b:", b);

             // Calculate discount
            uint256 discount = b.mulDiv(Constants.ONE, targetVTAmount); // Normalize to 18 decimals
            console.log("LntVaultAethirUpg._buybackVT, discount:", discount);
            
            // Get BuybackDiscountThreshold from vault settings
            uint256 threshold = paramValue("BuybackDiscountThreshold");
            
            // Check if discount is favorable enough to execute swap
            if (discount > threshold) {
                emit BuybackThresholdNotMet(VT, T, threshold, b, targetVTAmount);
                return;
            }

            minAmountOutVT = b.mulDiv(Constants.ONE, threshold); // Normalize to 18 decimals
        }
        console.log("LntVaultAethirUpg._buybackVT, minAmountOutVT:", minAmountOutVT);

        if (T != Constants.NATIVE_TOKEN) {
            _safeApprove(T, address(lntMarket), b);
        }
        uint256 msgVaulue = T == Constants.NATIVE_TOKEN ? b : 0;

        uint256 previousVT = _selfBalance(VT);
        try lntMarket.swapExactTforVT{value: msgVaulue}(
            VT,
            T,
            vtSwapHook,
            b,
            minAmountOutVT
        ) returns (uint256) {
            uint256 c = _selfBalance(VT) - previousVT;
            uint256 d = 0;

            uint256 profit;
            if (c <= a) {
                profit = c - b;
            }
            else {
                uint256 vtToSwapBack = c - a;
                _safeApprove(VT, address(lntMarket), vtToSwapBack);
                uint256 prevBalanceT = _selfBalance(T);
                // If first swap succeed, second swap fail, the whole tx will revert
                lntMarket.swapExactVTforT(
                    VT,
                    T,
                    vtSwapHook,
                    vtToSwapBack,
                    0 // No minimum output for swap back
                );
                d = _selfBalance(T) - prevBalanceT;
                profit = a - b + d;
            }

            uint256 vtToBurn = _selfBalance(VT) - previousVT;
            if (vtToBurn > 0) {
                IVestingToken(VT).burn(address(this), vtToBurn);
            }

            if (profit > 0) {
                uint256 commissionRate = paramValue("BuybackProfitCommissionRate");
                address treasury = IProtocolSettings(IProtocol(protocol).settings()).treasury();
                
                // Calculate commission amount
                uint256 commission = profit.mulDiv(commissionRate, 10 ** paramDecimals());
                uint256 remainingProfit = profit - commission;
                
                // Transfer commission to treasury using TokenHelper
                if (commission > 0) {
                    _transferOut(T, treasury, commission);
                }
                
                // Transfer remaining profit to tokenPot using TokenHelper
                if (remainingProfit > 0) {
                    _transferOut(T, tokenPot, remainingProfit);
                }

                console.log("Buyback a:", a);
                console.log("Buyback b:", b);
                console.log("Buyback c (VT received):", c);
                console.log("Buyback d (T received from swap back):", d);
                console.log("Buyback profit $T:", profit);
                console.log("Buyback commission $T:", commission);
                console.log("Buyback remaining profit $T:", remainingProfit);
                emit Buyback(
                    VT, T, vtSwapHook,
                    a, b, c, d,
                    profit, commission, remainingProfit
                );
            }
        }
        catch {
            // For auto buyback, if swap fails, continue execution without failing the entire transaction 
            console.log("Buyback failed");
            emit BuybackSwapFailed(VT, T, vtSwapHook, b, minAmountOutVT);

            if (adminBuyback) {
                revert("Buyback swap failed");
            }
        }
    }

    function _deposit(uint256 tokenId) internal {
        require(IAethirLicenseNFT(NFT).isBanned(tokenId) == false, "NFT is banned");
        require(IERC721(NFT).ownerOf(tokenId) == msg.sender, "Not owner of NFT");
        IERC721(NFT).safeTransferFrom(msg.sender, address(this), tokenId);
        require(IERC721(NFT).ownerOf(tokenId) == address(this), "NFT transfer failed");

        uint256 vtAmount = IAethiraVTOracle(aVTOracle).aVT();
        uint256 vtNetAmount = vtAmount - vtAmount.mulDiv(paramValue("VTC"), 10 ** paramDecimals());
        if (vtNetAmount > 0) {
            IVestingToken(VT).mint(msg.sender, vtNetAmount);
        }
        emit VTMinted(msg.sender, vtNetAmount);

        if (checkerNode != address(0)) {
            _setUser(tokenId, checkerNode, type(uint64).max);
        }

        emit Deposit(tokenId, msg.sender);
    }

    /**
     * @dev Iterate to find a token id to redeem. This might fail due to no valid token id found, or out of gas.
     * In this case, admin should be notified and call removeLastSetUserRecords to remove last ineffective setUser records
     */
    function _redeem() internal returns (uint256 tokenId) {
        require(IAethirRedeemStrategy(redeemStrategy).canRedeem(), "Cannot redeem at this time");

        bool found = false;
        while(_setUserRecordQueue.length() > 0) {
            tokenId = uint256(_setUserRecordQueue.popBack());
            bool isOwned = IERC721(NFT).ownerOf(tokenId) == address(this);
            bool isBanned = IAethirLicenseNFT(NFT).isBanned(tokenId);
            emit RemoveSetUserRecord(tokenId, isOwned, isBanned, false);

            found = isOwned && !isBanned;
            if (found) {
                break;
            }
        }
        require(found, "No redeemable NFT found");

        uint256 vtBurnAmount = IAethiraVTOracle(aVTOracle).aVT();
        if (vtBurnAmount > 0) {
            require(_balance(msg.sender, VT) >= vtBurnAmount, "Insufficient VT balance");
            IVestingToken(VT).burn(msg.sender, vtBurnAmount);
            emit VTBurned(msg.sender, vtBurnAmount);
        }

        IERC721(NFT).transferFrom(address(this), msg.sender, tokenId);
        emit Redeem(tokenId, msg.sender);
    }

    function _setUser(uint256 tokenId, address user, uint64 expires) internal {
        require(IERC721(NFT).ownerOf(tokenId) == address(this), "Vault does not own NFT");
        require(IAethirLicenseNFT(NFT).isBanned(tokenId) == false, "NFT is banned");

        IAethirLicenseNFT(NFT).setUser(tokenId, user, expires);
        emit SetUser(tokenId, user, expires);

        _setUserRecordQueue.pushBack(bytes32(tokenId));
    }

    function _ensurePoolInitialized() internal {
        if (vtSwapHook != address(0)) {
            ILntMarket lntMarket = ILntMarket(IProtocol(protocol).lntMarket());
            lntMarket.ensurePoolInitialized(VT, T, vtSwapHook);
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function expire() external nonReentrant onlyOwner {
        require(!expired, "Already expired");
        require(IAethiraVTOracle(aVTOracle).aVT() == 0, "aVT is not zero");
        expired = true;

        emit Expired(msg.sender);
    }

    function unexpire() external nonReentrant onlyOwner {
        require(expired, "Not expired");
        expired = false;

        emit Unexpired(msg.sender);
    }

    function pauseDeposit() external nonReentrant onlyOwner {
        require(!pausedDeposit, "Already paused deposit");
        pausedDeposit = true;

        emit PauseDeposit(msg.sender);
    }

    function unpauseDeposit() external nonReentrant onlyOwner {
        require(pausedDeposit, "Not paused deposit");
        pausedDeposit = false;

        emit UnpauseDeposit(msg.sender);
    }

    function pauseRedeem() external nonReentrant onlyOwner {
        require(!pausedRedeem, "Already paused redeem");
        pausedRedeem = true;

        emit PauseRedeem(msg.sender);
    }

    function unpauseRedeem() external nonReentrant onlyOwner {
        require(pausedRedeem, "Not paused redeem");
        pausedRedeem = false;

        emit UnpauseRedeem(msg.sender);
    }

    function updateAutoBuyback(bool newAutoBuyback) external nonReentrant onlyOwner {
        require(newAutoBuyback != autoBuyback, "New value must differ from current");
        bool previous = autoBuyback;
        autoBuyback = newAutoBuyback;

        emit UpdateAutoBuyback(previous, newAutoBuyback);
    }

    function updateCheckerNode(address newCheckerNode) external nonReentrant onlyOwnerOrOperator {
        require(newCheckerNode != address(0), "Zero address detected");
        require(newCheckerNode != checkerNode, "Checker node already set");
        address previousCheckerNode = checkerNode;
        checkerNode = newCheckerNode;

        emit UpdateCheckerNode(previousCheckerNode, checkerNode);
    }

    function setUser(uint256 tokenId, address user, uint64 expires) external nonReentrant onlyOwnerOrOperator {
        _setUser(tokenId, user, expires);
    }

    function batchSetUser(uint256[] calldata tokenIds, address[] calldata users, uint64 expires) external nonReentrant onlyOwnerOrOperator {
        require(tokenIds.length == users.length, "Array length mismatch");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _setUser(tokenIds[i], users[i], expires);
        }
    }

    function removeLastSetUserRecords(uint256 count, bool force) external nonReentrant onlyOwnerOrOperator {
        require(count > 0 && count <= _setUserRecordQueue.length(), "Invalid count");

        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = uint256(_setUserRecordQueue.back());
            bool isOwned = IERC721(NFT).ownerOf(tokenId) == address(this);
            bool isBanned = IAethirLicenseNFT(NFT).isBanned(tokenId);
            bool canRemove = force || (!isOwned) || isBanned;
            require(canRemove, "Cannot remove setUser record for owned and unbanned NFT");

            _setUserRecordQueue.popBack();
            emit RemoveSetUserRecord(tokenId, isOwned, isBanned, force);
        }
    }

    function buybackVT(uint256 amountT) external nonReentrant onlyOwner {
        require(amountT > 0, "Amount must be greater than 0");
        require(_selfBalance(T) >= amountT, "Insufficient T balance");

        _buybackVT(amountT, true);
    }

    function withdrawProfitT(address recipient) external nonReentrant onlyOwner {
        require(expired, "Vault is not expired");
        require(recipient != address(0), "Zero address detected");

        uint256 totalSupplyOfVT = IVestingToken(VT).totalSupply();
        uint256 balanceOfT = TokenPot(payable(tokenPot)).balance(T);
        if (balanceOfT > totalSupplyOfVT) {
            uint256 profit = balanceOfT - totalSupplyOfVT;
            TokenPot(payable(tokenPot)).withdraw(recipient, T, profit);
            emit WithdrawProfitT(recipient, profit);
        }
    }

    function updateVTPriceTime(uint256 newStartTime, uint256 newEndTime) external nonReentrant onlyOwner {
        require(newStartTime > 0 && newEndTime > newStartTime, "Invalid time range");

        uint256 previousStartTime = vtPriceStartTime;
        uint256 previousEndTime = vtPriceEndTime;
        vtPriceStartTime = newStartTime;
        vtPriceEndTime = newEndTime;

        emit UpdateVTPriceTime(previousStartTime, newStartTime, previousEndTime, newEndTime);
    }

    function updateVTAOracle(address newOracle) external nonReentrant onlyOwner {
        require(newOracle != address(0), "Zero address detected");
        require(newOracle != aVTOracle, "New oracle must differ from current");
        address previousOracle = aVTOracle;
        aVTOracle = newOracle;

        emit UpdateAVTOracle(previousOracle, newOracle);
    }

    function updateRedeemStrategy(address newStrategy) external nonReentrant onlyOwner {
        require(newStrategy != address(0), "Zero address detected");
        require(newStrategy != redeemStrategy, "New strategy must differ from current");
        address previousStrategy = redeemStrategy;
        redeemStrategy = newStrategy;

        emit UpdateRedeemStrategy(previousStrategy, newStrategy);
    }

    function updateVTSwapHook(address newHook) external nonReentrant onlyOwner {
        require(newHook != address(0), "Zero address detected");
        require(newHook != vtSwapHook, "New hook must differ from current");
        address previousHook = vtSwapHook;
        vtSwapHook = newHook;

        emit UpdateVTSwapHook(previousHook, newHook);

        _ensurePoolInitialized();
    }

    /* ============== MODIFIERS =============== */

    modifier onlyOwner() {
        require(msg.sender == owner(), "Caller is not the owner");
        _;
    }

    modifier whenNotPausedDeposit() {
        require(!pausedDeposit, "Deposit is paused");
        _;
    }

    modifier whenNotPausedRedeem() {
        require(!pausedRedeem, "Redeem is paused");
        _;
    }

    modifier noneZeroAmount(uint256 amount) {
        require(amount > 0, "Amount must be greater than 0");
        _;
    }

    modifier onlyOwnerOrOperator() {
        require(
            msg.sender == owner() || IProtocol(protocol).isOperator(msg.sender),
            "Caller is not the owner or an operator"
        );
        _;
    }

    modifier onlyOwnerOrUpgrader() {
        require(
            msg.sender == owner() || IProtocol(protocol).isUpgrader(msg.sender),
            "Caller is not the owner or an upgrader"
        );
        _;
    }

    /* ============= PROXY RELATED ============== */

    function _authorizeUpgrade(address newImplementation) internal override onlyOwnerOrUpgrader {
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
     */
    uint256[49] private __gap;
}
