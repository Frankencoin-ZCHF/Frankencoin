// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMorphoFlashloan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

interface IMintingHubGeneric {
    function clone(address parent, uint256 initialCollateral, uint256 initialMint, uint40 expiration)
        external
        returns (address);
}

interface IPositionGeneric {
    function collateral() external view returns (IERC20);

    function price() external view returns (uint256);

    function expiration() external view returns (uint40);

    function reserveContribution() external view returns (uint24);

    function annualInterestPPM() external view returns (uint24);
}

interface IOwnableGeneric {
    function transferOwnership(address newOwner) external;
}

/**
 * @title  LeverageGeneric
 * @notice Stateless, permissionless executor that opens a leveraged Frankencoin PositionV2
 *         backed by any liquid ERC20 collateral (`source.collateral()`) in one transaction.
 *
 *         The collateral is flash-borrowed from Morpho, so the position can be cloned and minted
 *         first; the minted ZCHF is then swapped back into collateral to repay the flashloan.
 *
 *         Two entry points share one callback:
 *
 *         1. executeWithZCHF(source, equity z, C, ...)
 *              pull z ZCHF → flashloan C collateral → clone with C and mint → swap (z + mintNet) ZCHF
 *              into ≥ C collateral → repay C → sweep leftovers
 *
 *         2. executeWithCollateral(source, equity e, C, ...)
 *              pull e collateral → flashloan C − e → clone with C and mint → swap mintNet ZCHF
 *              into ≥ C − e collateral → repay C − e → sweep leftovers
 *
 *         C is the target collateral deposited into the position. The mint is the maximum for C:
 *           mintGross = C × price() / 1e18      (valid for any collateral decimals)
 *           mintNet   = mintGross × (1e6 − resPPM − feePPM) / 1e6
 *         Use `preview` for these numbers, quote the swap off-chain, and size C so that the swap
 *         output covers the flashloan. Excess collateral and ZCHF are swept to the caller.
 *
 *         Security: swap calldata may only be sent to the immutable ROUTER, so it cannot spend users'
 *         allowances. The router is approved for the exact swap input and reset afterwards. The swap
 *         result is measured by balance delta and must cover the flashloan, which is the slippage
 *         guard. Collateral must be a plain ERC20 (no fee-on-transfer or rebasing).
 */
