// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FTUmaOracleAdapter} from "../src/FTUmaOracleAdapter.sol";
import {MockOptimisticOracleV3} from "./mocks/MockOptimisticOracleV3.sol";
import {MockFTMarketController} from "./mocks/MockFTMarketController.sol";

contract MockBondToken is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FTUmaOracleAdapterTest is Test {
    FTUmaOracleAdapter adapter;
    MockOptimisticOracleV3 oracle;
    MockFTMarketController controller;
    MockBondToken bondToken;

    address admin = makeAddr("admin");
    address proposer = makeAddr("proposer");
    address disputer = makeAddr("disputer");
    address user = makeAddr("user");

    bytes32 questionId = keccak256("Will BTC hit 200k by Dec 2026?");
    uint256 constant DEFAULT_BOND = 1000e18;
    uint64 constant DEFAULT_LIVENESS = 7200; // 2 hours
    uint256 constant ANSWER_YES = 1; // bitmask: bit 0 set = outcome 0 won
    uint256 constant ANSWER_NO = 2; // bitmask: bit 1 set = outcome 1 won

    function setUp() public {
        vm.startPrank(admin);

        bondToken = new MockBondToken();
        oracle = new MockOptimisticOracleV3();
        controller = new MockFTMarketController();

        adapter = new FTUmaOracleAdapter(
            address(oracle), address(controller), address(bondToken), DEFAULT_BOND, DEFAULT_LIVENESS
        );

        // Create a question: 2 outcomes, expires in 1 day
        controller.createMockQuestion(questionId, 2, uint128(block.timestamp + 1 days));

        vm.stopPrank();

        // Fund proposer with bond tokens and approve adapter
        bondToken.mint(proposer, 100_000e18);
        vm.prank(proposer);
        bondToken.approve(address(adapter), type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════
    //  Happy Path: propose -> liveness -> settle -> resolved
    // ════════════════════════════════════════════════════════════════

    function test_happyPath() public {
        vm.warp(block.timestamp + 1 days + 1);

        uint256 proposerBalanceBefore = bondToken.balanceOf(proposer);

        vm.prank(proposer);
        bytes32 assertionId = adapter.proposeAnswer(questionId, ANSWER_YES);

        // Verify state
        assertTrue(adapter.hasPendingProposal(questionId));
        FTUmaOracleAdapter.AssertionData memory data = adapter.getPendingProposal(questionId);
        assertEq(data.questionId, questionId);
        assertEq(data.answer, ANSWER_YES);
        assertEq(data.proposer, proposer);

        // Warp past liveness
        vm.warp(block.timestamp + DEFAULT_LIVENESS + 1);

        // Settle on UMA -> triggers callback
        oracle.settleAssertion(assertionId);

        // Verify market was resolved
        assertTrue(controller.resolveCalled());
        assertTrue(controller.finaliseCalled());
        assertEq(controller.lastResolvedAnswer(), ANSWER_YES);

        // Verify adapter cleaned up
        assertFalse(adapter.hasPendingProposal(questionId));

        // Verify bond returned directly to proposer by UMA (not via adapter)
        assertEq(bondToken.balanceOf(proposer), proposerBalanceBefore);
        assertEq(bondToken.balanceOf(address(adapter)), 0);
    }

    // ════════════════════════════════════════════════════════════════
    //  Dispute Path: propose -> dispute -> DVM -> resolved
    // ════════════════════════════════════════════════════════════════

    function test_disputePath_proposerWasRight() public {
        vm.warp(block.timestamp + 1 days + 1);

        uint256 proposerBalanceBefore = bondToken.balanceOf(proposer);

        vm.prank(proposer);
        bytes32 assertionId = adapter.proposeAnswer(questionId, ANSWER_YES);
        assertTrue(adapter.hasPendingProposal(questionId));

        // Dispute fires callback
        oracle.disputeAssertion(assertionId);

        // Pending proposal cleared — new proposals allowed
        assertFalse(adapter.hasPendingProposal(questionId));

        // DVM resolves in favor of proposer (truthful)
        oracle.settleDispute(assertionId, true);

        // Market resolved
        assertTrue(controller.resolveCalled());
        assertTrue(controller.finaliseCalled());

        // Bond returned directly to proposer by UMA
        assertEq(bondToken.balanceOf(proposer), proposerBalanceBefore);
    }

    function test_disputePath_proposerWasWrong() public {
        vm.warp(block.timestamp + 1 days + 1);

        uint256 proposerBalanceBefore = bondToken.balanceOf(proposer);

        vm.prank(proposer);
        bytes32 assertionId = adapter.proposeAnswer(questionId, ANSWER_YES);

        oracle.disputeAssertion(assertionId);

        // DVM resolves against proposer (not truthful)
        oracle.settleDispute(assertionId, false);

        // Market NOT resolved — waiting for new proposal
        assertFalse(controller.resolveCalled());
        assertFalse(controller.finaliseCalled());

        // Bond slashed — proposer lost it
        assertEq(bondToken.balanceOf(proposer), proposerBalanceBefore - DEFAULT_BOND);

        // Can propose again with correct answer
        vm.prank(proposer);
        bytes32 newAssertionId = adapter.proposeAnswer(questionId, ANSWER_NO);
        assertTrue(adapter.hasPendingProposal(questionId));
        assertTrue(newAssertionId != assertionId);
    }

    // ════════════════════════════════════════════════════════════════
    //  Emergency Path: flag -> safety period -> emergency resolve
    // ════════════════════════════════════════════════════════════════

    function test_emergencyResolve() public {
        vm.warp(block.timestamp + 1 days + 1);

        // Admin flags the question
        vm.prank(admin);
        adapter.flag(questionId);

        assertTrue(adapter.isFlagged(questionId));

        // Can't propose while flagged
        vm.prank(proposer);
        vm.expectRevert(FTUmaOracleAdapter.QuestionPausedForResolution.selector);
        adapter.proposeAnswer(questionId, ANSWER_YES);

        // Can't emergency resolve before safety period
        vm.prank(admin);
        vm.expectRevert(FTUmaOracleAdapter.SafetyPeriodNotPassed.selector);
        adapter.emergencyResolve(questionId, ANSWER_YES);

        // Warp past safety period
        vm.warp(block.timestamp + 1 hours + 1);

        // Admin resolves
        vm.prank(admin);
        adapter.emergencyResolve(questionId, ANSWER_YES);

        assertTrue(controller.resolveCalled());
        assertTrue(controller.finaliseCalled());
        assertFalse(adapter.isFlagged(questionId));
    }

    function test_unflag() public {
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(admin);
        adapter.flag(questionId);

        // Unflag before safety period expires
        vm.prank(admin);
        adapter.unflag(questionId);

        assertFalse(adapter.isFlagged(questionId));

        // Can propose again
        vm.prank(proposer);
        adapter.proposeAnswer(questionId, ANSWER_YES);
        assertTrue(adapter.hasPendingProposal(questionId));
    }

    function test_unflag_revertsAfterSafetyPeriod() public {
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(admin);
        adapter.flag(questionId);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(admin);
        vm.expectRevert(FTUmaOracleAdapter.SafetyPeriodAlreadyPassed.selector);
        adapter.unflag(questionId);
    }

    // ════════════════════════════════════════════════════════════════
    //  Flag during pending UMA proposal
    // ════════════════════════════════════════════════════════════════

    function test_flagWhileProposalPending() public {
        vm.warp(block.timestamp + 1 days + 1);

        uint256 proposerBalanceBefore = bondToken.balanceOf(proposer);

        // Propose
        vm.prank(proposer);
        bytes32 assertionId = adapter.proposeAnswer(questionId, ANSWER_YES);

        // Admin flags — UMA callback will skip resolution
        vm.prank(admin);
        adapter.flag(questionId);

        // Settle on UMA — callback should NOT resolve the market (paused)
        vm.warp(block.timestamp + DEFAULT_LIVENESS + 1);
        oracle.settleAssertion(assertionId);

        // Controller NOT called — admin controls this question now
        assertFalse(controller.resolveCalled());

        // Bond returned directly to proposer by UMA (asserter = proposer)
        assertEq(bondToken.balanceOf(proposer), proposerBalanceBefore);
        assertEq(bondToken.balanceOf(address(adapter)), 0);

        // Admin resolves manually
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(admin);
        adapter.emergencyResolve(questionId, ANSWER_NO);

        assertTrue(controller.resolveCalled());
        assertEq(controller.lastResolvedAnswer(), ANSWER_NO);
    }

    // ════════════════════════════════════════════════════════════════
    //  Stale DVM settlement on already-finalised market
    // ════════════════════════════════════════════════════════════════

    function test_staleDvmSettlement_onFinalisedMarket() public {
        vm.warp(block.timestamp + 1 days + 1);

        // Fund a second proposer
        address proposer2 = makeAddr("proposer2");
        bondToken.mint(proposer2, 100_000e18);
        vm.prank(proposer2);
        bondToken.approve(address(adapter), type(uint256).max);

        uint256 proposerBalanceBefore = bondToken.balanceOf(proposer);

        // Proposer A proposes YES
        vm.prank(proposer);
        bytes32 idA = adapter.proposeAnswer(questionId, ANSWER_YES);

        // Dispute A
        oracle.disputeAssertion(idA);

        // Proposer B proposes NO
        vm.prank(proposer2);
        bytes32 idB = adapter.proposeAnswer(questionId, ANSWER_NO);

        // B settles — market finalised with answer=NO
        vm.warp(block.timestamp + DEFAULT_LIVENESS + 1);
        oracle.settleAssertion(idB);
        assertTrue(controller.finaliseCalled());
        assertEq(controller.lastResolvedAnswer(), ANSWER_NO);

        // DVM resolves A as truthful — but market is already finalised
        // callback should skip resolution gracefully (isFinalised check)
        controller.resetTracking();
        oracle.settleDispute(idA, true);

        // Controller NOT called again — market was already finalised
        assertFalse(controller.resolveCalled());

        // Proposer A's bond returned directly by UMA (asserter = proposer)
        assertEq(bondToken.balanceOf(proposer), proposerBalanceBefore);
    }

    // ════════════════════════════════════════════════════════════════
    //  Bug fix: old DVM settlement doesn't wipe new proposal
    // ════════════════════════════════════════════════════════════════

    function test_oldDvmSettlement_doesNotWipeNewProposal() public {
        vm.warp(block.timestamp + 1 days + 1);

        // Propose YES
        vm.prank(proposer);
        bytes32 id1 = adapter.proposeAnswer(questionId, ANSWER_YES);

        // Dispute
        oracle.disputeAssertion(id1);
        assertFalse(adapter.hasPendingProposal(questionId));

        // Re-propose NO while DVM is voting on id1
        vm.prank(proposer);
        bytes32 id2 = adapter.proposeAnswer(questionId, ANSWER_NO);
        assertTrue(adapter.hasPendingProposal(questionId));

        // DVM resolves id1 as truthful — should NOT wipe id2
        oracle.settleDispute(id1, true);

        // New proposal (id2) still pending
        assertTrue(adapter.hasPendingProposal(questionId));
    }

    function test_oldDvmSettlement_false_doesNotWipeNewProposal() public {
        vm.warp(block.timestamp + 1 days + 1);

        // Propose YES
        vm.prank(proposer);
        bytes32 id1 = adapter.proposeAnswer(questionId, ANSWER_YES);

        // Dispute
        oracle.disputeAssertion(id1);

        // Re-propose NO
        vm.prank(proposer);
        bytes32 id2 = adapter.proposeAnswer(questionId, ANSWER_NO);
        assertTrue(adapter.hasPendingProposal(questionId));

        // DVM resolves id1 as NOT truthful
        oracle.settleDispute(id1, false);

        // id2 still pending
        assertTrue(adapter.hasPendingProposal(questionId));

        // id2 settles and resolves the market
        vm.warp(block.timestamp + DEFAULT_LIVENESS + 1);
        oracle.settleAssertion(id2);

        assertTrue(controller.resolveCalled());
        assertEq(controller.lastResolvedAnswer(), ANSWER_NO);
    }

    // ════════════════════════════════════════════════════════════════
    //  Validation: Invalid proposals rejected
    // ════════════════════════════════════════════════════════════════

    function test_revert_proposeBeforeExpiry() public {
        vm.prank(proposer);
        vm.expectRevert(FTUmaOracleAdapter.QuestionNotExpired.selector);
        adapter.proposeAnswer(questionId, ANSWER_YES);
    }

    function test_revert_proposeZeroAnswer() public {
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(proposer);
        vm.expectRevert(FTUmaOracleAdapter.InvalidAnswer.selector);
        adapter.proposeAnswer(questionId, 0);
    }

    function test_revert_proposeAnswerOutOfRange() public {
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(proposer);
        vm.expectRevert(FTUmaOracleAdapter.InvalidAnswer.selector);
        adapter.proposeAnswer(questionId, 4);
    }

    function test_revert_proposeDuplicate() public {
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(proposer);
        adapter.proposeAnswer(questionId, ANSWER_YES);

        vm.prank(proposer);
        vm.expectRevert(FTUmaOracleAdapter.ProposalAlreadyPending.selector);
        adapter.proposeAnswer(questionId, ANSWER_NO);
    }

    function test_revert_proposeAlreadyFinalised() public {
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(proposer);
        bytes32 assertionId = adapter.proposeAnswer(questionId, ANSWER_YES);
        vm.warp(block.timestamp + DEFAULT_LIVENESS + 1);
        oracle.settleAssertion(assertionId);

        vm.prank(proposer);
        vm.expectRevert(FTUmaOracleAdapter.QuestionAlreadyFinalised.selector);
        adapter.proposeAnswer(questionId, ANSWER_NO);
    }

    // ════════════════════════════════════════════════════════════════
    //  Callback Auth: only UMA can call callbacks
    // ════════════════════════════════════════════════════════════════

    function test_revert_callbackFromNonOracle() public {
        vm.prank(user);
        vm.expectRevert(FTUmaOracleAdapter.NotOracle.selector);
        adapter.assertionResolvedCallback(bytes32(uint256(1)), true);
    }

    function test_revert_disputeCallbackFromNonOracle() public {
        vm.prank(user);
        vm.expectRevert(FTUmaOracleAdapter.NotOracle.selector);
        adapter.assertionDisputedCallback(bytes32(uint256(1)));
    }

    // ════════════════════════════════════════════════════════════════
    //  Admin: only owner can call admin functions
    // ════════════════════════════════════════════════════════════════

    function test_revert_flagByNonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        adapter.flag(questionId);
    }

    function test_revert_emergencyResolveByNonOwner() public {
        vm.prank(admin);
        adapter.flag(questionId);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(user);
        vm.expectRevert();
        adapter.emergencyResolve(questionId, ANSWER_YES);
    }

    // ════════════════════════════════════════════════════════════════
    //  Config: bond and liveness settings
    // ════════════════════════════════════════════════════════════════

    function test_setDefaultBond() public {
        vm.prank(admin);
        adapter.setDefaultBond(2000e18);
        assertEq(adapter.defaultBond(), 2000e18);
    }

    function test_setDefaultLiveness() public {
        vm.prank(admin);
        adapter.setDefaultLiveness(14400);
        assertEq(adapter.defaultLiveness(), 14400);
    }

    function test_revert_setZeroBond() public {
        vm.prank(admin);
        vm.expectRevert(FTUmaOracleAdapter.InvalidBond.selector);
        adapter.setDefaultBond(0);
    }

    function test_revert_setZeroLiveness() public {
        vm.prank(admin);
        vm.expectRevert(FTUmaOracleAdapter.InvalidLiveness.selector);
        adapter.setDefaultLiveness(0);
    }

    // ════════════════════════════════════════════════════════════════
    //  Bond: verify bond flows correctly (proposer -> adapter -> UMA -> proposer)
    // ════════════════════════════════════════════════════════════════

    function test_bondFlow() public {
        vm.warp(block.timestamp + 1 days + 1);

        uint256 proposerBefore = bondToken.balanceOf(proposer);
        uint256 oracleBefore = bondToken.balanceOf(address(oracle));

        // Propose — bond goes: proposer -> adapter -> UMA
        vm.prank(proposer);
        bytes32 assertionId = adapter.proposeAnswer(questionId, ANSWER_YES);

        assertEq(bondToken.balanceOf(proposer), proposerBefore - DEFAULT_BOND);
        assertEq(bondToken.balanceOf(address(oracle)), oracleBefore + DEFAULT_BOND);
        assertEq(bondToken.balanceOf(address(adapter)), 0); // adapter doesn't hold bond

        // Settle — bond goes: UMA -> proposer (directly, not via adapter)
        vm.warp(block.timestamp + DEFAULT_LIVENESS + 1);
        oracle.settleAssertion(assertionId);

        assertEq(bondToken.balanceOf(proposer), proposerBefore); // fully returned
        assertEq(bondToken.balanceOf(address(adapter)), 0); // adapter never held it
    }

    // ════════════════════════════════════════════════════════════════
    //  View: ready() function
    // ════════════════════════════════════════════════════════════════

    function test_ready_falseWhenNoPendingProposal() public view {
        assertFalse(adapter.ready(questionId));
    }

    function test_ready_falseWhenPaused() public {
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(proposer);
        adapter.proposeAnswer(questionId, ANSWER_YES);

        vm.prank(admin);
        adapter.pause(questionId);

        assertFalse(adapter.ready(questionId));
    }

    // ════════════════════════════════════════════════════════════════
    //  Multi-outcome: 3 outcomes with bitmask answer
    // ════════════════════════════════════════════════════════════════

    function test_multiOutcome() public {
        bytes32 multiQuestionId = keccak256("Who wins the World Cup?");

        vm.prank(admin);
        controller.createMockQuestion(multiQuestionId, 3, uint128(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(proposer);
        bytes32 assertionId = adapter.proposeAnswer(multiQuestionId, 5);

        vm.warp(block.timestamp + DEFAULT_LIVENESS + 1);
        oracle.settleAssertion(assertionId);

        assertEq(controller.lastResolvedAnswer(), 5);
    }
}
