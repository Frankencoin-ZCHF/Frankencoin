// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

contract Arbitrage is IUniswapV3SwapCallback {

    IERC20 public immutable ZCHF;
    IERC20 public immutable USDT;

    IUniswapV3Pool public immutable POOL;
    AggregatorV3Interface public immutable FEED;

    event Balanced(uint256 priceBeforeE8, uint256 targetE8, uint256 priceAfterE8, int256 zchfFlowE18, int256 usdFlowE6, int256 profitsE6);
    error NotProfitableEnough(int256 zchfFlowE18, int256 usdFlowE6, int256 profitsE6);

    constructor() {
        POOL = IUniswapV3Pool(0x8E4318E2cb1ae291254B187001a59a1f8ac78cEF);
        FEED = AggregatorV3Interface(0x449d117117838fFA61263B61dA6301AA2a88B13A);
        ZCHF = IERC20(0xB58E61C3098d85632Df34EecfB899A1Ed80921cB);
        USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    }

    function getChainlinkPrice() public view returns (uint256) {
        (, int256 price,,,) = FEED.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price); // 8 decimals
    }

    function convertToUniswapPrice(uint256 chainlinkPrice) public pure returns (uint160){
        uint256 temp = chainlinkPrice << 192; // should not cause overflow as 1e8 is much less than 256 - 192 = 64 bits, whereas chainlink's 8 decimals are about 24 bits
        return uint160(sqrt(temp) / 1e10);
    }

    function getUniswapPrice() public view returns (uint160) {
        (uint160 sqrtPriceX96,,,,,,) = POOL.slot0();
        return sqrtPriceX96;
    }

    function convertToChainlinkPrice(uint160 sqrtPriceX96) public pure returns (uint256){
        uint256 temp = sqrtPriceX96 * (1e10) >> 96;
        return temp * temp; // price ratio with 8 digits
    }

    function balance(int256 minProfitUSDTe6) external returns(int256, uint160, bytes memory) {
        uint160 currentPrice = getUniswapPrice();

        uint256 chainlinkPrice = getChainlinkPrice();
        uint160 targetSqrtPriceX96 = convertToUniswapPrice(chainlinkPrice);
        bool buyCHF = currentPrice < targetSqrtPriceX96;
        int256 balanceZCHFBefore = int256(ZCHF.balanceOf(msg.sender));
        int256 balanceUSDTBefore = int256(USDT.balanceOf(msg.sender));
        int256 max = buyCHF ? balanceUSDTBefore : balanceZCHFBefore;

        POOL.swap(msg.sender, !buyCHF, max, targetSqrtPriceX96, abi.encode(msg.sender));

        int256 balanceZCHFAfter = int256(ZCHF.balanceOf(msg.sender));
        int256 balanceUSDTAfter = int256(USDT.balanceOf(msg.sender));

        int256 flowCHF = balanceZCHFAfter - balanceZCHFBefore;
        int256 flowUSD = balanceUSDTAfter - balanceUSDTBefore;
        int256 profits = flowUSD * 1e12 + flowCHF * int256(uint256(chainlinkPrice)) / 1e8;
        if (profits < minProfitUSDTe6) revert NotProfitableEnough(flowCHF, flowUSD, profits);
        emit Balanced(convertToChainlinkPrice(currentPrice), chainlinkPrice, convertToChainlinkPrice(getUniswapPrice()), flowCHF, flowUSD, profits);
    }

    function swap(bool buyCHF, int256 max, uint160 targetPrice) external {
        POOL.swap(msg.sender, !buyCHF, max, targetPrice, abi.encode(msg.sender));
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == address(POOL), "Unauthorized");
        address sender = abi.decode(data, (address));
        if (amount0Delta > 0) {
            IERC20(ZCHF).transferFrom(sender, msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(USDT).transferFrom(sender, msg.sender, uint256(amount1Delta));
        }
    }
}

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external;
    function balanceOf(address owner) external returns (uint256);
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IUniswapV3Pool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external;
}