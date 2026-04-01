// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IOptimisticOracleV3 — Vendored minimal interface for UMA's Optimistic Oracle V3
/// @dev Full interface: https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol
interface IOptimisticOracleV3 {
    struct Assertion {
        address escalationManager;
        address assertingCaller;
        uint64 expirationTime;
        bool settled;
        IERC20 currency;
        uint256 bond;
        address callbackRecipient;
        address asserter;
        bytes32 domainId;
        bytes32 identifier;
        bool settlementResolution;
        bytes claim;
    }

    /// @notice Assert a truth claim
    /// @param claim Human-readable claim text
    /// @param asserter Address that posts the bond
    /// @param callbackRecipient Address that receives resolved/disputed callbacks
    /// @param escalationManager Optional custom escalation logic (address(0) for default)
    /// @param liveness Duration in seconds before unchallenged assertion settles
    /// @param currency ERC20 token used for the bond
    /// @param bond Bond amount
    /// @param identifier UMA price identifier (typically ASSERT_TRUTH)
    /// @param domainId Optional domain identifier
    /// @return assertionId Unique identifier for this assertion
    function assertTruth(
        bytes calldata claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId);

    /// @notice Settle an assertion after liveness expires
    function settleAssertion(bytes32 assertionId) external;

    /// @notice Get assertion data
    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);

    /// @notice Get minimum bond for a given currency
    function getMinimumBond(address currency) external view returns (uint256);

    /// @notice The default identifier used for assertions
    function defaultIdentifier() external view returns (bytes32);
}

/// @title IOptimisticOracleV3Callbacks — Callbacks the adapter must implement
/// @dev UMA calls these on the callbackRecipient after settlement or dispute
interface IOptimisticOracleV3Callbacks {
    /// @notice Called when an assertion is settled
    /// @param assertionId The assertion that was settled
    /// @param assertedTruthfully true if assertion stood, false if it was wrong
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    /// @notice Called when an assertion is disputed
    /// @param assertionId The assertion that was disputed
    function assertionDisputedCallback(bytes32 assertionId) external;
}