contract LeverageGeneric is IMorphoFlashLoanCallback {
    using SafeERC20 for IERC20;

    // ── Deployed addresses (mainnet) ──────────────────────────────────────────

    IMorphoFlashloan public constant MORPHO = IMorphoFlashloan(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    IMintingHubGeneric public constant HUB = IMintingHubGeneric(0xDe12B620A8a714476A97EfD14E6F7180Ca653557);
    IERC20 public constant ZCHF = IERC20(0xB58E61C3098d85632Df34EecfB899A1Ed80921cB);

    /// @notice Swap router (e.g. Enso), the only permitted call target for swap calldata.
    address public immutable ROUTER;

    // ── Types ─────────────────────────────────────────────────────────────────

    struct Preview {
        uint256 mintGross; // gross ZCHF minted by the clone
        uint256 reserveAmount; // ZCHF locked in the Frankencoin reserve
        uint256 feeAmount; // upfront minting interest fee
        uint256 mintNet; // ZCHF released to this contract, swap input (plus ZCHF equity)
    }

    struct CallbackData {
        address source;
        address recipient;
        uint256 collateralAmount; // C, deposited into the position
        uint40 expiration;
        bytes swapData;
    }

    // Intra-tx return value: set in callback, consumed and cleared by the entry points.
    address private _clonedPosition;

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotMorpho();
    error InvalidAmount();
    error InvalidExpiration();
    error SwapFailed(bytes reason);
    error InsufficientSwapOutput(uint256 got, uint256 required);

    constructor(address router) {
        require(router != address(0), "router");
        ROUTER = router;
    }

    // ── View ──────────────────────────────────────────────────────────────────

    /**
     * @notice Clone economics for depositing `collateralAmount` into a clone of `source`.
     */
    function preview(address source, uint40 expiration, uint256 collateralAmount)
        external
        view
        returns (Preview memory p)
    {
        IPositionGeneric src = IPositionGeneric(source);
        if (expiration <= block.timestamp || expiration > src.expiration()) revert InvalidExpiration();

        uint256 resPPM = src.reserveContribution();
        uint256 feePPM = ((uint256(expiration) - block.timestamp) * uint256(src.annualInterestPPM())) / 365 days;

        p.mintGross = (collateralAmount * src.price()) / 1e18;
        p.reserveAmount = (p.mintGross * resPPM) / 1_000_000;
        p.mintNet = (p.mintGross * (1_000_000 - resPPM - feePPM)) / 1_000_000;
        p.feeAmount = p.mintGross - p.mintNet - p.reserveAmount;
    }

    // ── Entry points ──────────────────────────────────────────────────────────

    /**
     * @notice Flow 1: equity in ZCHF.
     * @param source            PositionV2 to clone; the collateral is `source.collateral()`.
     * @param equityAmount      ZCHF equity z, pulled from msg.sender (pre-approved).
     * @param collateralAmount  Collateral C to deposit, entirely flash-borrowed.
     * @param expiration        Clone expiration (≤ source.expiration()).
     * @param swapData          Router calldata swapping exactly z + mintNet ZCHF into the collateral,
     *                          with this contract as recipient.
     */
    function executeWithZCHF(
        address source,
        uint256 equityAmount,
        uint256 collateralAmount,
        uint40 expiration,
        bytes calldata swapData
    ) external returns (address leveragedPosition) {
        ZCHF.safeTransferFrom(msg.sender, address(this), equityAmount);
        return _run(source, collateralAmount, collateralAmount, expiration, swapData);
    }

    /**
     * @notice Flow 2: equity in collateral.
     * @param source            PositionV2 to clone; the collateral is `source.collateral()`.
     * @param equityAmount      Collateral equity e, pulled from msg.sender (pre-approved).
     * @param collateralAmount  Collateral C to deposit; C − e is flash-borrowed.
     * @param expiration        Clone expiration (≤ source.expiration()).
     * @param swapData          Router calldata swapping exactly mintNet ZCHF into the collateral,
     *                          with this contract as recipient.
     */
    function executeWithCollateral(
        address source,
        uint256 equityAmount,
        uint256 collateralAmount,
        uint40 expiration,
        bytes calldata swapData
    ) external returns (address leveragedPosition) {
        if (equityAmount >= collateralAmount) revert InvalidAmount();
        IPositionGeneric(source).collateral().safeTransferFrom(msg.sender, address(this), equityAmount);
        return _run(source, collateralAmount - equityAmount, collateralAmount, expiration, swapData);
    }

    // ── Morpho callback ───────────────────────────────────────────────────────

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(MORPHO)) revert NotMorpho();

        CallbackData memory d = abi.decode(data, (CallbackData));
        IERC20 collateral = IPositionGeneric(d.source).collateral();

        // 1. Clone with C collateral and mint the maximum. The 4-arg overload sends the minted
        //    ZCHF to this contract, not to the recipient.
        uint256 mintGross = (d.collateralAmount * IPositionGeneric(d.source).price()) / 1e18;
        collateral.forceApprove(address(HUB), d.collateralAmount);
        address pos = HUB.clone(d.source, d.collateralAmount, mintGross, d.expiration);
        collateral.forceApprove(address(HUB), 0);
        _clonedPosition = pos;

        // 2. Swap all ZCHF (equity + minted net) into collateral; it must cover the flashloan.
        uint256 received = _swap(collateral, d.swapData);
        if (received < assets) revert InsufficientSwapOutput(received, assets);

        // 3. Approve Morpho to pull the repayment.
        collateral.forceApprove(address(MORPHO), assets);

        // 4. Sweep leftovers (excess collateral, unspent ZCHF) to the recipient.
        uint256 excess = collateral.balanceOf(address(this)) - assets;
        if (excess > 0) collateral.safeTransfer(d.recipient, excess);
        uint256 zchfLeft = ZCHF.balanceOf(address(this));
        if (zchfLeft > 0) ZCHF.safeTransfer(d.recipient, zchfLeft);

        // 5. Hand the position to the recipient.
        IOwnableGeneric(pos).transferOwnership(d.recipient);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    function _run(
        address source,
        uint256 borrowAmount,
        uint256 collateralAmount,
        uint40 expiration,
        bytes calldata swapData
    ) internal returns (address leveragedPosition) {
        bytes memory data = abi.encode(
            CallbackData({
                source: source,
                recipient: msg.sender,
                collateralAmount: collateralAmount,
                expiration: expiration,
                swapData: swapData
            })
        );

        MORPHO.flashLoan(address(IPositionGeneric(source).collateral()), borrowAmount, data);

        leveragedPosition = _clonedPosition;
        _clonedPosition = address(0);
    }

    function _swap(IERC20 collateral, bytes memory swapData) internal returns (uint256 received) {
        uint256 collBefore = collateral.balanceOf(address(this));

        ZCHF.forceApprove(ROUTER, ZCHF.balanceOf(address(this)));
        (bool ok, bytes memory ret) = ROUTER.call(swapData);
        if (!ok) revert SwapFailed(ret);
        ZCHF.forceApprove(ROUTER, 0);

        received = collateral.balanceOf(address(this)) - collBefore;
    }
}
