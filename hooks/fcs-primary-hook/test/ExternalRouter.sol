// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev TEST ONLY: lets tests send adversarial payloads. Not a production user router.
contract ExternalRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    IPoolManager immutable manager;

    struct Request {
        address payer;
        PoolKey key;
        SwapParams params;
        bytes hookData;
        bool prefund;
        bool roundtrip;
        bool liquidity;
    }

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData, bool prefund, bool roundtrip)
        external
        returns (uint256 out)
    {
        return abi.decode(
            manager.unlock(abi.encode(Request(msg.sender, key, params, hookData, prefund, roundtrip, false))), (uint256)
        );
    }

    function addLiquidity(PoolKey memory key) external {
        manager.unlock(abi.encode(Request(msg.sender, key, SwapParams(false, 0, 0), "", false, false, true)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        Request memory r = abi.decode(data, (Request));
        if (r.liquidity) {
            manager.modifyLiquidity(r.key, ModifyLiquidityParams(-10, 10, 100, 0), "");
            return "";
        }
        Currency input = r.params.zeroForOne ? r.key.currency0 : r.key.currency1;
        Currency output = r.params.zeroForOne ? r.key.currency1 : r.key.currency0;
        if (r.prefund) {
            manager.sync(input);
            IERC20(Currency.unwrap(input)).transferFrom(r.payer, address(manager), uint256(-r.params.amountSpecified));
            manager.settle();
        }
        BalanceDelta d = manager.swap(r.key, r.params, r.hookData);
        uint256 out = uint256(uint128(r.params.zeroForOne ? d.amount1() : d.amount0()));
        if (r.roundtrip) {
            bool z = !r.params.zeroForOne;
            d = manager.swap(
                r.key,
                SwapParams(z, -int256(out), z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
                r.hookData
            );
            output = input;
            out = uint256(uint128(z ? d.amount1() : d.amount0()));
        }
        manager.take(output, r.payer, out);
        return abi.encode(out);
    }
}
