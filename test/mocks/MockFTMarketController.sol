// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IFTMarketController} from "../../src/interfaces/IFTMarketController.sol";

/// @title MockFTMarketController — Simulates FortyTwo's controller for testing
contract MockFTMarketController is IFTMarketController {
    struct QuestionState {
        uint256 numOutcomes;
        uint128 timestampEnd;
        uint256 answer;
        bool finalised;
        bool exists;
    }

    mapping(bytes32 => QuestionState) public questions;

    // Track calls for assertion in tests
    bytes32 public lastResolvedQuestionId;
    uint256 public lastResolvedAnswer;
    bool public resolveCalled;
    bool public finaliseCalled;

    /// @notice Create a mock question for testing
    function createMockQuestion(bytes32 questionId, uint256 numOutcomes, uint128 timestampEnd) external {
        questions[questionId] = QuestionState({
            numOutcomes: numOutcomes, timestampEnd: timestampEnd, answer: 0, finalised: false, exists: true
        });
    }

    function resolveOutcome(bytes32 questionId, uint256 answer) external override {
        QuestionState storage q = questions[questionId];
        require(q.exists, "question does not exist");
        require(!q.finalised, "already finalised");

        q.answer = answer;
        lastResolvedQuestionId = questionId;
        lastResolvedAnswer = answer;
        resolveCalled = true;
    }

    function finaliseOutcome(bytes32 questionId, uint256 answerChallenge) external override {
        QuestionState storage q = questions[questionId];
        require(q.exists, "question does not exist");
        require(!q.finalised, "already finalised");
        require(q.answer == answerChallenge, "answer mismatch");

        q.finalised = true;
        finaliseCalled = true;
    }

    function isFinalised(bytes32 questionId) external view override returns (bool) {
        return questions[questionId].finalised;
    }

    function getOutcomeEnd(bytes32 questionId) external view override returns (uint128) {
        return questions[questionId].timestampEnd;
    }

    function getNumOutcomes(bytes32 questionId) external view override returns (uint256) {
        return questions[questionId].numOutcomes;
    }

    function getOutcomeAnswer(bytes32 questionId) external view override returns (uint256) {
        return questions[questionId].answer;
    }

    /// @notice Reset tracking flags between tests
    function resetTracking() external {
        resolveCalled = false;
        finaliseCalled = false;
        lastResolvedQuestionId = bytes32(0);
        lastResolvedAnswer = 0;
    }
}
