// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PaymentController} from "../contracts/PaymentController.sol";
import {PolicyEngine} from "../contracts/PolicyEngine.sol";
import {AegisFixture} from "./helpers/AegisFixture.sol";

/// @notice The payment state machine and every rule that can refuse a payment.
contract PaymentControllerTest is AegisFixture {
    uint32 constant FLS = 899_990;
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
        controller.dispatch(id, FLS, LLS, FEE);
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

    /// @dev Found by running the real enclave against a real chain: a
    /// right-aligned AccountID passed every on-chain check and was then refused
    /// at signing, after approvals had already been collected. The contract now
    /// refuses it where every other policy violation is refused — at proposal.
    function test_rightAlignedDestinationIsRejectedAtProposal() public {
        bytes32 rightAligned = bytes32(uint256(uint160(0xaEd2aCa19C6F54926F8482648A694E7cb62baA22)));

        vm.expectRevert(abi.encodeWithSelector(PaymentController.DestinationNotLeftAligned.selector, rightAligned));
        vm.prank(proposer);
        controller.propose(treasuryId, rightAligned, 0, 1_000_000);
    }

    function test_leftAlignedDestinationIsAccepted() public {
        bytes32 leftAligned = bytes32(bytes20(hex"AED2ACA19C6F54926F8482648A694E7CB62BAA22"));

        vm.prank(proposer);
        uint256 id = controller.propose(treasuryId, leftAligned, 0, 1_000_000);
        assertEq(controller.getRequest(id).destinationAccountId, leftAligned);
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

    // --- revocation -------------------------------------------------------

    function test_approverCanWithdrawTheirOwnApproval() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 1);
        assertEq(controller.getRequest(id).approvals, 1);
        assertTrue(controller.hasApproved(id, approverA));

        vm.prank(approverA);
        controller.revokeApproval(id);

        assertEq(controller.getRequest(id).approvals, 0);
        assertFalse(controller.hasApproved(id, approverA));
    }

    function test_revocationReturnsAnApprovedRequestToProposed() public {
        // Tier 1 needs two approvals, so this request is fully authorised.
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Approved));

        vm.prank(approverB);
        controller.revokeApproval(id);

        PaymentController.PaymentRequest memory r = controller.getRequest(id);
        assertEq(uint8(r.state), uint8(PaymentController.RequestState.Proposed));
        assertEq(r.approvals, 1);
    }

    /// @dev The property the whole path exists for. A request that had reached
    /// its threshold must not remain dispatchable once an approver withdraws,
    /// even after the timelock has fully elapsed.
    function test_dispatchIsRefusedAfterAnApprovalIsWithdrawn() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        vm.prank(approverB);
        controller.revokeApproval(id);

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.WrongState.selector,
                PaymentController.RequestState.Proposed,
                PaymentController.RequestState.Approved
            )
        );
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);
    }

    function test_revokedApprovalCanBeGivenAgain() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        vm.prank(approverB);
        controller.revokeApproval(id);
        vm.prank(approverB);
        controller.approve(id);

        PaymentController.PaymentRequest memory r = controller.getRequest(id);
        assertEq(uint8(r.state), uint8(PaymentController.RequestState.Approved));
        assertEq(r.approvals, 2);
    }

    /// @dev `eligibleAt` is a proposal-time clock. If revoking restarted it, one
    /// approver could push a payment out indefinitely by approving and
    /// withdrawing, which is a denial of service dressed as caution.
    function test_revocationDoesNotRestartTheTimelock() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        uint64 eligibleAt = controller.getRequest(id).eligibleAt;

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(approverB);
        controller.revokeApproval(id);
        vm.prank(approverB);
        controller.approve(id);

        assertEq(controller.getRequest(id).eligibleAt, eligibleAt);
    }

    function test_cannotRevokeAnApprovalNeverGiven() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 1);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.NotApproved.selector, id, approverB));
        vm.prank(approverB);
        controller.revokeApproval(id);
    }

    function test_cannotRevokeTheSameApprovalTwice() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 1);

        vm.prank(approverA);
        controller.revokeApproval(id);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.NotApproved.selector, id, approverA));
        vm.prank(approverA);
        controller.revokeApproval(id);
    }

    /// @dev One approver must not be able to strike another's approval. That
    /// would be a veto, and no role in the policy grants one.
    function test_oneApproverCannotRevokeAnothers() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 1);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.NotApproved.selector, id, approverC));
        vm.prank(approverC);
        controller.revokeApproval(id);

        assertEq(controller.getRequest(id).approvals, 1);
    }

    function test_cannotRevokeAfterDispatch() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.WrongState.selector,
                PaymentController.RequestState.Dispatched,
                PaymentController.RequestState.Proposed
            )
        );
        vm.prank(approverA);
        controller.revokeApproval(id);
    }

    function test_cannotRevokeAfterCancellation() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 1);
        vm.prank(proposer);
        controller.cancel(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.WrongState.selector,
                PaymentController.RequestState.Cancelled,
                PaymentController.RequestState.Proposed
            )
        );
        vm.prank(approverA);
        controller.revokeApproval(id);
    }

    /// @dev An address whose approver role was taken away still has its approval
    /// counted toward the threshold. If the role were required to withdraw it,
    /// that approval would be stranded and a removed approver's authority would
    /// carry the payment.
    function test_revocationSurvivesLosingTheApproverRole() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        vm.prank(admin);
        policy.setRoles(policyId, approverB, 0);

        vm.prank(approverB);
        controller.revokeApproval(id);

        PaymentController.PaymentRequest memory r = controller.getRequest(id);
        assertEq(uint8(r.state), uint8(PaymentController.RequestState.Proposed));
        assertEq(r.approvals, 1);
    }

    /// @dev Every refusal-to-spend path stays open on a frozen treasury. A freeze
    /// that also preserved approvals would protect the payment it interrupted.
    function test_revocationIsAllowedWhileTheTreasuryIsFrozen() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.prank(approverB);
        controller.revokeApproval(id);

        assertEq(controller.getRequest(id).approvals, 1);
    }

    function test_revocationEmitsTheCountsItLeavesBehind() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        vm.expectEmit(true, true, false, true);
        emit PaymentController.PaymentApprovalRevoked(id, approverB, 1, 2);
        vm.prank(approverB);
        controller.revokeApproval(id);
    }

    function test_revokingAnUnknownRequestReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PaymentController.RequestNotFound.selector, uint256(999)));
        vm.prank(approverA);
        controller.revokeApproval(999);
    }

    // --- approver authority is re-checked at dispatch ----------------------

    /// @dev The reason the approver set is stored rather than counted. A policy
    /// admin who discovers an approver is compromised revokes their role — and
    /// before this check, every request that approver had already signed off
    /// still carried their vote to dispatch.
    function test_dispatchRefusesAnApprovalWhoseRoleWasRevoked() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Approved));

        vm.prank(admin);
        policy.setRoles(policyId, approverB, 0);

        vm.warp(block.timestamp + 2 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));

        vm.expectRevert(abi.encodeWithSelector(PaymentController.InsufficientApprovals.selector, 1, 2));
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);
    }

    function test_dispatchProceedsWhileEveryApproverStillHoldsTheRole() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        vm.warp(block.timestamp + 2 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));

        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Dispatched));
    }

    /// @dev A revoked role only matters if it takes the request below the
    /// threshold that applies at dispatch, and that threshold is re-resolved
    /// from the live price. Here XRP falls far enough to move the payment down
    /// into tier 0, which needs one approval — so the one surviving approval is
    /// enough and the payment goes out. The check is against current authority
    /// versus the current rule, not a blanket strike against the request.
    function test_revokedRoleDoesNotBlockADispatchThatStillMeetsTheThreshold() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        vm.prank(admin);
        policy.setRoles(policyId, approverB, 0);

        vm.warp(block.timestamp + 2 hours);
        // 5,000 USD at proposal becomes 500 USD, which is tier 0 and needs one.
        setPrice(XRP_PRICE / 10, uint64(block.timestamp));
        assertEq(controller.validApprovals(id), 1);

        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Dispatched));
    }

    function test_validApprovalsFallsBelowTheRawCountWhenARoleIsRevoked() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        assertEq(controller.validApprovals(id), 2);

        vm.prank(admin);
        policy.setRoles(policyId, approverB, 0);

        assertEq(controller.getRequest(id).approvals, 2, "the raw count is unchanged");
        assertEq(controller.validApprovals(id), 1, "but only one still carries authority");
    }

    /// @dev Revoking a role is not permanent. Restoring it restores the payment,
    /// because the check reads current authority rather than recording a strike.
    function test_restoringTheRoleRestoresTheDispatch() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        // Read before the pranks, or the first one is spent on this call rather
        // than on setRoles.
        uint8 approverRole = policy.ROLE_APPROVER();

        vm.prank(admin);
        policy.setRoles(policyId, approverB, 0);
        vm.prank(admin);
        policy.setRoles(policyId, approverB, approverRole);

        vm.warp(block.timestamp + 2 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));

        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Dispatched));
    }

    function test_approverSetTracksApprovalsAndWithdrawals() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        address[] memory both = controller.approversOf(id);
        assertEq(both.length, 2);
        assertEq(both[0], approverA);
        assertEq(both[1], approverB);

        vm.prank(approverA);
        controller.revokeApproval(id);

        address[] memory left = controller.approversOf(id);
        assertEq(left.length, 1);
        assertEq(left[0], approverB, "the last entry fills the gap");
    }

    function test_approverSetIsEmptyBeforeAnyApproval() public {
        vm.prank(proposer);
        uint256 id = controller.propose(treasuryId, DEST, 0, dropsForUsd(5_000e18));
        assertEq(controller.approversOf(id).length, 0);
        assertEq(controller.validApprovals(id), 0);
    }

    /// @dev Withdrawing and approving again must not leave a duplicate behind,
    /// or one address would be counted twice toward the threshold.
    function test_reApprovingDoesNotDuplicateTheApprover() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);

        vm.prank(approverA);
        controller.revokeApproval(id);
        vm.prank(approverA);
        controller.approve(id);

        assertEq(controller.approversOf(id).length, 2);
        assertEq(controller.validApprovals(id), 2);
        assertEq(controller.getRequest(id).approvals, 2);
    }

    function test_validApprovalsRejectsAnUnknownRequest() public {
        vm.expectRevert(abi.encodeWithSelector(PaymentController.RequestNotFound.selector, uint256(999)));
        controller.validApprovals(999);
    }

    // --- dispatch ---------------------------------------------------------

    function test_dispatchBeforeTimelockReverts() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        PaymentController.PaymentRequest memory r = controller.getRequest(id);

        vm.expectRevert(
            abi.encodeWithSelector(PaymentController.TimelockNotElapsed.selector, r.eligibleAt, uint64(block.timestamp))
        );
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);
    }

    function test_dispatchAfterTimelockSucceeds() public {
        uint256 id = proposeAndApprove(dropsForUsd(5_000e18), 2);
        vm.warp(block.timestamp + 1 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));

        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Dispatched));
        assertEq(sender.calls(), 1, "instruction reached the sender");
    }

    function test_dispatchPassesTheOnChainDigest() public {
        uint64 drops = dropsForUsd(500e18);
        uint256 id = proposeAndApprove(drops, 1);

        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

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
        controller.dispatch(id, FLS, 0, FEE);
    }

    function test_dispatchRequiresFee() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.expectRevert(PaymentController.ZeroFee.selector);
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, 0);
    }

    function test_dispatchRequiresFirstLedgerSequence() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.expectRevert(PaymentController.FirstLedgerSequenceRequired.selector);
        vm.prank(proposer);
        controller.dispatch(id, 0, LLS, FEE);
    }

    function test_dispatchRejectsInvertedLedgerRange() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.expectRevert(abi.encodeWithSelector(PaymentController.LedgerRangeInverted.selector, LLS + 1, LLS));
        vm.prank(proposer);
        controller.dispatch(id, LLS + 1, LLS, FEE);
    }

    function test_dispatchAcceptsSingleLedgerRange() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, LLS, LLS, FEE);
        assertEq(controller.getRequest(id).firstLedgerSequence, LLS);
    }

    function test_dispatchStoresLedgerRange() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);
        PaymentController.PaymentRequest memory r = controller.getRequest(id);
        assertEq(r.firstLedgerSequence, FLS, "lower bound for the non-existence proof");
        assertEq(r.lastLedgerSequence, LLS);
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
        controller.dispatch(id, FLS, LLS, FEE);
    }

    function test_dispatchUsesTreasurySequence() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);
        assertEq(
            controller.getRequest(id).sequence, START_SEQUENCE, "the first payment uses the account's real sequence"
        );
    }

    /// @dev The bug this guards: a treasury whose XRPL starting sequence has not
    /// been recorded would otherwise sign against a guessed one, and a
    /// transaction XRPL rejects can never be proven, so nothing could ever
    /// advance it. Refusing at propose keeps approvals off a dead request.
    function test_proposeRefusedBeforeTheStartingSequenceIsKnown() public {
        vm.prank(admin);
        uint256 fresh = registry.createTreasury(policyId);
        registry.bindXrplAccount(fresh, PUBKEY, CLASSIC);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.SequenceNotInitialised.selector, fresh));
        vm.prank(proposer);
        controller.propose(fresh, DEST, 0, dropsForUsd(100e18));
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
        controller.dispatch(id, FLS, LLS, FEE);
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
        controller.dispatch(id, FLS, LLS, FEE);
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
        controller.dispatch(id, FLS, LLS, FEE);
    }

    // --- rolling window ---------------------------------------------------

    function test_windowBlocksProposalOnceExhausted() public {
        // Commit 30,000 of the 50,000 window.
        uint256 first = proposeAndApprove(dropsForUsd(30_000e18), 3);
        vm.warp(block.timestamp + 24 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));
        vm.prank(proposer);
        controller.dispatch(first, FLS, LLS, FEE);

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
        controller.dispatch(a, FLS, LLS, FEE);

        // 30,000 is committed; 25,000 no longer fits under the 50,000 ceiling.
        vm.expectRevert(
            abi.encodeWithSelector(PaymentController.RollingWindowExceeded.selector, 30_000e18, 25_000e18, WINDOW_CAP)
        );
        vm.prank(proposer);
        controller.dispatch(b, FLS, LLS, FEE);
    }

    function test_windowReleasesAfterTheWindowPasses() public {
        uint256 id = proposeAndApprove(dropsForUsd(30_000e18), 3);
        vm.warp(block.timestamp + 24 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);
        assertEq(controller.committedUsd(treasuryId), 30_000e18);

        vm.warp(block.timestamp + WINDOW_SECONDS + 1);
        assertEq(controller.committedUsd(treasuryId), 0, "spend ages out of the window");
    }

    function test_failedPaymentReleasesItsWindowSpend() public {
        uint256 id = proposeAndApprove(dropsForUsd(30_000e18), 3);
        vm.warp(block.timestamp + 24 hours);
        setPrice(XRP_PRICE, uint64(block.timestamp));
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);
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
        controller.dispatch(id, FLS, LLS, FEE);
    }

    // --- authority --------------------------------------------------------

    function test_onlyInstructionSenderRecordsSignature() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

        vm.expectRevert(PaymentController.NotInstructionSender.selector);
        vm.prank(outsider);
        controller.recordSignature(id, hex"1234", bytes32(uint256(1)));
    }

    function test_onlyExecutionVerifierMarksSettled() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

        vm.expectRevert(PaymentController.NotExecutionVerifier.selector);
        vm.prank(outsider);
        controller.markSettled(id);
    }

    function test_settlementRequiresASignatureFirst() public {
        uint256 id = proposeAndApprove(dropsForUsd(100e18), 1);
        vm.prank(proposer);
        controller.dispatch(id, FLS, LLS, FEE);

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
        controller.dispatch(id, FLS, LLS, FEE);
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

        // Same key as the fixture's treasury: nothing here turns on which XRPL
        // account it is, only that one is bound so a starting sequence exists.
        registry.bindXrplAccount(tid, PUBKEY, CLASSIC);
        vm.prank(admin);
        registry.setInitialSequence(tid, START_SEQUENCE);
    }
}
