// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FCSPrimaryHook} from "../src/FCSPrimaryHook.sol";
import {FCSPrimaryRouter} from "../src/FCSPrimaryRouter.sol";

/// @notice Executes one real swap through the bundled FCSPrimaryRouter against the live, deployed,
/// verified hook and pool. Uses the router's settle-first flow, so unlike a Universal-Router-style
/// default-encoding swap, it never depends on the PoolManager singleton's ambient float. This is the
/// way to actually test the pool right now: app.uniswap.org doesn't discover/route to it yet (README:
/// "Universal Router, Uniswap UI and aggregator discovery/inclusion are not supplied or implied by
/// deployment").
/// @dev Reads the broadcaster from PRIVATE_KEY directly (not ambient msg.sender/--sender), so the
/// balance/allowance checks below are guaranteed to be for the actual account that will trade.
/// Configure via env vars, all optional:
///   SWAP_BUY_FCS      true = ZCHF -> FCS (default), false = FCS -> ZCHF
///   SWAP_AMOUNT_IN     raw wei amount of the input token (default 10e18, i.e. 10 tokens)
///   SWAP_SLIPPAGE_BPS  minOut tolerance below the live quote, in basis points (default 50 = 0.5%)
contract Swap is Script {
    address public constant HOOK = 0x747a076611A138ae063179800D43d8aE33b7E888;
    address public constant ROUTER = 0xc056Bb03EB2eF7F86f570AAB52C8Fba13B3E8566;

    error QuoteUnavailable(FCSPrimaryHook.QuoteStatus status);
    error InsufficientBalance(uint256 have, uint256 need);

    function run() external {
        FCSPrimaryHook hook = FCSPrimaryHook(HOOK);
        FCSPrimaryRouter router = FCSPrimaryRouter(ROUTER);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address trader = vm.addr(pk);

        bool buyFCS = vm.envOr("SWAP_BUY_FCS", true);
        uint256 amountIn = vm.envOr("SWAP_AMOUNT_IN", uint256(1e18));
        uint256 slippageBps = vm.envOr("SWAP_SLIPPAGE_BPS", uint256(50));

        address input = buyFCS ? hook.ZCHF() : address(hook.FCS());
        uint256 balance = IERC20(input).balanceOf(trader);
        if (balance < amountIn) revert InsufficientBalance(balance, amountIn);

        (uint256 quoted, bool available, FCSPrimaryHook.QuoteStatus status) = hook.quoteExactInput(buyFCS, amountIn);
        if (!available) revert QuoteUnavailable(status);
        uint256 minOut = quoted - ((quoted * slippageBps) / 10_000);

        console2.log("Trader              ", trader);
        console2.log("Direction (true=buyFCS)", buyFCS);
        console2.log("Input token         ", input);
        console2.log("Amount in           ", amountIn);
        console2.log("Live quote          ", quoted);
        console2.log("Min out (with slippage)", minOut);

        vm.startBroadcast(pk);
        IERC20(input).approve(ROUTER, amountIn);
        uint256 amountOut = router.swapExactInput(buyFCS, amountIn, minOut, trader, block.timestamp + 300);
        vm.stopBroadcast();

        console2.log("SUCCESS: received", amountOut);
    }
}
