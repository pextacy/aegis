// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PolicyEngine} from "../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../contracts/TreasuryRegistry.sol";
import {AegisFixture} from "./helpers/AegisFixture.sol";

/// @notice Treasury lifecycle: binding, freezing, and governed amendments.
contract TreasuryRegistryTest is AegisFixture {
    /// @dev A second valid key, so "already bound" is tested against a real
    /// alternative rather than a repeat of the same one.
    bytes constant OTHER_PUBKEY = hex"02B4632D08485FF1DF2DB55B9DAFD23347D1C47A457072A1E87BE26896549A8737";

    // --- binding ----------------------------------------------------------

    function test_bindingStoresDerivedAccount() public view {
        TreasuryRegistry.Treasury memory t = registry.getTreasury(treasuryId);
        assertEq(t.xrplAddress, CLASSIC);
        assertEq(t.xrplAccountId, bytes32(ripemd160(abi.encodePacked(sha256(PUBKEY)))));
    }

    function test_secondBindingReverts() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.AccountAlreadyBound.selector, treasuryId));
        registry.bindXrplAccount(treasuryId, OTHER_PUBKEY, CLASSIC);
    }

    function test_bindingRejectsAddressThatDoesNotMatchTheKey() public {
        vm.prank(admin);
        uint256 tid = registry.createTreasury(policyId);

        vm.expectRevert();
        registry.bindXrplAccount(tid, PUBKEY, "rNotTheDerivedAddressAtAll1234567");
    }

    function test_onlyInstructionSenderMayBind() public {
        vm.prank(admin);
        uint256 tid = registry.createTreasury(policyId);

        vm.expectRevert(TreasuryRegistry.NotInstructionSender.selector);
        vm.prank(outsider);
        registry.bindXrplAccount(tid, PUBKEY, CLASSIC);
    }

    // --- creation ---------------------------------------------------------

    function test_onlyPolicyAdminCreatesTreasury() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.NotPolicyAdmin.selector, policyId, outsider));
        vm.prank(outsider);
        registry.createTreasury(policyId);
    }

    /// @dev A fresh treasury has no sequence at all, and that is the point. XRPL
    /// accounts created since the DeletableAccounts amendment start at the
    /// ledger index they were funded in, so any number this contract invented
    /// would be wrong; zero means "not yet known" and every spending path
    /// refuses while it holds.
    function test_treasuryStartsWithNoKnownSequence() public {
        vm.prank(admin);
        uint256 fresh = registry.createTreasury(policyId);
        assertEq(registry.nextSequenceOf(fresh), 0);
    }

    function test_initialSequenceIsRecordedAfterFunding() public {
        assertEq(registry.nextSequenceOf(treasuryId), START_SEQUENCE);
    }

    function test_initialSequenceNeedsABoundAccount() public {
        vm.prank(admin);
        uint256 fresh = registry.createTreasury(policyId);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.AccountNotBound.selector, fresh));
        vm.prank(admin);
        registry.setInitialSequence(fresh, START_SEQUENCE);
    }

    function test_initialSequenceRejectsZero() public {
        vm.expectRevert(TreasuryRegistry.InitialSequenceRequired.selector);
        vm.prank(admin);
        registry.setInitialSequence(treasuryId, 0);
    }

    function test_initialSequenceIsPolicyAdminOnly() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.NotPolicyAdmin.selector, policyId, outsider));
        vm.prank(outsider);
        registry.setInitialSequence(treasuryId, START_SEQUENCE);
    }

    /// @dev Correctable until XRPL has consumed one. A mistyped starting
    /// sequence produces a payment that never lands, and without this the
    /// treasury would be wedged on a typo with no way back.
    function test_initialSequenceIsCorrectableBeforeXrplConfirmsOne() public {
        vm.prank(admin);
        registry.setInitialSequence(treasuryId, START_SEQUENCE + 10);
        assertEq(registry.nextSequenceOf(treasuryId), START_SEQUENCE + 10);
    }

    function test_initialSequenceIsFixedOnceXrplConfirmsOne() public {
        registry.advanceSequence(treasuryId, START_SEQUENCE);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.SequenceAlreadyConfirmed.selector, treasuryId));
        vm.prank(admin);
        registry.setInitialSequence(treasuryId, START_SEQUENCE + 10);
    }

    function test_initialSequenceRefusedOnAFrozenTreasury() public {
        vm.prank(guardian);
        registry.freeze(treasuryId);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.TreasuryFrozenError.selector, treasuryId));
        vm.prank(admin);
        registry.setInitialSequence(treasuryId, START_SEQUENCE);
    }

    function test_unknownPolicyCannotBackATreasury() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.PolicyNotFound.selector, 999));
        vm.prank(admin);
        registry.createTreasury(999);
    }

    // --- freeze -----------------------------------------------------------

    function test_guardianFreezesAlone() public {
        vm.prank(guardian);
        registry.freeze(treasuryId);
        assertTrue(registry.isFrozen(treasuryId), "one guardian, one transaction, no delay");
    }

    function test_nonGuardianCannotFreeze() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.NotGuardian.selector, treasuryId, approverA));
        vm.prank(approverA);
        registry.freeze(treasuryId);
    }

    function test_doubleFreezeReverts() public {
        vm.startPrank(guardian);
        registry.freeze(treasuryId);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.TreasuryFrozenError.selector, treasuryId));
        registry.freeze(treasuryId);
        vm.stopPrank();
    }

    // --- unfreeze needs the amendment threshold and timelock ---------------

    function test_unfreezeRequiresThresholdAndTimelock() public {
        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.prank(admin);
        uint256 aid = registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.Unfreeze, 0);

        // Too early and unapproved.
        vm.expectRevert();
        registry.executeAmendment(aid);

        vm.prank(approverA);
        registry.approveAmendment(aid);

        // Threshold is two: one approval is not enough even after the delay.
        vm.warp(block.timestamp + AMEND_TIMELOCK);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.InsufficientApprovals.selector, 1, AMEND_APPROVALS));
        registry.executeAmendment(aid);

        vm.prank(approverB);
        registry.approveAmendment(aid);
        registry.executeAmendment(aid);

        assertFalse(registry.isFrozen(treasuryId), "unfreezing is deliberately harder than freezing");
    }

    function test_unfreezeBlockedBeforeTimelockEvenWithEnoughApprovals() public {
        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.prank(admin);
        uint256 aid = registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.Unfreeze, 0);
        vm.prank(approverA);
        registry.approveAmendment(aid);
        vm.prank(approverB);
        registry.approveAmendment(aid);

        uint64 eligibleAt = registry.getAmendment(aid).eligibleAt;
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryRegistry.TimelockNotElapsed.selector, eligibleAt, uint64(block.timestamp))
        );
        registry.executeAmendment(aid);
    }

    function test_amendmentProposerCannotApprove() public {
        // Hoisted: an external call in the argument list would consume the prank.
        uint8 both = policy.ROLE_POLICY_ADMIN() | policy.ROLE_APPROVER();
        vm.prank(admin);
        policy.setRoles(policyId, admin, both);

        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.startPrank(admin);
        uint256 aid = registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.Unfreeze, 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.ProposerCannotApprove.selector, aid));
        registry.approveAmendment(aid);
        vm.stopPrank();
    }

    function test_amendmentDuplicateApprovalRejected() public {
        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.prank(admin);
        uint256 aid = registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.Unfreeze, 0);

        vm.startPrank(approverA);
        registry.approveAmendment(aid);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.AlreadyApproved.selector, aid, approverA));
        registry.approveAmendment(aid);
        vm.stopPrank();
    }

    function test_amendmentCannotExecuteTwice() public {
        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.prank(admin);
        uint256 aid = registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.Unfreeze, 0);
        vm.prank(approverA);
        registry.approveAmendment(aid);
        vm.prank(approverB);
        registry.approveAmendment(aid);
        vm.warp(block.timestamp + AMEND_TIMELOCK);
        registry.executeAmendment(aid);

        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.AmendmentAlreadyExecuted.selector, aid));
        registry.executeAmendment(aid);
    }

    // --- policy amendment -------------------------------------------------

    function test_repointingToANewPolicyIsGoverned() public {
        uint256 newPolicy = _secondPolicy();

        vm.prank(admin);
        uint256 aid = registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.ChangePolicy, newPolicy);

        vm.prank(approverA);
        registry.approveAmendment(aid);
        vm.prank(approverB);
        registry.approveAmendment(aid);
        vm.warp(block.timestamp + AMEND_TIMELOCK);
        registry.executeAmendment(aid);

        assertEq(registry.policyIdOf(treasuryId), newPolicy);
    }

    function test_cannotRepointToTheSamePolicy() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.SamePolicy.selector, policyId));
        vm.prank(admin);
        registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.ChangePolicy, policyId);
    }

    function test_cannotRepointToAnUnknownPolicy() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.PolicyNotFound.selector, 999));
        vm.prank(admin);
        registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.ChangePolicy, 999);
    }

    function test_onlyPolicyAdminProposesAmendments() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.NotPolicyAdmin.selector, policyId, approverA));
        vm.prank(approverA);
        registry.proposeAmendment(treasuryId, TreasuryRegistry.AmendmentKind.ChangePolicy, 1);
    }

    // --- sequence ---------------------------------------------------------

    function test_onlyExecutionVerifierAdvancesSequence() public {
        vm.expectRevert(TreasuryRegistry.NotExecutionVerifier.selector);
        vm.prank(outsider);
        registry.advanceSequence(treasuryId, 1);
    }

    function test_sequenceAdvancesPastTheConfirmedOne() public {
        registry.advanceSequence(treasuryId, START_SEQUENCE);
        assertEq(registry.nextSequenceOf(treasuryId), START_SEQUENCE + 1);
    }

    function test_sequenceCannotGoBackwards() public {
        registry.advanceSequence(treasuryId, START_SEQUENCE + 4);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryRegistry.SequenceMustAdvance.selector, START_SEQUENCE + 5, START_SEQUENCE + 2
            )
        );
        registry.advanceSequence(treasuryId, START_SEQUENCE + 2);
    }

    // --- wiring -----------------------------------------------------------

    function test_instructionSenderIsWiredOnce() public {
        vm.expectRevert(TreasuryRegistry.AlreadyWired.selector);
        registry.setInstructionSender(outsider);
    }

    function test_onlyOwnerWires() public {
        TreasuryRegistry fresh = new TreasuryRegistry(policy);
        vm.expectRevert(TreasuryRegistry.NotOwner.selector);
        vm.prank(outsider);
        fresh.setInstructionSender(outsider);
    }

    function _secondPolicy() private returns (uint256 pid) {
        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](1);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: 500e18, requiredApprovals: 1, timelockSeconds: 0});
        vm.prank(admin);
        pid = policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, false, AMEND_APPROVALS, AMEND_TIMELOCK);
    }
}
