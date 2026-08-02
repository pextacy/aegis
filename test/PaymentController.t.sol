// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PaymentController} from "../contracts/PaymentController.sol";
import {PolicyEngine} from "../contracts/PolicyEngine.sol";
import {AegisFixture} from "./helpers/AegisFixture.sol";

/// @notice The payment state machine and every rule that can refuse a payment.
contract PaymentControllerTest is AegisFixture {
    uint32 constant LLS = 900_000;
    uint64 constant FEE = 12;

    // --- pricing ----------------------------------------------------------

    function test_dropsConvertToUsd() public {
        // 1 XRP at $0.50 is 0.5e18 USD.
        assertEq(controller.quoteUsd(1_000_000), 0.5e18);
        assertEq(controller.quoteUsd(2_000_000), 1e18);
    }

    function test_stalePriceBlocksProposal() public {
        setPrice(XRP_PRICE, uint64(block.timestamp - 181));
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.StalePrice.selector, uint64(block.timestamp - 181), uint64(block.timestamp)
            )
        );
        vm.prank(proposer);
        controller.propose(treasuryId, DEST, 0, dropsForUsd(100e18));
    }

    function test_priceExactlyAtAgeLimitIsAccepted() public {
        setPrice(XRP_PRICE, uint64(block.timestamp - 180));
        vm.prank(proposer);
        uint256 id = controller.propose(treasuryId, DEST, 0, dropsForUsd(100e18));
        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Proposed));
    }

    function test_stalePriceBlocksDispatch() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        // Valid at proposal, stale by the time it is dispatched.
        setPrice(XRP_PRICE, uint64(block.timestamp - 200));
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.StalePrice.selector, uint64(block.timestamp - 200), uint64(block.timestamp)
            )
        );
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
    }

    // --- proposal ---------------------------------------------------------

    function test_proposalResolvesTierAndTimelock() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 0);
        PaymentController.PaymentRequest memory r = controller.getRequest(id);
        assertEq(r.requiredApprovals, 2, "5,000 USD sits in tier 1");
        assertEq(r.eligibleAt, uint64(block.timestamp) + 1 hours);
    }

    function test_aboveCapCannotBeProposedAtAll() public {
        uint64 drops = dropsForUsd(TIER2_CAP + 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(PolicyEngine.AmountExceedsPolicyCap.selector, TIER2_CAP + 1e18, TIER2_CAP)
        );
        vm.prank(proposer);
        controller.propose(treasuryId, DEST, 0, drops);
    }

    function test_zeroAmountRejected() public {
        vm.expectRevert(PaymentController.ZeroAmount.selector);
        vm.prank(proposer);
        controller.propose(treasuryId, DEST, 0, 0);
    }

    function test_zeroDestinationRejected() public {
        vm.expectRevert(PaymentController.ZeroDestination.selector);
        vm.prank(proposer);
        controller.propose(treasuryId, bytes32(0), 0, 1_000_000);
    }

    function test_onlyProposerRoleMayPropose() public {
        vm.expectRevert(abi.encodeWithSelector(PaymentController.NotProposer.selector, policyId, outsider));
        vm.prank(outsider);
        controller.propose(treasuryId, DEST, 0, 1_000_000);
    }

    // --- approval ---------------------------------------------------------

    function test_proposerCannotApproveOwnRequest() public {
        vm.prank(proposer);
        uint256 id = controller.propose(treasuryId, DEST, 0, dropsForUsd(100e18));

        // Give the proposer the approver role too, so the refusal below is
        // about who proposed the request rather than about a missing role.
        uint8 both = policy.ROLE_PROPOSER() | policy.ROLE_APPROVER();
        vm.prank(admin);
        policy.setRoles(policyId, proposer, both);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.ProposerCannotApprove.selector, id));
        vm.prank(proposer);
        controller.approve(id);
    }

    function test_sameAddressCannotApproveTwice() public {
        vm.prank(proposer);
        uint256 id = controller.propose(treasuryId, DEST, 0, dropsForUsd(5_000e18));

        vm.prank(approverA);
        controller.approve(id);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.AlreadyApproved.selector, id, approverA));
        vm.prank(approverA);
        controller.approve(id);
    }

    function test_thresholdMovesRequestToApproved() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 1);
        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Proposed));

        vm.prank(approverB);
        controller.approve(id);
        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Approved));
    }

    function test_onlyApproverRoleMayApprove() public {
        vm.prank(proposer);
        uint256 id = controller.propose(treasuryId, DEST, 0, dropsForUsd(100e18));
        vm.expectRevert(abi.encodeWithSelector(PaymentController.NotApprover.selector, policyId, outsider));
        vm.prank(outsider);
        controller.approve(id);
    }

    // --- dispatch ---------------------------------------------------------

    function test_dispatchBeforeTimelockReverts() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        PaymentController.PaymentRequest memory r = controller.getRequest(id);

        vm.expectRevert(
            abi.encodeWithSelector(PaymentController.TimelockNotElapsed.selector, r.eligibleAt, uint64(block.timestamp))
        );
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
    }

    function test_dispatchAfterTimelockSucceeds() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        vm.warp(block.timestamp + 1 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));

        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Dispatched));
        assertEq(sender.calls(), 1, "instruction reached the sender");
    }

    function test_dispatchPassesTheOnChainDigest() public {
        uint64 drops = dropsForUsd(500e18);
        uint256 id = proposeAndApprove(drops, 1);

        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);

        PaymentController.PaymentRequest memory r = controller.getRequest(id);
        bytes32 expected = controller.policyDigest(id, treasuryId, DEST, 0, drops, r.sequence, LLS, FEE);
        assertEq(r.policyDigest, expected, "stored digest");

        (,,,,,,,, bytes32 sentDigest) = sender.last();
        assertEq(sentDigest, expected, "digest the TEE will re-check");
    }

    function test_dispatchRequiresLastLedgerSequence() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.expectRevert(PaymentController.LastLedgerSequenceRequired.selector);
        vm.prank(proposer);
        controller.dispatch(id, 0, FEE);
    }

    function test_dispatchRequiresFee() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.expectRevert(PaymentController.ZeroFee.selector);
        vm.prank(proposer);
        controller.dispatch(id, LLS, 0);
    }

    function test_dispatchRequiresApprovedState() public {
        vm.prank(proposer);
        uint256 id = controller.propose(treasuryId, DEST, 0, dropsForUsd(5_000e18));
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.WrongState.selector,
                PaymentController.RequestState.Proposed,
                PaymentController.RequestState.Approved
            )
        );
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
    }

    function test_dispatchUsesTreasurySequence() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
        assertEq(controller.getRequest(id).sequence, 1, "first payment uses sequence 1");
    }

    // --- the price moving between proposal and dispatch -------------------

    function test_priceRiseCanPushARequestIntoAHigherTier() public {
        // 1,900 USD at proposal sits in tier 1 and collects its two approvals.
        uint64 drops = dropsForUsd(1_900e18);
        uint256 id = proposeAndApprove(drops, 2);
        vm.warp(block.timestamp + 1 hours);

        // XRP doubles. The same drops are now worth 3,800 USD — still tier 1.
        setPrice(XRP_PRICE * 2, uint64(block.timestamp));
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Dispatched));
    }

    function test_priceRiseIntoAHigherTierNeedsMoreApprovals() public {
        // 6,000 USD at proposal: tier 1, two approvals, one hour.
        uint64 drops = dropsForUsd(6_000e18);
        uint256 id = proposeAndApprove(drops, 2);
        vm.warp(block.timestamp + 1 hours);

        // XRP doubles: the payment is now 12,000 USD, which is tier 2 and needs
        // three approvals. The two it collected are no longer enough.
        setPrice(XRP_PRICE * 2, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(PaymentController.InsufficientApprovals.selector, 2, 3));
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
    }

    function test_priceRiseAboveCapBlocksDispatch() public {
        // 40,000 USD fits both the top tier and the rolling window at proposal.
        uint64 drops = dropsForUsd(40_000e18);
        uint256 id = proposeAndApprove(drops, 3);
        vm.warp(block.timestamp + 24 hours);

        // XRP triples: the same drops are now 120,000 USD, above the hard cap.
        // A payment that can no longer be expressed by the policy is refused,
        // not grandfathered on the amount it was worth yesterday.
        setPrice(XRP_PRICE * 3, uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.AmountExceedsPolicyCap.selector, 120_000e18, TIER2_CAP));
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
    }

    // --- rolling window ---------------------------------------------------

    function test_windowBlocksProposalOnceExhausted() public {
        // Commit 30,000 of the 50,000 window.
        uint256 first = proposeAndApprove(dropsForUsd(30_000e18), 3);
        vm.warp(block.timestamp + 24 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));
        vm.prank(proposer);
        controller.dispatch(first, LLS, FEE);

        assertEq(controller.committedUsd(treasuryId), 30_000e18);

        vm.expectRevert(
            abi.encodeWithSelector(PaymentController.RollingWindowExceeded.selector, 30_000e18, 25_000e18, WINDOW_CAP)
        );
        vm.prank(proposer);
        controller.propose(treasuryId, DEST, 0, dropsForUsd(25_000e18));
    }

    /// @dev The criterion that matters most: a request that passed every check
    /// at proposal is refused at dispatch because another payment consumed the
    /// shared window in between.
    function test_windowExhaustionBlocksADispatchThatPassedAtProposal() public {
        uint64 bigDrops = dropsForUsd(30_000e18);
        uint64 secondDrops = dropsForUsd(25_000e18);

        // Both are proposed while the window is still empty, so both pass.
        vm.prank(proposer);
        uint256 a = controller.propose(treasuryId, DEST, 0, bigDrops);
        vm.prank(proposer);
        uint256 b = controller.propose(treasuryId, DEST, 0, secondDrops);

        for (uint256 i = 0; i < 3; ++i) {
            address[3] memory pool = [approverA, approverB, approverC];
            vm.prank(pool[i]);
            controller.approve(a);
            vm.prank(pool[i]);
            controller.approve(b);
        }

        vm.warp(block.timestamp + 24 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));

        vm.prank(proposer);
        controller.dispatch(a, LLS, FEE);

        // 30,000 is committed; 25,000 no longer fits under the 50,000 ceiling.
        vm.expectRevert(
            abi.encodeWithSelector(PaymentController.RollingWindowExceeded.selector, 30_000e18, 25_000e18, WINDOW_CAP)
        );
        vm.prank(proposer);
        controller.dispatch(b, LLS, FEE);
    }

    function test_windowReleasesAfterTheWindowPasses() public {
        uint256 id = proposeAndApprove(dropsForUsd(30_000e18), 3);
        vm.warp(block.timestamp + 24 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
        assertEq(controller.committedUsd(treasuryId), 30_000e18);

        vm.warp(block.timestamp + WINDOW_SECONDS + 1);
        assertEq(controller.committedUsd(treasuryId), 0, "spend ages out of the window");
    }

    function test_failedPaymentReleasesItsWindowSpend() public {
        uint256 id = proposeAndApprove(dropsForUsd(30_000e18), 3);
        vm.warp(block.timestamp + 24 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
        assertEq(controller.committedUsd(treasuryId), 30_000e18);

        // The fixture wires this test contract as the execution verifier.
        controller.markFailed(id, "nonexistence-proven");

        assertEq(controller.committedUsd(treasuryId), 0, "a payment that never happened frees its budget");
        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Failed));
    }

    // --- allowlist --------------------------------------------------------

    function test_nonAllowlistedDestinationIsRefused() public {
        (uint256 pid, uint256 tid) = _enforcedTreasury();
        vm.prank(admin);
        policy.setAllowlist(pid, DEST, 0, true);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.DestinationNotAllowed.selector, DEST_OTHER, 0));
        vm.prank(proposer);
        controller.propose(tid, DEST_OTHER, 0, dropsForUsd(100e18));
    }

    function test_allowlistedDestinationWithAnyTagIsAccepted() public {
        (uint256 pid, uint256 tid) = _enforcedTreasury();
        vm.prank(admin);
        policy.setAllowlist(pid, DEST, 0, true);

        vm.prank(proposer);
        uint256 id = controller.propose(tid, DEST, 424_242, dropsForUsd(100e18));
        assertEq(controller.getRequest(id).destinationTag, 424_242);
    }

    // --- freeze -----------------------------------------------------------

    function test_frozenTreasuryRejectsPropose() public {
        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.TreasuryIsFrozen.selector, treasuryId));
        vm.prank(proposer);
        controller.propose(treasuryId, DEST, 0, dropsForUsd(100e18));
    }

    function test_frozenTreasuryRejectsApprove() public {
        vm.prank(proposer);
        uint256 id = controller.propose(treasuryId, DEST, 0, dropsForUsd(5_000e18));

        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.TreasuryIsFrozen.selector, treasuryId));
        vm.prank(approverA);
        controller.approve(id);
    }

    function test_frozenTreasuryRejectsDispatch() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);

        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.TreasuryIsFrozen.selector, treasuryId));
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
    }

    // --- authority --------------------------------------------------------

    function test_onlyInstructionSenderRecordsSignature() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);

        vm.expectRevert(PaymentController.NotInstructionSender.selector);
        vm.prank(outsider);
        controller.recordSignature(id, hex"1234", bytes32(uint256(1)));
    }

    function test_onlyExecutionVerifierMarksSettled() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);

        vm.expectRevert(PaymentController.NotExecutionVerifier.selector);
        vm.prank(outsider);
        controller.markSettled(id);
    }

    function test_settlementRequiresASignatureFirst() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);

        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.WrongState.selector,
                PaymentController.RequestState.Dispatched,
                PaymentController.RequestState.Signed
            )
        );
        controller.markSettled(id);
    }

    function test_cancelledRequestCannotDispatch() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.cancel(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.WrongState.selector,
                PaymentController.RequestState.Cancelled,
                PaymentController.RequestState.Approved
            )
        );
        vm.prank(proposer);
        controller.dispatch(id, LLS, FEE);
    }

    function _enforcedTreasury() private returns (uint256 pid, uint256 tid) {
        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](1);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: TIER2_CAP, requiredApprovals: 1, timelockSeconds: 0});
        vm.startPrank(admin);
        pid = policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, true, AMEND_APPROVALS, AMEND_TIMELOCK);
        policy.setRoles(pid, proposer, policy.ROLE_PROPOSER());
        policy.setRoles(pid, approverA, policy.ROLE_APPROVER());
        tid = registry.createTreasury(pid);
        vm.stopPrank();
    }
}
