// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IReferenceTransfer {
    /// @notice Emitted when a user sets or clears their auto-save target
    event AutoSave(address indexed to, address target);

    /// @notice Emitted on a transfer with a reference string
    event Transfer(address indexed from, address indexed to, uint256 amount, string ref);

    /// @notice Reverts when the allowance is not set to infinite
    error InfiniteAllowanceRequired(address owner, address spender);

    /// @notice Transfers tokens to a recipient with a reference
    /// @param recipient The address receiving the tokens
    /// @param amount The amount of tokens to transfer
    /// @param ref A reference string to log with the transfer
    /// @return success True if the transfer was successful
    function transfer(address recipient, uint256 amount, string calldata ref) external returns (bool success);

    /// @notice Transfers tokens from another user with a reference
    /// @param owner The address providing the tokens
    /// @param recipient The address receiving the tokens
    /// @param amount The amount of tokens to transfer
    /// @param ref A reference string to log with the transfer
    /// @return success True if the transfer was successful
    function transferFrom(
        address owner,
        address recipient,
        uint256 amount,
        string calldata ref
    ) external returns (bool success);

    /// @notice Sets an auto-save contract for the sender
    /// @param target The address of the ISavings contract
    function setAutoSave(address target) external;

    /// @notice Clears the sender's auto-save target
    function clearAutoSave() external;

    /// @notice Returns the auto-save contract address set for a user
    /// @param user The address of the user
    /// @return target The address of the user's auto-save target
    function hasAutoSave(address user) external view returns (address target);
}
