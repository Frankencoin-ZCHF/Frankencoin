// SPDX-License-Identifier: MIT
// Code generated with https://etherscan.io/address/0x027b40f5917fcd0eac57d7015e120096a5f92ca9#code as input.
pragma solidity 0.8.24;

interface ITwocrypto {
    // --- Events ---
    event SetPeriphery(address views, address math);
    event Transfer(address indexed sender, address indexed receiver, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TokenExchange(address indexed buyer, uint256 sold_id, uint256 tokens_sold, uint256 bought_id, uint256 tokens_bought, uint256 fee, uint256 price_scale);
    event AddLiquidity(address indexed provider, address indexed receiver, uint256[2] token_amounts, uint256 fee, uint256 token_supply, uint256 price_scale);
    event Donation(address indexed donor, uint256[2] token_amounts);
    event RemoveLiquidity(address indexed provider, uint256[2] token_amounts, uint256 token_supply);
    event RemoveLiquidityOne(address indexed provider, uint256 token_amount, uint256 coin_index, uint256 coin_amount, uint256 approx_fee, uint256 packed_price_scale);
    event RemoveLiquidityImbalance(address indexed provider, uint256 lp_token_amount, uint256[2] token_amounts, uint256 approx_fee, uint256 price_scale);
    event NewParameters(uint256 mid_fee, uint256 out_fee, uint256 fee_gamma, uint256 allowed_extra_profit, uint256 adjustment_step, uint256 ma_time);
    event RampAgamma(uint256 initial_A, uint256 future_A, uint256 initial_gamma, uint256 future_gamma, uint256 initial_time, uint256 future_time);
    event StopRampA(uint256 current_A, uint256 current_gamma, uint256 time);
    event ClaimAdminFee(address indexed admin, uint256[2] tokens);
    event SetDonationDuration(uint256 duration);
    event SetDonationProtection(uint256 donation_protection_period, uint256 donation_protection_lp_threshold, uint256 donation_shares_max_ratio);
    event SetAdminFee(uint256 admin_fee);

    // --- Swap ---
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);

    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy, address receiver) external returns (uint256);

    function exchange_received(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);

    function exchange_received(uint256 i, uint256 j, uint256 dx, uint256 min_dy, address receiver) external returns (uint256);

    // --- Liquidity ---
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external returns (uint256);

    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount, address receiver) external returns (uint256);

    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount, address receiver, bool donation) external returns (uint256);

    function remove_liquidity(uint256 amount, uint256[2] calldata min_amounts) external returns (uint256[2] memory);

    function remove_liquidity(uint256 amount, uint256[2] calldata min_amounts, address receiver) external returns (uint256[2] memory);

    function remove_liquidity_fixed_out(uint256 token_amount, uint256 i, uint256 amount_i, uint256 min_amount_j) external returns (uint256);

    function remove_liquidity_fixed_out(uint256 token_amount, uint256 i, uint256 amount_i, uint256 min_amount_j, address receiver) external returns (uint256);

    function remove_liquidity_one_coin(uint256 lp_token_amount, uint256 i, uint256 min_amount) external returns (uint256);

    function remove_liquidity_one_coin(uint256 lp_token_amount, uint256 i, uint256 min_amount, address receiver) external returns (uint256);

    // --- ERC20 ---
    function transfer(address _to, uint256 _value) external returns (bool);

    function transferFrom(address _from, address _to, uint256 _value) external returns (bool);

    function approve(address _spender, uint256 _value) external returns (bool);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function version() external view returns (string memory);

    function balanceOf(address arg0) external view returns (uint256);

    function allowance(address arg0, address arg1) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    // --- Price / fee queries ---
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);

    function get_dx(uint256 i, uint256 j, uint256 dy) external view returns (uint256);

    function get_dx(uint256 i, uint256 j, uint256 dy, uint256 n_iter) external view returns (uint256);

    function calc_token_amount(uint256[2] calldata amounts, bool deposit) external view returns (uint256);

    function calc_withdraw_one_coin(uint256 lp_token_amount, uint256 i) external view returns (uint256);

    function calc_withdraw_fixed_out(uint256 lp_token_amount, uint256 i, uint256 amount_i) external view returns (uint256);

    function calc_token_fee(uint256[2] calldata amounts, uint256[2] calldata xp) external view returns (uint256);

    function calc_token_fee(uint256[2] calldata amounts, uint256[2] calldata xp, bool donation) external view returns (uint256);

    function calc_token_fee(uint256[2] calldata amounts, uint256[2] calldata xp, bool donation, bool deposit) external view returns (uint256);

    function fee_calc(uint256[2] calldata xp) external view returns (uint256);

    function lp_price() external view returns (uint256);

    function get_virtual_price() external view returns (uint256);

    function price_oracle() external view returns (uint256);

    function price_scale() external view returns (uint256);

    function fee() external view returns (uint256);

    // --- Pool state ---
    function user_supply() external view returns (uint256);

    function A() external view returns (uint256);

    function gamma() external view returns (uint256);

    function D() external view returns (uint256);

    function balances(uint256 arg0) external view returns (uint256);

    function coins(uint256 arg0) external view returns (address);

    function precisions() external view returns (uint256[2] memory);

    function last_prices() external view returns (uint256);

    function last_timestamp() external view returns (uint256);

    function virtual_price() external view returns (uint256);

    function xcp_profit() external view returns (uint256);

    function xcp_profit_a() external view returns (uint256);

    // --- Fee params ---
    function mid_fee() external view returns (uint256);

    function out_fee() external view returns (uint256);

    function fee_gamma() external view returns (uint256);

    function admin_fee() external view returns (uint256);

    function packed_fee_params() external view returns (uint256);

    // --- Rebalancing params ---
    function allowed_extra_profit() external view returns (uint256);

    function adjustment_step() external view returns (uint256);

    function ma_time() external view returns (uint256);

    function packed_rebalancing_params() external view returns (uint256);

    // --- A/gamma ramp ---
    function initial_A_gamma() external view returns (uint256);

    function initial_A_gamma_time() external view returns (uint256);

    function future_A_gamma() external view returns (uint256);

    function future_A_gamma_time() external view returns (uint256);

    // --- Donation ---
    function donation_shares() external view returns (uint256);

    function donation_shares_max_ratio() external view returns (uint256);

    function donation_duration() external view returns (uint256);

    function last_donation_release_ts() external view returns (uint256);

    function donation_protection_expiry_ts() external view returns (uint256);

    function donation_protection_period() external view returns (uint256);

    function donation_protection_lp_threshold() external view returns (uint256);

    // --- Addresses ---
    function fee_receiver() external view returns (address);

    function admin() external view returns (address);

    function MATH() external view returns (address);

    function VIEW() external view returns (address);

    function factory() external view returns (address);

    // --- Admin ---
    function ramp_A_gamma(uint256 future_A, uint256 future_gamma, uint256 future_time) external;

    function stop_ramp_A_gamma() external;

    function apply_new_parameters(uint256 _new_mid_fee, uint256 _new_out_fee, uint256 _new_fee_gamma, uint256 _new_allowed_extra_profit, uint256 _new_adjustment_step, uint256 _new_ma_time) external;

    function set_donation_duration(uint256 duration) external;

    function set_donation_protection_params(uint256 _period, uint256 _threshold, uint256 _max_shares_ratio) external;

    function set_admin_fee(uint256 admin_fee) external;

    function set_periphery(address views, address math) external;
}
