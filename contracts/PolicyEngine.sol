// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title PolicyEngine
/// @author Aegis
/// @notice Immutable spending policies for XRPL treasuries: amount tiers, a
/// rolling spend ceiling, a destination allowlist, and per-policy roles.
/// @dev A policy's rules are fixed at creation. Changing a rule means creating a
/// new policy and repointing the treasury, which TreasuryRegistry gates behind
/// the current policy's amendment threshold and timelock. The allowlist and role
/// assignments are the two things a POLICY_ADMIN may change in place, because
/// they are membership rather than rules — a vendor list that could never change
/// would make the product unusable.
contract PolicyEngine {
    /// @notice One amount band. Payments up to `maxAmountUsd` need
    /// `requiredApprovals` approvals and wait `timelockSeconds`.
    struct Tier {
        uint128 maxAmountUsd; // 18-decimal USD ceiling
        uint8 requiredApprovals;
        uint32 timelockSeconds;
    }

    /// @notice A complete rule set. `tiers` ascend; the last one is the hard
    /// per-payment cap.
    struct Policy {
        uint256 id;
        Tier[] tiers;
        uint128 rollingWindowUsd;
        uint32 windowSeconds;
        bool allowlistEnforced;
        uint8 amendApprovals;
        uint32 amendTimelock;
    }

    /// @notice May propose payments.
    uint8 public constant ROLE_PROPOSER = 1;
    /// @notice May approve payments proposed by others.
    uint8 public constant ROLE_APPROVER = 2;
    /// @notice May freeze a treasury alone, with no threshold and no delay.
    uint8 public constant ROLE_GUARDIAN = 4;
    /// @notice May grant roles and edit the allowlist.
    uint8 public constant ROLE_POLICY_ADMIN = 8;

    /// @notice Every role bit, for callers that want to grant all of them.
    uint8 public constant ROLE_ALL = 15;

    /// @notice Upper bound on tiers per policy, so tier resolution stays cheap.
    uint256 public constant MAX_TIERS = 16;

    uint256 private _nextPolicyId = 1;

    mapping(uint256 policyId => Policy) private _policies;
    mapping(uint256 policyId => mapping(address account => uint8 roleMask)) private _roles;
    mapping(uint256 policyId => mapping(bytes32 accountId => mapping(uint32 tag => bool))) private _allowlist;

    /// @notice Emitted once per policy, at creation.
    event PolicyCreated(uint256 indexed policyId, address indexed creator, uint256 tierCount);
    /// @notice Emitted when a role mask is written.
    event RolesSet(uint256 indexed policyId, address indexed account, uint8 roleMask);
    /// @notice Emitted when an allowlist entry changes.
    event AllowlistSet(uint256 indexed policyId, bytes32 indexed accountId, uint32 destinationTag, bool allowed);

    error PolicyNotFound(uint256 policyId);
    error NoTiers();
    error TooManyTiers();
    error TiersNotAscending(uint256 index);
    error TierNeedsApprovals(uint256 index);
    error RollingWindowRequired();
    error WindowSecondsRequired();
    error AmendApprovalsRequired();
    error AmountExceedsPolicyCap(uint256 amountUsd, uint256 cap);
    error NotPolicyAdmin(uint256 policyId, address account);
    error ZeroAddress();

    /// @notice Creates an immutable policy and makes the caller its admin.
    /// @param tiers Ascending amount bands; the last one is the hard cap.
    /// @param rollingWindowUsd Total USD that may be committed inside a window.
    /// @param windowSeconds Length of the rolling window.
    /// @param allowlistEnforced Whether destinations must be allowlisted.
    /// @param amendApprovals Approvals needed to repoint a treasury or unfreeze it.
    /// @param amendTimelock Delay those amendments must wait out.
    /// @return policyId The new policy's id.
    function createPolicy(
        Tier[] calldata tiers,
        uint128 rollingWindowUsd,
        uint32 windowSeconds,
        bool allowlistEnforced,
        uint8 amendApprovals,
        uint32 amendTimelock
    ) external returns (uint256 policyId) {
        if (tiers.length == 0) revert NoTiers();
        if (tiers.length > MAX_TIERS) revert TooManyTiers();
        if (rollingWindowUsd == 0) revert RollingWindowRequired();
        if (windowSeconds == 0) revert WindowSecondsRequired();
        if (amendApprovals == 0) revert AmendApprovalsRequired();

        for (uint256 i = 0; i < tiers.length; ++i) {
            if (tiers[i].requiredApprovals == 0) revert TierNeedsApprovals(i);
            if (i > 0 && tiers[i].maxAmountUsd <= tiers[i - 1].maxAmountUsd) revert TiersNotAscending(i);
        }

        policyId = _nextPolicyId++;

        Policy storage p = _policies[policyId];
        p.id = policyId;
        p.rollingWindowUsd = rollingWindowUsd;
        p.windowSeconds = windowSeconds;
        p.allowlistEnforced = allowlistEnforced;
        p.amendApprovals = amendApprovals;
        p.amendTimelock = amendTimelock;
        for (uint256 i = 0; i < tiers.length; ++i) {
            p.tiers.push(tiers[i]);
        }

        _roles[policyId][msg.sender] = ROLE_POLICY_ADMIN;

        emit PolicyCreated(policyId, msg.sender, tiers.length);
        emit RolesSet(policyId, msg.sender, ROLE_POLICY_ADMIN);
    }

    /// @notice Sets an account's complete role mask for a policy.
    /// @dev Writes the whole mask rather than toggling bits, so the resulting
    /// authority is visible in one place instead of inferred from a history of
    /// grants and revokes.
    /// @param policyId The policy.
    /// @param account The address to write.
    /// @param roleMask Bitwise OR of the ROLE_ constants.
    function setRoles(uint256 policyId, address account, uint8 roleMask) external {
        _requireExists(policyId);
        _requirePolicyAdmin(policyId);
        if (account == address(0)) revert ZeroAddress();
        _roles[policyId][account] = roleMask;
        emit RolesSet(policyId, account, roleMask);
    }

    /// @notice Allows or disallows a destination for a policy.
    /// @param policyId The policy.
    /// @param xrplAccountId The destination AccountID, left-aligned in bytes32.
    /// @param destinationTag The destination tag; `0` means any tag on that account.
    /// @param allowed Whether the pair is permitted.
    function setAllowlist(uint256 policyId, bytes32 xrplAccountId, uint32 destinationTag, bool allowed) external {
        _requireExists(policyId);
        _requirePolicyAdmin(policyId);
        _allowlist[policyId][xrplAccountId][destinationTag] = allowed;
        emit AllowlistSet(policyId, xrplAccountId, destinationTag, allowed);
    }

    /// @notice Returns the lowest tier whose ceiling covers `amountUsd`.
    /// @param policyId The policy.
    /// @param amountUsd The payment amount, 18-decimal USD.
    /// @return The applicable tier.
    function resolveTier(uint256 policyId, uint256 amountUsd) external view returns (Tier memory) {
        return _resolveTier(policyId, amountUsd);
    }

    /// @notice Whether a destination may receive a payment under this policy.
    /// @dev A tag-`0` allowlist entry permits any tag on that account, which is
    /// how an exchange deposit address with per-user tags stays workable.
    /// @param policyId The policy.
    /// @param accountId The destination AccountID.
    /// @param tag The destination tag.
    /// @return True if the destination is permitted.
    function isDestinationAllowed(uint256 policyId, bytes32 accountId, uint32 tag) external view returns (bool) {
        return _isDestinationAllowed(policyId, accountId, tag);
    }

    /// @notice Reads a policy.
    /// @param policyId The policy.
    /// @return The stored policy.
    function getPolicy(uint256 policyId) external view returns (Policy memory) {
        _requireExists(policyId);
        return _policies[policyId];
    }

    /// @notice Reads the tiers of a policy.
    /// @param policyId The policy.
    /// @return The tier array.
    function getTiers(uint256 policyId) external view returns (Tier[] memory) {
        _requireExists(policyId);
        return _policies[policyId].tiers;
    }

    /// @notice The hard per-payment cap — the ceiling of the highest tier.
    /// @param policyId The policy.
    /// @return The cap in 18-decimal USD.
    function policyCap(uint256 policyId) external view returns (uint256) {
        _requireExists(policyId);
        Tier[] storage tiers = _policies[policyId].tiers;
        return tiers[tiers.length - 1].maxAmountUsd;
    }

    /// @notice An account's role mask for a policy.
    /// @param policyId The policy.
    /// @param account The address.
    /// @return The role mask.
    function rolesOf(uint256 policyId, address account) external view returns (uint8) {
        return _roles[policyId][account];
    }

    /// @notice Whether an account holds a role on a policy.
    /// @param policyId The policy.
    /// @param account The address.
    /// @param role One of the ROLE_ constants.
    /// @return True if the bit is set.
    function hasRole(uint256 policyId, address account, uint8 role) external view returns (bool) {
        return _roles[policyId][account] & role == role;
    }

    /// @notice Whether a policy id has been created.
    /// @param policyId The policy.
    /// @return True if it exists.
    function policyExists(uint256 policyId) external view returns (bool) {
        return _policies[policyId].id != 0;
    }

    function _resolveTier(uint256 policyId, uint256 amountUsd) private view returns (Tier memory) {
        _requireExists(policyId);
        Tier[] storage tiers = _policies[policyId].tiers;
        for (uint256 i = 0; i < tiers.length; ++i) {
            if (amountUsd <= tiers[i].maxAmountUsd) return tiers[i];
        }
        revert AmountExceedsPolicyCap(amountUsd, tiers[tiers.length - 1].maxAmountUsd);
    }

    function _isDestinationAllowed(uint256 policyId, bytes32 accountId, uint32 tag) private view returns (bool) {
        _requireExists(policyId);
        if (!_policies[policyId].allowlistEnforced) return true;
        if (_allowlist[policyId][accountId][0]) return true;
        return _allowlist[policyId][accountId][tag];
    }

    function _requireExists(uint256 policyId) private view {
        if (_policies[policyId].id == 0) revert PolicyNotFound(policyId);
    }

    function _requirePolicyAdmin(uint256 policyId) private view {
        if (_roles[policyId][msg.sender] & ROLE_POLICY_ADMIN == 0) revert NotPolicyAdmin(policyId, msg.sender);
    }
}
