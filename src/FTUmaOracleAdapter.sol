// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IOptimisticOracleV3, IOptimisticOracleV3Callbacks} from "./interfaces/IOptimisticOracleV3.sol";
import {IFTMarketController} from "./interfaces/IFTMarketController.sol";

/**
 * @title FTUmaOracleAdapter
 * @notice Resolves FortyTwo prediction markets via UMA's Optimistic Oracle V3.
 * Holds QUESTION_RESOLVER_ROLE and QUESTION_FINALISER_ROLE on the CONTROLLER.
 * @dev Adapter pattern: a translator between UMA and FTMarketController.
 * Stores only translation mappings (assertionId <-> questionId). Bond, liveness,
 * and dispute state are managed by UMA. Bond is returned directly to the proposer
 * by UMA on settlement — the adapter never holds or returns bond tokens.
 */
contract FTUmaOracleAdapter is IOptimisticOracleV3Callbacks, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct AssertionData {
        bytes32 questionId;
        uint256 answer;
        address proposer;
    }

    IOptimisticOracleV3 public immutable ORACLE_V3;
    IFTMarketController public immutable CONTROLLER;
    IERC20 public immutable BOND_TOKEN;

    // ASSERT_TRUTH2 identifier — ASSERT_TRUTH is deprecated and reverts
    bytes32 public constant ASSERT_TRUTH_IDENTIFIER = "ASSERT_TRUTH2";

    uint256 public constant SAFETY_PERIOD = 1 hours;

    uint256 public defaultBond;
    uint64 public defaultLiveness;

    // assertionId -> assertion data
    mapping(bytes32 => AssertionData) public assertions;

    // questionId -> pending assertionId (one at a time)
    mapping(bytes32 => bytes32) public questionToAssertion;

    enum QuestionStatus {
        ACTIVE,
        FLAGGED
    }

    struct QuestionState {
        uint40 flagDeadline; // non-zero = flagged, stores block.timestamp + SAFETY_PERIOD
        QuestionStatus status; // question status
    }

    // questionId -> flag state (packed into 1 slot)
    mapping(bytes32 => QuestionState) public questionState;

    ////// EVENTS //////

    // emitted when a proposer submits an answer via proposeAnswer()
    event AnswerProposed(bytes32 indexed questionId, bytes32 indexed assertionId, uint256 answer, address proposer);

    // emitted when UMA callback resolves a market on the CONTROLLER
    event QuestionResolved(bytes32 indexed questionId, bytes32 indexed assertionId, uint256 answer);

    // emitted when someone disputes an assertion on UMA
    event AssertionDisputed(bytes32 indexed questionId, bytes32 indexed assertionId);

    // emitted when admin force-resolves after safety period
    event EmergencyResolved(bytes32 indexed questionId, uint256 answer, address admin);

    // emitted when admin flags a question for manual resolution
    event QuestionFlagged(bytes32 indexed questionId);

    // emitted when admin cancels a flag before safety period expires
    event QuestionUnflagged(bytes32 indexed questionId);

    // emitted when admin updates the default bond amount
    event DefaultBondSet(uint256 newBond);

    // emitted when admin updates the default liveness period
    event DefaultLivenessSet(uint64 newLiveness);

    ////// ERRORS //////

    error NotOracle();
    error ProposalAlreadyPending();
    error InvalidAnswer();
    error QuestionAlreadyFinalised();
    error QuestionNotExpired();
    error QuestionNotFlagged();
    error QuestionAlreadyFlagged();
    error QuestionFlaggedForResolution();
    error SafetyPeriodNotPassed();
    error SafetyPeriodAlreadyPassed();
    error UnknownAssertion();
    error InvalidBond();
    error InvalidLiveness();

    modifier onlyOracle() {
        if (msg.sender != address(ORACLE_V3)) revert NotOracle();
        _;
    }

    constructor(
        address _oracleV3,
        address _controller,
        address _bondToken,
        uint256 _defaultBond,
        uint64 _defaultLiveness
    ) Ownable(msg.sender) {
        ORACLE_V3 = IOptimisticOracleV3(_oracleV3);
        CONTROLLER = IFTMarketController(_controller);
        BOND_TOKEN = IERC20(_bondToken);
        defaultBond = _defaultBond;
        defaultLiveness = _defaultLiveness;
    }

    /**
     * @notice Propose an answer for a question. Permissionless — bond is the gatekeeper.
     * @dev Caller must have approved BOND_TOKEN to this contract.
     * Bond is pulled through the adapter to UMA, but the asserter is set to msg.sender.
     * UMA returns the bond directly to the proposer on truthful settlement.
     * @param questionId The FortyTwo question to resolve
     * @param answer The proposed answer bitmask (bit i set = outcome i won)
     * @return assertionId The UMA assertion ID
     */
    function proposeAnswer(bytes32 questionId, uint256 answer) external nonReentrant returns (bytes32 assertionId) {
        _validateProposal(questionId, answer);

        // pull bond from proposer, approve UMA to pull from adapter
        BOND_TOKEN.safeTransferFrom(msg.sender, address(this), defaultBond);
        BOND_TOKEN.forceApprove(address(ORACLE_V3), defaultBond); // reset to 0 first and approve again

        // assert on UMA — asserter is the proposer (receives bond back directly)
        bytes memory claim = _buildClaim(questionId, answer, msg.sender);

        assertionId = ORACLE_V3.assertTruth(
            claim,
            msg.sender, // asserter: proposer gets bond back directly from UMA
            address(this), // callbackRecipient: adapter receives callbacks
            address(0), // escalationManager: UMA default
            defaultLiveness,
            BOND_TOKEN,
            defaultBond,
            ASSERT_TRUTH_IDENTIFIER,
            bytes32(0)
        );

        // store translation mapping
        assertions[assertionId] = AssertionData({questionId: questionId, answer: answer, proposer: msg.sender});

        questionToAssertion[questionId] = assertionId;

        emit AnswerProposed(questionId, assertionId, answer, msg.sender);
    }

    /**
     * @notice Called by UMA when an assertion settles (liveness expired or dispute resolved).
     * If truthful and market not yet resolved: resolves + finalises the market on the CONTROLLER.
     * If not truthful: cleans up, allows re-proposal.
     * If question was flagged or already finalised: just cleans up.
     * @dev Bond is returned directly to the proposer by UMA — adapter doesn't handle bond returns.
     */
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully)
        external
        override
        onlyOracle
        nonReentrant
    {
        AssertionData memory data = assertions[assertionId];
        if (data.questionId == bytes32(0)) revert UnknownAssertion();

        // resolve the market if truthful, active, and not already finalised
        bool shouldResolve = assertedTruthfully && questionState[data.questionId].status == QuestionStatus.ACTIVE
            && !CONTROLLER.isFinalised(data.questionId);

        if (shouldResolve) {
            CONTROLLER.resolveOutcome(data.questionId, data.answer);
            CONTROLLER.finaliseOutcome(data.questionId, data.answer);
            emit QuestionResolved(data.questionId, assertionId, data.answer);
        }

        // still clean up — stateless between cycles, eventhough didn't resolve/finalise
        delete assertions[assertionId];
        // only delete questionToAssertion if it still points to THIS assertion
        // a newer proposal may have replaced it after a dispute
        if (questionToAssertion[data.questionId] == assertionId) {
            delete questionToAssertion[data.questionId];
        }
    }

    /**
     * @notice Called by UMA when an assertion is disputed (before DVM resolves).
     * Clears pending state so the question isn't stuck during DVM vote.
     * @dev Keeps assertions[assertionId] because assertionResolvedCallback still needs it after DVM.
     */
    function assertionDisputedCallback(bytes32 assertionId) external override onlyOracle nonReentrant {
        AssertionData memory data = assertions[assertionId];
        if (data.questionId == bytes32(0)) revert UnknownAssertion();

        // clear pending state — new proposals allowed during DVM vote
        // keep assertions[assertionId] — callback still needs it after DVM resolves
        delete questionToAssertion[data.questionId];

        emit AssertionDisputed(data.questionId, assertionId);
    }

    /**
     * @notice Flag a question for manual resolution.
     * Pauses UMA resolution and starts a safety timer. Admin must wait before resolving.
     */
    function flag(bytes32 questionId) external onlyOwner {
        QuestionState storage state = questionState[questionId];

        if (state.flagDeadline != 0) revert QuestionAlreadyFlagged();

        if (CONTROLLER.isFinalised(questionId)) revert QuestionAlreadyFinalised();

        state.flagDeadline = uint40(block.timestamp + SAFETY_PERIOD);
        state.status = QuestionStatus.FLAGGED;

        emit QuestionFlagged(questionId);
    }

    /**
     * @notice Cancel manual resolution — only before safety period expires.
     */
    function unflag(bytes32 questionId) external onlyOwner {
        QuestionState storage state = questionState[questionId];
        if (state.flagDeadline == 0) revert QuestionNotFlagged();
        if (block.timestamp >= state.flagDeadline) revert SafetyPeriodAlreadyPassed();

        state.flagDeadline = 0;
        state.status = QuestionStatus.ACTIVE;

        emit QuestionUnflagged(questionId);
    }

    /**
     * @notice Manually resolve a question after safety period has passed.
     * @dev Validates answer, resolves directly on CONTROLLER. Any pending UMA assertion
     * will settle normally — the callback will see isFinalised and skip resolution.
     * Bond is returned directly to the proposer by UMA regardless of emergency resolve.
     */
    function emergencyResolve(bytes32 questionId, uint256 answer) external onlyOwner nonReentrant {
        QuestionState storage state = questionState[questionId];
        if (state.flagDeadline == 0) revert QuestionNotFlagged();
        if (block.timestamp < state.flagDeadline) revert SafetyPeriodNotPassed();

        uint256 numOutcomes = CONTROLLER.getNumOutcomes(questionId);
        if (answer == 0 || answer >= (uint256(1) << numOutcomes)) revert InvalidAnswer();

        CONTROLLER.resolveOutcome(questionId, answer);
        CONTROLLER.finaliseOutcome(questionId, answer);

        state.flagDeadline = 0;
        state.status = QuestionStatus.ACTIVE;

        emit EmergencyResolved(questionId, answer, msg.sender);
    }

    function setDefaultBond(uint256 newBond) external onlyOwner {
        if (newBond == 0) revert InvalidBond();
        defaultBond = newBond;
        emit DefaultBondSet(newBond);
    }

    function setDefaultLiveness(uint64 newLiveness) external onlyOwner {
        if (newLiveness == 0) revert InvalidLiveness();
        defaultLiveness = newLiveness;
        emit DefaultLivenessSet(newLiveness);
    }

    function _validateProposal(bytes32 questionId, uint256 answer) internal view {
        uint128 timestampEnd = CONTROLLER.getOutcomeEnd(questionId);
        if (block.timestamp < timestampEnd) revert QuestionNotExpired();

        if (CONTROLLER.isFinalised(questionId)) revert QuestionAlreadyFinalised();

        uint256 numOutcomes = CONTROLLER.getNumOutcomes(questionId);
        if (answer == 0 || answer >= (uint256(1) << numOutcomes)) revert InvalidAnswer();

        if (questionToAssertion[questionId] != bytes32(0)) revert ProposalAlreadyPending();

        if (questionState[questionId].status == QuestionStatus.FLAGGED) revert QuestionFlaggedForResolution();
    }

    /// @dev Builds a human-readable claim string for UMA DVM voters to verify during disputes.
    /// Follows UMA best practices (see DataAsserter example): self-contained, includes contract
    /// address, timestamp, asserter, and decoded bitmask so voters can independently verify
    /// without needing external context. Binary representation included because raw bitmask
    /// values (e.g. "3") are not intuitive — "binary: 11" makes winning outcomes immediately clear.
    function _buildClaim(bytes32 questionId, uint256 answer, address asserter) internal view returns (bytes memory) {
        return abi.encodePacked(
            "FortyTwo market resolution. questionId: ",
            Strings.toHexString(uint256(questionId), 32),
            ", answer bitmask: ",
            Strings.toString(answer),
            " (binary: ",
            _toBinaryString(answer),
            "), resolved by asserter: ",
            Strings.toHexString(asserter),
            ", at timestamp: ",
            Strings.toString(block.timestamp),
            ", via adapter contract: ",
            Strings.toHexString(address(this)),
            ". Bit i set in bitmask means outcome i won."
        );
    }

    function _toBinaryString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";

        // find highest set bit
        uint256 temp = value;
        uint256 length;
        while (temp > 0) {
            length++;
            temp >>= 1;
        }

        bytes memory result = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            result[length - 1 - i] = (value & (uint256(1) << i)) != 0 ? bytes1("1") : bytes1("0");
        }
        return string(result);
    }

    function hasPendingProposal(bytes32 questionId) external view returns (bool) {
        return questionToAssertion[questionId] != bytes32(0);
    }

    function getPendingProposal(bytes32 questionId) external view returns (AssertionData memory) {
        return assertions[questionToAssertion[questionId]];
    }

    /// @dev Returns true when UMA liveness has expired and the assertion is unsettled
    function ready(bytes32 questionId) external view returns (bool) {
        bytes32 assertionId = questionToAssertion[questionId];
        if (assertionId == bytes32(0)) return false;
        if (questionState[questionId].status != QuestionStatus.ACTIVE) return false;

        IOptimisticOracleV3.Assertion memory assertion = ORACLE_V3.getAssertion(assertionId);
        return block.timestamp >= assertion.expirationTime && !assertion.settled;
    }

    function isFlagged(bytes32 questionId) external view returns (bool) {
        return questionState[questionId].flagDeadline != 0;
    }
}
