// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTokenWrapperHook} from "./base/BaseTokenWrapperHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFCS, IFPS} from "./interfaces/IFCS.sol";
import {FCSPrimaryRouter} from "./FCSPrimaryRouter.sol";

/// @notice Primary ZCHF/FCS adapter. Does not use FCS.wrap/unwrap or modify FCS governance.
contract FCSPrimaryHook is BaseTokenWrapperHook {
    using SafeERC20 for IERC20;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    IFCS public immutable FCS;
    address public immutable ZCHF;
    FCSPrimaryRouter public immutable router;
    error SettlementMismatch();
    error InvalidOutput();
    error InvalidConfiguration();
    error InvalidTickSpacing();
    error InvalidHookData();
    error InvalidMinimum();
    error Expired();
    error InvalidAmount();
    error InputNotPrefunded();
    error InsufficientOutput(uint256 actual, uint256 minimum);

    /// @notice Actual primary execution amounts, including swaps through external routers.
    /// @dev `router` is the PoolManager-authenticated swap caller, NOT necessarily the economic
    /// payer or recipient. buyFCS=true means ZCHF in/FCS out; false means FCS in/ZCHF out.
    /// Emitted after settlement and minimum-output checks; any later revert rolls the log back.
    event PrimaryExecution(
        PoolId indexed poolId, address indexed router, bool buyFCS, uint256 amountIn, uint256 amountOut
    );

    constructor(IPoolManager manager, IFCS fcs)
        BaseTokenWrapperHook(manager, Currency.wrap(address(fcs)), Currency.wrap(_validatedAsset(manager, fcs)))
    {
        FCS = fcs;
        ZCHF = fcs.asset();
        router = new FCSPrimaryRouter(manager, fcs, address(this));
        IERC20(ZCHF).forceApprove(address(fcs), type(uint256).max);
    }

    function _validatedAsset(IPoolManager manager, IFCS fcs) private view returns (address asset) {
        if (address(manager).code.length == 0 || address(fcs).code.length == 0) revert InvalidConfiguration();
        asset = fcs.asset();
        if (asset == address(fcs) || asset.code.length == 0 || fcs.ZCHF() != asset || fcs.FPS1().code.length == 0) {
            revert InvalidConfiguration();
        }
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 price)
        internal
        view
        override
        returns (bytes4)
    {
        if (key.tickSpacing != 1) revert InvalidTickSpacing();
        return super._beforeInitialize(sender, key, price);
    }

    /// @dev Permissionless integration: the manager authenticates sender; every route must
    /// own prefunded input credit and supply per-hop (minimumOutput, deadline) as exactly 64 bytes.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 fee)
    {
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();
        if (params.amountSpecified < -int256(type(int128).max)) revert InvalidAmount();
        if (hookData.length != 64) revert InvalidHookData();
        (uint256 minimum, uint256 deadline) = abi.decode(hookData, (uint256, uint256));
        if (minimum == 0) revert InvalidMinimum();
        if (block.timestamp > deadline) revert Expired();
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (poolManager.currencyDelta(sender, input) < -params.amountSpecified) revert InputNotPrefunded();
        (selector, delta, fee) = super._beforeSwap(sender, key, params, hookData);
        uint256 output = uint256(-int256(delta.getUnspecifiedDelta()));
        if (output < minimum) revert InsufficientOutput(output, minimum);
        emit PrimaryExecution(
            key.toId(), sender, params.zeroForOne == wrapZeroForOne, uint256(int256(delta.getSpecifiedDelta())), output
        );
    }

    function _supportsExactOutput() internal pure override returns (bool) {
        return false;
    }

    enum QuoteStatus {
        Available,
        InvalidInput,
        NotBinding,
        FPSRedemptionDisabled,
        InsufficientSupply,
        PreviewFailed,
        ZeroOutput,
        OutputTooLarge,
        ReadFailed
    }

    /// @notice Read-only amount-specific quote. `available` means the supported checks pass,
    /// NOT guaranteed execution. User balance/allowance, pool initialization, recapitalization,
    /// FPS total-supply caps and future state changes are not modelled. Disabled quotes may
    /// still show theoretical output; protocol calls remain authoritative.
    /// @dev Never uses maxRedeem(hook): this adapter normally holds no FCS.
    function quoteExactInput(bool buyFCS, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, bool available, QuoteStatus status)
    {
        if (amountIn == 0 || amountIn > uint256(uint128(type(int128).max))) {
            return (0, false, QuoteStatus.InvalidInput);
        }
        if (buyFCS) {
            try FCS.previewDeposit(amountIn) returns (uint256 out) {
                amountOut = out;
            } catch {
                return (0, false, QuoteStatus.PreviewFailed);
            }
        } else {
            try FCS.totalSupply() returns (uint256 supply) {
                if (amountIn > supply) return (0, false, QuoteStatus.InsufficientSupply);
            } catch {
                return (0, false, QuoteStatus.ReadFailed);
            }
            try FCS.previewRedeem(amountIn) returns (uint256 out) {
                amountOut = out;
            } catch {
                return (0, false, QuoteStatus.PreviewFailed);
            }
            try FCS.isBinding() returns (bool binding) {
                if (!binding) return (amountOut, false, QuoteStatus.NotBinding);
            } catch {
                return (amountOut, false, QuoteStatus.ReadFailed);
            }
            try IFPS(FCS.FPS1()).canRedeem(address(FCS)) returns (bool enabled) {
                if (!enabled) return (amountOut, false, QuoteStatus.FPSRedemptionDisabled);
            } catch {
                return (amountOut, false, QuoteStatus.ReadFailed);
            }
        }
        if (amountOut == 0) return (0, false, QuoteStatus.ZeroOutput);
        if (amountOut > uint256(uint128(type(int128).max))) return (amountOut, false, QuoteStatus.OutputTooLarge);
        return (amountOut, true, QuoteStatus.Available);
    }

    function _deposit(uint256 amount) internal override returns (uint256, uint256) {
        uint256 inputBefore = IERC20(ZCHF).balanceOf(address(this));
        uint256 outputBefore = FCS.balanceOf(address(this));
        _take(underlyingCurrency, address(this), amount);
        if (IERC20(ZCHF).balanceOf(address(this)) != inputBefore + amount) revert SettlementMismatch();
        uint256 reported = FCS.deposit(amount, address(this));
        uint256 output = FCS.balanceOf(address(this)) - outputBefore;
        if (reported != output || IERC20(ZCHF).balanceOf(address(this)) != inputBefore) revert SettlementMismatch();
        _settleOutput(wrapperCurrency, output);
        if (FCS.balanceOf(address(this)) != outputBefore) revert SettlementMismatch();
        return (amount, output);
    }

    function _settleOutput(Currency currency, uint256 output) private {
        if (output == 0 || output > uint256(uint128(type(int128).max))) revert InvalidOutput();
        poolManager.sync(currency);
        _pay(currency, address(this), output);
        if (poolManager.settle() != output) revert SettlementMismatch();
    }

    function _withdraw(uint256 amount) internal override returns (uint256, uint256) {
        uint256 inputBefore = FCS.balanceOf(address(this));
        uint256 outputBefore = IERC20(ZCHF).balanceOf(address(this));
        _take(wrapperCurrency, address(this), amount);
        if (FCS.balanceOf(address(this)) != inputBefore + amount) revert SettlementMismatch();
        // Genuine FCS enforces binding and FPS1.canRedeem(FCS); never bypass those gates.
        uint256 reported = FCS.redeem(amount, address(this), address(this));
        uint256 output = IERC20(ZCHF).balanceOf(address(this)) - outputBefore;
        if (reported != output || FCS.balanceOf(address(this)) != inputBefore) revert SettlementMismatch();
        _settleOutput(underlyingCurrency, output);
        if (IERC20(ZCHF).balanceOf(address(this)) != outputBefore) revert SettlementMismatch();
        return (amount, output);
    }
}
