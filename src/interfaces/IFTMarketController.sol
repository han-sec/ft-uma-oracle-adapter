// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

/// @title IFTMarketController — Minimal interface for FortyTwo's FTMarketController
/// @notice Only the functions the oracle adapter needs to resolve markets and validate proposals
/// @dev Sourced from FTMarketController.sol and IRegistry.sol in the FortyTwo protocol
interface IFTMarketController {
    // Resolution (adapter needs QUESTION_RESOLVER_ROLE + QUESTION_FINALISER_ROLE)

    /// @notice Set the answer bitmask for a question (can re-resolve before finalisation)
    function resolveOutcome(bytes32 questionId, uint256 answer) external;

    /// @notice Lock the answer permanently — enables claims
    function finaliseOutcome(bytes32 questionId, uint256 answerChallenge) external;

    // ── Validation (view functions from IRegistry) ──

    /// @notice Check if a question has been finalised
    function isFinalised(bytes32 questionId) external view returns (bool);

    /// @notice Get the trading end timestamp for a question
    function getOutcomeEnd(bytes32 questionId) external view returns (uint128);

    /// @notice Get the number of outcomes for a question
    function getNumOutcomes(bytes32 questionId) external view returns (uint256);

    /// @notice Get the current answer for a question (0 if unresolved)
    function getOutcomeAnswer(bytes32 questionId) external view returns (uint256);
}
