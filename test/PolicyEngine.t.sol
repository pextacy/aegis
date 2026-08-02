// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PolicyEngine} from "../contracts/PolicyEngine.sol";
import {AegisFixture} from "./helpers/AegisFixture.sol";

/// @notice Tier resolution, allowlist semantics, roles, and policy validation.
contract PolicyEngineTest is AegisFixture {
    // --- tier resolution at every boundary -------------------------------

    function test_tierResolvesAtExactCeiling() public view {
        assertEq(policy.resolveTier(policyId, TIER0_CAP).requiredApprovals, 1, "at tier0 ceiling");
        assertEq(policy.resolveTier(policyId, TIER1_CAP).requiredApprovals, 2, "at tier1 ceiling");
        assertEq(policy.resolveTier(policyId, TIER2_CAP).requiredApprovals, 3, "at tier2 ceiling");
    }

    function test_tierResolvesJustBelowCeiling() public view {
        assertEq(policy.resolveTier(policyId, TIER0_CAP - 1).requiredApprovals, 1);
        assertEq(policy.resolveTier(policyId, TIER1_CAP - 1).requiredApprovals, 2);
        assertEq(policy.resolveTier(policyId, TIER2_CAP - 1).requiredApprovals, 3);
    }

    function test_tierResolvesJustAboveCeiling() public view {
        assertEq(policy.resolveTier(policyId, TIER0_CAP + 1).requiredApprovals, 2, "just above tier0 is tier1");
        assertEq(policy.resolveTier(policyId, TIER1_CAP + 1).requiredApprovals, 3, "just above tier1 is tier2");
    }

    function test_tierResolutionCarriesTimelock() public view {
        assertEq(policy.resolveTier(policyId, TIER0_CAP).timelockSeconds, 0);
        assertEq(policy.resolveTier(policyId, TIER1_CAP).timelockSeconds, 1 hours);
        assertEq(policy.resolveTier(policyId, TIER2_CAP).timelockSeconds, 24 hours);
    }

    function test_aboveHighestCeilingReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.AmountExceedsPolicyCap.selector, TIER2_CAP + 1, TIER2_CAP));
        policy.resolveTier(policyId, TIER2_CAP + 1);
    }

    function test_policyCapIsHighestTier() public view {
        assertEq(policy.policyCap(policyId), TIER2_CAP);
    }

    // --- allowlist --------------------------------------------------------

    function test_allowlistOffPermitsAnything() public view {
        assertTrue(policy.isDestinationAllowed(policyId, DEST, 0));
        assertTrue(policy.isDestinationAllowed(policyId, DEST_OTHER, 12345));
    }

    function test_allowlistOnBlocksUnlisted() public {
        uint256 pid = _enforcedPolicy();
        assertFalse(policy.isDestinationAllowed(pid, DEST, 0), "nothing is allowed by default");
    }

    function test_allowlistExactTagMatch() public {
        uint256 pid = _enforcedPolicy();
        vm.prank(admin);
        policy.setAllowlist(pid, DEST, 77, true);

        assertTrue(policy.isDestinationAllowed(pid, DEST, 77), "listed tag allowed");
        assertFalse(policy.isDestinationAllowed(pid, DEST, 78), "other tag not allowed");
        assertFalse(policy.isDestinationAllowed(pid, DEST_OTHER, 77), "other account not allowed");
    }

    function test_tagZeroMeansAnyTag() public {
        uint256 pid = _enforcedPolicy();
        vm.prank(admin);
        policy.setAllowlist(pid, DEST, 0, true);

        assertTrue(policy.isDestinationAllowed(pid, DEST, 0), "no tag");
        assertTrue(policy.isDestinationAllowed(pid, DEST, 1), "arbitrary tag");
        assertTrue(policy.isDestinationAllowed(pid, DEST, type(uint32).max), "max tag");
        assertFalse(policy.isDestinationAllowed(pid, DEST_OTHER, 1), "does not leak to other accounts");
    }

    function test_allowlistCanBeRevoked() public {
        uint256 pid = _enforcedPolicy();
        vm.startPrank(admin);
        policy.setAllowlist(pid, DEST, 0, true);
        policy.setAllowlist(pid, DEST, 0, false);
        vm.stopPrank();
        assertFalse(policy.isDestinationAllowed(pid, DEST, 5));
    }

    function test_onlyPolicyAdminSetsAllowlist() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.NotPolicyAdmin.selector, policyId, outsider));
        vm.prank(outsider);
        policy.setAllowlist(policyId, DEST, 0, true);
    }

    // --- roles ------------------------------------------------------------

    function test_creatorIsPolicyAdminOnly() public view {
        assertTrue(policy.hasRole(policyId, admin, policy.ROLE_POLICY_ADMIN()));
        assertFalse(policy.hasRole(policyId, admin, policy.ROLE_PROPOSER()));
    }

    function test_rolesAreWrittenAsAWholeMask() public {
        uint8 mask = policy.ROLE_PROPOSER() | policy.ROLE_APPROVER();
        vm.prank(admin);
        policy.setRoles(policyId, outsider, mask);

        assertEq(policy.rolesOf(policyId, outsider), mask);
        assertTrue(policy.hasRole(policyId, outsider, policy.ROLE_PROPOSER()));
        assertTrue(policy.hasRole(policyId, outsider, policy.ROLE_APPROVER()));
        assertFalse(policy.hasRole(policyId, outsider, policy.ROLE_GUARDIAN()));
    }

    function test_onlyPolicyAdminSetsRoles() public {
        // Read the constant first: an external call inside the argument list
        // would be the one expectRevert catches.
        uint8 all = policy.ROLE_ALL();
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.NotPolicyAdmin.selector, policyId, outsider));
        vm.prank(outsider);
        policy.setRoles(policyId, outsider, all);
    }

    function test_rolesAreScopedPerPolicy() public {
        uint256 pid = _enforcedPolicy();
        assertTrue(policy.hasRole(policyId, proposer, policy.ROLE_PROPOSER()));
        assertFalse(policy.hasRole(pid, proposer, policy.ROLE_PROPOSER()), "roles do not cross policies");
    }

    // --- creation validation ---------------------------------------------

    function test_rejectsEmptyTiers() public {
        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](0);
        vm.expectRevert(PolicyEngine.NoTiers.selector);
        policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, false, 1, 0);
    }

    function test_rejectsUnsortedTiers() public {
        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](2);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: 100e18, requiredApprovals: 1, timelockSeconds: 0});
        tiers[1] = PolicyEngine.Tier({maxAmountUsd: 50e18, requiredApprovals: 2, timelockSeconds: 0});
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.TiersNotAscending.selector, 1));
        policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, false, 1, 0);
    }

    function test_rejectsDuplicateCeilings() public {
        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](2);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: 100e18, requiredApprovals: 1, timelockSeconds: 0});
        tiers[1] = PolicyEngine.Tier({maxAmountUsd: 100e18, requiredApprovals: 2, timelockSeconds: 0});
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.TiersNotAscending.selector, 1));
        policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, false, 1, 0);
    }

    function test_rejectsTierWithoutApprovals() public {
        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](1);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: 100e18, requiredApprovals: 0, timelockSeconds: 0});
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.TierNeedsApprovals.selector, 0));
        policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, false, 1, 0);
    }

    function test_rejectsZeroWindow() public {
        PolicyEngine.Tier[] memory tiers = _oneTier();
        vm.expectRevert(PolicyEngine.RollingWindowRequired.selector);
        policy.createPolicy(tiers, 0, WINDOW_SECONDS, false, 1, 0);
    }

    function test_rejectsZeroWindowSeconds() public {
        PolicyEngine.Tier[] memory tiers = _oneTier();
        vm.expectRevert(PolicyEngine.WindowSecondsRequired.selector);
        policy.createPolicy(tiers, WINDOW_CAP, 0, false, 1, 0);
    }

    function test_rejectsZeroAmendApprovals() public {
        PolicyEngine.Tier[] memory tiers = _oneTier();
        vm.expectRevert(PolicyEngine.AmendApprovalsRequired.selector);
        policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, false, 0, 0);
    }

    function test_unknownPolicyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyEngine.PolicyNotFound.selector, 999));
        policy.getPolicy(999);
    }

    function _oneTier() private pure returns (PolicyEngine.Tier[] memory tiers) {
        tiers = new PolicyEngine.Tier[](1);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: 100e18, requiredApprovals: 1, timelockSeconds: 0});
    }

    function _enforcedPolicy() private returns (uint256 pid) {
        PolicyEngine.Tier[] memory tiers = _oneTier();
        vm.prank(admin);
        pid = policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, true, AMEND_APPROVALS, AMEND_TIMELOCK);
    }
}
