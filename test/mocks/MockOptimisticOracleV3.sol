// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOptimisticOracleV3, IOptimisticOracleV3Callbacks} from "../../src/interfaces/IOptimisticOracleV3.sol";

/// @title MockOptimisticOracleV3 — Simulates UMA's OO V3 for testing
/// @dev Bond is pulled from msg.sender (adapter) but returned to asserter (proposer)
contract MockOptimisticOracleV3 is IOptimisticOracleV3 {
    using SafeERC20 for IERC20;

    uint256 private _nextAssertionId = 1;

    mapping(bytes32 => Assertion) private _assertions;
    mapping(bytes32 => address) private _callbackRecipients;
    mapping(bytes32 => bool) private _disputed;

    bytes32 public constant DEFAULT_IDENTIFIER = keccak256("ASSERT_TRUTH2");

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
    ) external override returns (bytes32 assertionId) {
        assertionId = bytes32(_nextAssertionId++);

        // pull bond from msg.sender (the adapter), not from asserter
        currency.safeTransferFrom(msg.sender, address(this), bond);

        _assertions[assertionId] = Assertion({
            escalationManager: escalationManager,
            assertingCaller: msg.sender,
            expirationTime: uint64(block.timestamp + liveness),
            settled: false,
            currency: currency,
            bond: bond,
            callbackRecipient: callbackRecipient,
            asserter: asserter, // proposer — receives bond back on truthful settlement
            domainId: domainId,
            identifier: identifier,
            settlementResolution: false,
            claim: claim
        });

        _callbackRecipients[assertionId] = callbackRecipient;
    }

    /// @notice Settle an assertion — call after liveness period
    function settleAssertion(bytes32 assertionId) external override {
        Assertion storage assertion = _assertions[assertionId];
        require(!assertion.settled, "already settled");
        require(block.timestamp >= assertion.expirationTime || _disputed[assertionId], "liveness not expired");

        assertion.settled = true;
        bool truthful = !_disputed[assertionId];
        assertion.settlementResolution = truthful;

        // return bond to ASSERTER (the proposer), not msg.sender or assertingCaller
        if (truthful) {
            assertion.currency.safeTransfer(assertion.asserter, assertion.bond);
        }

        // callback to the adapter (callbackRecipient)
        IOptimisticOracleV3Callbacks(_callbackRecipients[assertionId]).assertionResolvedCallback(assertionId, truthful);
    }

    /// @notice Simulate a dispute — triggers the disputed callback
    function disputeAssertion(bytes32 assertionId) external {
        require(!_assertions[assertionId].settled, "already settled");
        _disputed[assertionId] = true;

        IOptimisticOracleV3Callbacks(_callbackRecipients[assertionId]).assertionDisputedCallback(assertionId);
    }

    /// @notice Settle after dispute (DVM resolves) — test helper
    function settleDispute(bytes32 assertionId, bool truthful) external {
        Assertion storage assertion = _assertions[assertionId];
        require(!assertion.settled, "already settled");
        require(_disputed[assertionId], "not disputed");

        assertion.settled = true;
        assertion.settlementResolution = truthful;

        // return bond to asserter (proposer) if truthful
        if (truthful) {
            assertion.currency.safeTransfer(assertion.asserter, assertion.bond);
        }

        IOptimisticOracleV3Callbacks(_callbackRecipients[assertionId]).assertionResolvedCallback(assertionId, truthful);
    }

    function getAssertion(bytes32 assertionId) external view override returns (Assertion memory) {
        return _assertions[assertionId];
    }

    function getMinimumBond(address) external pure override returns (uint256) {
        return 100e18;
    }

    function defaultIdentifier() external pure override returns (bytes32) {
        return DEFAULT_IDENTIFIER;
    }
}
