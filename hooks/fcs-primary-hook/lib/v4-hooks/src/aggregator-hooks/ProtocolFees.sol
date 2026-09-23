// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IV4FeeAdapter} from "@protocol-fees/interfaces/IV4FeeAdapter.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

abstract contract ProtocolFees {
    using ProtocolFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address public tokenJar;
    uint24 public immutable protocolFeeMultiplier;

    constructor(uint24 _protocolFeeMultiplier) {
        protocolFeeMultiplier = _protocolFeeMultiplier;
    }

    event ProtocolFeesCollected(address indexed recipient, Currency indexed currency, uint256 amount);

    /// @notice Queries the token jar from the pool manager and emits an event if it is updated
    /// @return The token jar address
    /// @dev This function should not need to be called externally except in the case of the tokenJar address changing
    /// after the protocol fee has been set
    function pollTokenJar() public virtual returns (address);

    function _applyProtocolFee(
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata params,
        int128 unspecifiedDelta
    ) internal returns (int128) {
        uint24 protocolFee = _getProtocolFee(poolManager, params.zeroForOne, key.toId());
        return _applyWithProtocolFee(poolManager, key, params, unspecifiedDelta, protocolFee);
    }

    function _applyWithProtocolFee(
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata params,
        int128 unspecifiedDelta,
        uint24 protocolFee
    ) internal returns (int128) {
        if (protocolFee == 0) return 0;
        // Assumes that if a protocol fee is set, there should be a token jar.
        if (tokenJar == address(0)) pollTokenJar();
        if (tokenJar == address(0)) return 0;

        bool isExactInput = params.amountSpecified < 0;

        // Determine the unspecified currency (the side protocol fee is taken from)
        Currency unspecifiedCurrency = params.zeroForOne == isExactInput ? key.currency1 : key.currency0;

        uint256 absUnspecified = uint256(uint128(unspecifiedDelta < 0 ? -unspecifiedDelta : unspecifiedDelta));
        uint256 protocolFeeAmount = _calculateProtocolFeeAmount(protocolFee, params.amountSpecified < 0, absUnspecified);

        // Send the protocol fee to the token jar
        emit ProtocolFeesCollected(tokenJar, unspecifiedCurrency, protocolFeeAmount);
        poolManager.take(unspecifiedCurrency, tokenJar, protocolFeeAmount);

        return int128(uint128(protocolFeeAmount));
    }

    function _calculateProtocolFeeAmount(uint24 protocolFee, bool isExactInput, uint256 amountUnspecified)
        internal
        pure
        returns (uint256)
    {
        if (isExactInput) {
            return FullMath.mulDivRoundingUp(amountUnspecified, protocolFee, ProtocolFeeLibrary.PIPS_DENOMINATOR);
        } else {
            // This calculation ensures the fee is the correct proportion of the total input.
            // For a protocol fee of X%, the fee amount will be X% of the total input rather than X%
            // of the pre-protocol fee input.
            return FullMath.mulDivRoundingUp(
                amountUnspecified, protocolFee, ProtocolFeeLibrary.PIPS_DENOMINATOR - protocolFee
            );
        }
    }

    /// @dev The protocol fee is multiplied by the protocol fee multiplier
    function _getProtocolFee(IPoolManager poolManager, bool zeroToOne, PoolId poolId)
        internal
        view
        returns (uint24 protocolFee)
    {
        (,, uint24 protocolFeeRaw,) = poolManager.getSlot0(poolId);
        protocolFee = zeroToOne
            ? ProtocolFeeLibrary.getZeroForOneFee(protocolFeeRaw)
            : ProtocolFeeLibrary.getOneForZeroFee(protocolFeeRaw);
        protocolFee *= protocolFeeMultiplier;
    }

    function _getTokenJar(IPoolManager poolManager) internal view returns (address currentJar) {
        address protocolFeeAdapterAddress = poolManager.protocolFeeController();
        if (protocolFeeAdapterAddress == address(0) || protocolFeeAdapterAddress.code.length == 0) return address(0);
        try IV4FeeAdapter(protocolFeeAdapterAddress).TOKEN_JAR() returns (address _currentJar) {
            currentJar = _currentJar;
        } catch {
            // keep currentJar as address(0)
        }
    }
}
