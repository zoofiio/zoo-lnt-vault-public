// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

import {IProtocol} from "src/interfaces/IProtocol.sol";
import {IProtocolOwner} from "src/interfaces/IProtocolOwner.sol";
import {ILntVaultAethir} from "src/interfaces/aethir/ILntVaultAethir.sol";
import {IVTSwapHook} from "src/interfaces/IVTSwapHook.sol";
import {IVTSwapHookHelper} from "src/interfaces/IVTSwapHookHelper.sol";

import {Constants} from "src/libraries/Constants.sol";
import {LogExpMath} from "src/libraries/math/LogExpMath.sol";

contract VTSwapHookHelper is IVTSwapHookHelper {
    using Math for uint256;
    using SafeCast for uint256;

    function doGetAmountIn(
        IVTSwapHook self, 
        uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min
    ) external view returns (uint256 amount0, uint256 amount1, uint256 shares) {
        require(amount0Desired > 0 && amount1Desired > 0, "VTSwapHookHelper: Amounts must be greater than 0");

        uint256 amountTDesired;
        uint256 amountVTDesired;
        uint256 amountTMin;
        uint256 amountVTMin;
        
        if (self.isToken0VT()) {
            amountTDesired = amount1Desired;
            amountVTDesired = amount0Desired;
            amountTMin = amount1Min;
            amountVTMin = amount0Min;
        } else {
            amountTDesired = amount0Desired;
            amountVTDesired = amount1Desired;
            amountTMin = amount0Min;
            amountVTMin = amount1Min;
        }
        
        // Calculate proportional amounts first
        uint256 amountT = amountTDesired;
        uint256 amountVT = amountVTDesired;

        (uint256 reserveVT, uint256 reserveT) = self.getVTAndTReserves();
        if (reserveT > 0) {
            // Calculate proportional VT amount - use mulDiv to prevent overflow
            uint256 calculatedVT = reserveVT.mulDiv(amountTDesired, reserveT);
            if (calculatedVT < amountVTDesired) {
                amountVT = calculatedVT;
            } else {
                // If calculated VT is more than desired, recalculate T amount
                amountT = amountVTDesired.mulDiv(reserveT, reserveVT);
            }
        }
        else {
            // initial supply
            uint256 R = self.getParamValue("R");
            uint256 calculatedVT = amountTDesired.mulDiv(R, Constants.ONE);
            // console.log("VTSwapHookHelper.doGetAmountIn: calculatedVT: %s", calculatedVT);
            if (calculatedVT < amountVTDesired) {
                amountVT = calculatedVT;
            } else {
                // If calculated VT is more than desired, recalculate T amount
                amountT = amountVTDesired.mulDiv(Constants.ONE, R);
            }
            // console.log("VTSwapHookHelper.doGetAmountIn: amountT: %s", amountT);
            // console.log("VTSwapHookHelper.doGetAmountIn: amountVT: %s", amountVT);
        }

        require(amountT >= amountTMin, "VTSwapHookHelper: T amount below minimum");
        require(amountVT >= amountVTMin, "VTSwapHookHelper: VT amount below minimum");

        if (IERC20(address(self)).totalSupply() == 0) {
            shares = amountT;  // initial liquidity
        } else {
            shares = IERC20(address(self)).totalSupply().mulDiv(amountT, reserveT);
        }

        // Set the amounts to transfer
        if (self.isToken0VT()) {
            amount0 = amountVT;
            amount1 = amountT;
        } else {
            amount0 = amountT;
            amount1 = amountVT;
        }
        
        return (amount0, amount1, shares);
    }

    function doGetAmountOutTforVT(IVTSwapHook self, uint256 amountT) external view returns (uint256 amountVT) {
        require(amountT > 0, "VTSwapHookHelper: Input amount must be greater than 0");
        
        // Get pool reserves
        (uint256 reserveVT, uint256 reserveT) = self.getVTAndTReserves();
        require(reserveVT > 0 && reserveT > 0, "VTSwapHookHelper: Insufficient liquidity");
        
        // Get parameters
        uint256 t = _calculateTimeParameter(self);
        uint256 rateScalar = _calculateRateScalar(self, t);
        uint256 rateAnchor = _calculateRateAnchor(self, t);
        uint256 feeRate = _calculateFeeRate(self, t);

        // Calculate VT proportion before swap
        uint256 pVT_before = reserveVT.mulDiv(Constants.ONE, reserveVT + reserveT);
        uint256 price_before = _calculatePrice(self, pVT_before, rateScalar, rateAnchor);
        
        // Apply fee
        uint256 amountAfterFee = amountT.mulDiv(Constants.ONE, feeRate);
        
        // Check if remaining amount is valid
        if (amountAfterFee >= reserveT) {
            revert("VTSwapHookHelper: Insufficient T liquidity");
        }
        
        // Calculate new VT proportion after swap
        uint256 pVT_after;
        if (price_before >= Constants.ONE) {
            // p'~VT~ = (VT~tp~ - d~T~ * Price~t-before~) / (VT~tp~ + T~tp~ - d~T~ * (Price~t-before~ - 1))
            pVT_after = (reserveVT - amountAfterFee.mulDiv(price_before, Constants.ONE)).mulDiv(
                Constants.ONE, 
                reserveVT + reserveT - amountAfterFee.mulDiv(price_before - Constants.ONE, Constants.ONE)
            );
        } else {
            // p'~VT~ = (VT~tp~ - d~T~ * Price~t-before~) / (VT~tp~ + T~tp~ + d~T~ * (1 - Price~t-before~))
            pVT_after = (reserveVT - amountAfterFee.mulDiv(price_before, Constants.ONE)).mulDiv(
                Constants.ONE, 
                reserveVT + reserveT + amountAfterFee.mulDiv(Constants.ONE - price_before, Constants.ONE)
            );
        }
        
        // Calculate price after swap and final price
        uint256 price_after = _calculatePrice(self, pVT_after, rateScalar, rateAnchor);
        uint256 price_final = (price_before + price_after) / 2;
        
        // Ensure price is at least 1
        require(price_final >= Constants.ONE, "VTSwapHookHelper: Price below 1");
        
        // Calculate output amount
        amountVT = amountAfterFee.mulDiv(price_final, Constants.ONE);
        
        // Ensure output is available
        if (amountVT > reserveVT) {
            revert("VTSwapHookHelper: Insufficient VT liquidity");
        }
        
        return amountVT;
    }

    function doGetAmountOutVTforT(IVTSwapHook self, uint256 amountVT) external view returns (uint256 amountT) {
        require(amountVT > 0, "VTSwapHookHelper: Input amount must be greater than 0");
        
        // Get pool reserves
        (uint256 reserveVT, uint256 reserveT) = self.getVTAndTReserves();
        require(reserveVT > 0 && reserveT > 0, "VTSwapHookHelper: Insufficient liquidity");
        
        // Get parameters
        uint256 t = _calculateTimeParameter(self);
        uint256 rateScalar = _calculateRateScalar(self, t);
        uint256 rateAnchor = _calculateRateAnchor(self, t);
        uint256 feeRate = _calculateFeeRate(self, t);

        // Calculate VT proportion before swap
        uint256 pVT_before = reserveVT.mulDiv(Constants.ONE, reserveVT + reserveT);
        uint256 price_before = _calculatePrice(self, pVT_before, rateScalar, rateAnchor);
        
        // Apply fee
        uint256 amountAfterFee = amountVT.mulDiv(Constants.ONE, feeRate);
        
        // Check if remaining amount is valid
        if (amountAfterFee >= reserveVT) {
            revert("VTSwapHookHelper: Insufficient VT liquidity");
        }
        
        // Calculate new VT proportion after swap
        uint256 pVT_after;
        if (price_before >= Constants.ONE) {
            // p'~VT~ = (VT~tp~ + d~VT~) / (VT~tp~ + T~tp~ + d~VT~ * (1 - 1 / Price~t-before~))
            pVT_after = (reserveVT + amountAfterFee).mulDiv(
                Constants.ONE, 
                reserveVT + reserveT + amountAfterFee.mulDiv(Constants.ONE - Constants.ONE.mulDiv(Constants.ONE, price_before), Constants.ONE)
            );
        } else {
            // p'~VT~ = (VT~tp~ + d~VT~) / (VT~tp~ + T~tp~ - d~VT~ * (1 / Price~t-before~ - 1))
            pVT_after = (reserveVT + amountAfterFee).mulDiv(
                Constants.ONE, 
                reserveVT + reserveT - amountAfterFee.mulDiv(Constants.ONE.mulDiv(Constants.ONE, price_before) - Constants.ONE, Constants.ONE)
            );
        }
        
        // Calculate price after swap and final price
        uint256 price_after = _calculatePrice(self, pVT_after, rateScalar, rateAnchor);
        uint256 price_final = (price_before + price_after) / 2;
        
        // Calculate output amount
        amountT = amountAfterFee.mulDiv(Constants.ONE, price_final);
        
        // Ensure output is available
        if (amountT > reserveT) {
            revert("VTSwapHookHelper: Insufficient T liquidity");
        }
        
        return amountT;
    }

    function doGetUnspecifiedAmount(
        IVTSwapHook self, bool zeroForOne, int256 amountSpecified
    ) external view returns (uint256 specifiedAmount, uint256 unspecifiedAmount) {
        // Get pool reserves
        (uint256 reserveVT, uint256 reserveT) = self.getVTAndTReserves();
        require(reserveVT > 0 && reserveT > 0, "VTSwapHookHelper: Insufficient liquidity");

        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: reserveVT: %s", reserveVT);
        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: reserveT: %s", reserveT);
        
        // Calculate time-based parameters
        uint256 t = _calculateTimeParameter(self);
        uint256 rateScalar = _calculateRateScalar(self, t);
        uint256 rateAnchor = _calculateRateAnchor(self, t);
        uint256 feeRate = _calculateFeeRate(self, t);
        
        // Calculate current VT proportion
        uint256 pVT_before = reserveVT.mulDiv(Constants.ONE, reserveVT + reserveT);
        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: pVT_before: %s", pVT_before);
        
        // Calculate price before swap
        uint256 price_before = _calculatePrice(self, pVT_before, rateScalar, rateAnchor);
        
        // Determine swap direction and calculate price
        bool isTToVT = (zeroForOne == !self.isToken0VT()); // True if T -> VT, False if VT -> T
        // console.log("VTSwapHookHelper.doGetUnspecifiedAmount: zeroForOne: %s", zeroForOne);
        // console.log("VTSwapHookHelper.doGetUnspecifiedAmount: isToken0VT: %s", self.isToken0VT());
        // console.log("VTSwapHookHelper.doGetUnspecifiedAmount: isTToVT: %s", isTToVT);

        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: price_before: %s", price_before);
        
        // Get the input amount (absolute value)
        if (amountSpecified < 0) {
            specifiedAmount = uint256(-amountSpecified);
        } else {
            specifiedAmount = uint256(amountSpecified);
        }
        
        // Calculate and deduct fees
        uint256 amountAfterFee = specifiedAmount.mulDiv(Constants.ONE, feeRate);
        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: specifiedAmount: %s", specifiedAmount);
        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: feeRate: %s", feeRate);
        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: amountAfterFee: %s", amountAfterFee);
        
        uint256 pVT_after;
        uint256 price_after;
        uint256 price_final;
        
        if (isTToVT) {
            // T -> VT swap
            // Calculate new VT proportion after hypothetical swap using amount after fee
            if (amountAfterFee >= reserveT) {
                // Edge case, can't swap all T
                revert("VTSwapHookHelper: Insufficient T liquidity");
            }
            if (reserveVT <= amountAfterFee.mulDiv(price_before, Constants.ONE)) {
                // Edge case, can't swap all VT
                revert("VTSwapHookHelper: Insufficient VT liquidity");
            }
            
            if (price_before >= Constants.ONE) {
                // p'~VT~ = (VT~tp~ - d~T~ * Price~t-before~) / (VT~tp~ + T~tp~ - d~T~ * (Price~t-before~ - 1))
                pVT_after = (reserveVT - amountAfterFee.mulDiv(price_before, Constants.ONE)).mulDiv(
                    Constants.ONE, 
                    reserveVT + reserveT - amountAfterFee.mulDiv(price_before - Constants.ONE, Constants.ONE)
                );
            } else {
                // p'~VT~ = (VT~tp~ - d~T~ * Price~t-before~) / (VT~tp~ + T~tp~ + d~T~ * (1 - Price~t-before~))
                pVT_after = (reserveVT - amountAfterFee.mulDiv(price_before, Constants.ONE)).mulDiv(
                    Constants.ONE, 
                    reserveVT + reserveT + amountAfterFee.mulDiv(Constants.ONE - price_before, Constants.ONE)
                );
            }
            console.log("VTSwapHookHelper.doGetUnspecifiedAmount: T => VT, pVT_after: %s", pVT_after);
            
            // Calculate price after swap
            price_after = _calculatePrice(self, pVT_after, rateScalar, rateAnchor);
            console.log("VTSwapHookHelper.doGetUnspecifiedAmount: T => VT, price_after: %s", price_after);

            // Final price is average
            price_final = (price_before + price_after) / 2;
            console.log("VTSwapHookHelper.doGetUnspecifiedAmount: T => VT, price_final: %s", price_final);
            
            // Ensure price is at least 1
            require(price_final >= Constants.ONE, "VTSwapHookHelper: Price below 1");
            
            // Calculate output amount of VT - use amount after fee for calculation
            unspecifiedAmount = amountAfterFee.mulDiv(price_final, Constants.ONE);
            
            // Ensure the pool has enough VT
            require(unspecifiedAmount <= reserveVT, "VTSwapHookHelper: Insufficient VT liquidity");
        } else {
            // VT -> T swap
            // Calculate new VT proportion after hypothetical swap using amount after fee
            if (amountAfterFee >= reserveVT) {
                // Edge case, can't swap all VT
                revert("VTSwapHookHelper: Insufficient VT liquidity");
            }
            
            if (price_before >= Constants.ONE) {
                // p'~VT~ = (VT~tp~ + d~VT~) / (VT~tp~ + T~tp~ + d~VT~ * (1 - 1 / Price~t-before~))
                pVT_after = (reserveVT + amountAfterFee).mulDiv(
                    Constants.ONE, 
                    reserveVT + reserveT + amountAfterFee.mulDiv(Constants.ONE - Constants.ONE.mulDiv(Constants.ONE, price_before), Constants.ONE)
                );
            } else {
                // p'~VT~ = (VT~tp~ + d~VT~) / (VT~tp~ + T~tp~ - d~VT~ * (1 / Price~t-before~ - 1))
                pVT_after = (reserveVT + amountAfterFee).mulDiv(
                    Constants.ONE, 
                    reserveVT + reserveT - amountAfterFee.mulDiv(Constants.ONE.mulDiv(Constants.ONE, price_before) - Constants.ONE, Constants.ONE)
                );
            }
            console.log("VTSwapHookHelper.doGetUnspecifiedAmount: VT => T, pVT_after: %s", pVT_after);
            
            // Calculate price after swap
            price_after = _calculatePrice(self, pVT_after, rateScalar, rateAnchor);
            console.log("VTSwapHookHelper.doGetUnspecifiedAmount: VT => T, price_after: %s", price_after);
            
            // Final price is average
            price_final = (price_before + price_after) / 2;
            console.log("VTSwapHookHelper.doGetUnspecifiedAmount: VT => T, price_final: %s", price_final);
            
            // Calculate output amount of T - use amount after fee for calculation
            unspecifiedAmount = amountAfterFee.mulDiv(Constants.ONE, price_final);
            
            // Ensure the pool has enough T
            require(unspecifiedAmount <= reserveT, "VTSwapHookHelper: Insufficient T liquidity");
        }

        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: specifiedAmount: %s", specifiedAmount);
        console.log("VTSwapHookHelper.doGetUnspecifiedAmount: unspecifiedAmount: %s", unspecifiedAmount);
        
        return (specifiedAmount, unspecifiedAmount);
    }

     /**
     * @dev Calculate price of VT based on the proportion and rate parameters
     * @param pvPT The proportion of VT in the pool (scaled by 1e18)
     * @param rateScalar The calculated rate scalar (scaled by 1e18)
     * @param rateAnchor The calculated rate anchor (scaled by 1e18)
     * @return price The calculated price (scaled by 1e18)
     */
    function _calculatePrice(IVTSwapHook self, uint256 pvPT, uint256 rateScalar, uint256 rateAnchor) internal view returns (uint256 price) {
        require(pvPT > 0 && pvPT < Constants.ONE, "VTSwapHookHelper: Invalid proportion");

        uint256 R = self.getParamValue("R");
        
        // ln(pvPT / ((1 - pvPT) * R) + rateAnchor
        uint256 numerator = pvPT;
        uint256 denominator = (Constants.ONE - pvPT).mulDiv(R, Constants.ONE);
        
        // Use mulDiv for nested operations
        int256 lnTerm = LogExpMath.ln((numerator.mulDiv(Constants.ONE, denominator)).toInt256());
        
        // Calculate price = (1 / rateScalar) * lnTerm + rateAnchor
        if (lnTerm < 0) {
            uint256 term = uint256(-lnTerm).mulDiv(Constants.ONE, rateScalar);
            require(term < rateAnchor, "VTSwapHookHelper: Invalid price");
            price = rateAnchor - term;
        } else {
            price = rateAnchor + uint256(lnTerm).mulDiv(Constants.ONE, rateScalar);
        }
    }

    function _calculateTimeParameter(IVTSwapHook self) internal view returns (uint256 t) {
        address vault = self.vault();
        uint256 startTime = ILntVaultAethir(vault).vtPriceStartTime();
        uint256 endTime = ILntVaultAethir(vault).vtPriceEndTime();

        require(startTime > 0 && endTime > startTime, "Invalid VT price time range");

        // Calculate t parameter
        if (block.timestamp >= endTime) {
            return 0;
        }
        
        if (block.timestamp <= startTime) {
            return Constants.ONE;
        }
        
        // Linear decay from 1 to 0
        t = (endTime - block.timestamp).mulDiv(Constants.ONE, endTime - startTime);
    }
    
    /**
     * @dev Calculate RateScalar(t) parameter
     * @param t The time parameter (scaled by 1e18)
     * @return The rate scalar (scaled by 1e18)
     */
    function _calculateRateScalar(IVTSwapHook self, uint256 t) internal view returns (uint256) {
        if (t == 0) return type(uint256).max; // Avoid division by zero

        uint256 scalarRoot = self.getParamValue("scalarRoot");
        return scalarRoot.mulDiv(Constants.ONE, t);
    }
    
    /**
     * @dev Calculate RateAnchor(t) parameter
     * @param t The time parameter (scaled by 1e18)
     * @return The rate anchor (scaled by 1e18)
     */
    function _calculateRateAnchor(IVTSwapHook self, uint256 t) internal view returns (uint256) {
        uint256 initialAnchor = self.getParamValue("initialAnchor");
        return Constants.ONE + (initialAnchor - Constants.ONE).mulDiv(t, Constants.ONE);
    }

    /**
     * @dev Calculate the fee rate based on time parameter t
     * @param t The time parameter (scaled by 1e18)
     * @return The fee rate (scaled by 1e18)
     */
    function _calculateFeeRate(IVTSwapHook self, uint256 t) internal view returns (uint256) {
        // feeRate = (1 + vtSwapFee)^t
        
        // Handle special cases for efficiency
        if (t == 0) return Constants.ONE;

        uint256 vtSwapFee = self.getParamValue("vtSwapFee");
        if (t == Constants.ONE) return Constants.ONE + vtSwapFee;
        
        // For values between 0 and 1, use the precise pow function
        return LogExpMath.pow(Constants.ONE + vtSwapFee, t);
    }
}