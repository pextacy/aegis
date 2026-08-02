// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PolicyEngine} from "./PolicyEngine.sol";
import {XrplAddress} from "./lib/XrplAddress.sol";

/// @title TreasuryRegistry
/// @author Aegis
/// @notice Treasury lifecycle and the binding between a Flare-side treasury and
/// an XRPL account whose key was born inside a TEE.
/// @dev The binding is verified, not trusted: the AccountID is derived on-chain
/// from the public key the enclave returned and the classic address is
/// re-encoded from it, so a proxy that reported a different address than the key
/// it holds is rejected here rather than discovered after funds move.
contract TreasuryRegistry {
    /// @notice What a governed amendment does.
    enum AmendmentKind {
        Unfreeze,
        ChangePolicy
    }

    /// @notice A treasury and its XRPL account.
    /// @dev `nextSequence` is zero until the account's real starting sequence is
    /// recorded — see `setInitialSequence`. Zero means "not yet known", not
    /// "sequence zero", and every path that would spend refuses while it holds.
    struct Treasury {
        uint256 id;
        bytes32 xrplAccountId; // 20-byte AccountID, left-aligned
        string xrplAddress; // base58check classic address
        uint256 policyId;
        bool frozen;
        uint32 nextSequence;
        bool sequenceConfirmed; // true once XRPL has consumed a sequence for this treasury
    }

    /// @notice A pending governed change to a treasury.
    struct Amendment {
        uint256 treasuryId;
        AmendmentKind kind;
        uint256 newPolicyId;
        address proposer;
        uint64 eligibleAt;
        uint8 approvals;
        bool executed;
    }

    /// @notice The policy engine this registry reads rules and roles from.
    PolicyEngine public immutable POLICY_ENGINE;

    /// @notice Address allowed to wire the collaborating contracts, once each.
    address public immutable OWNER;

    /// @notice The only address that may bind an XRPL account.
    address public instructionSender;
    /// @notice The only address that may advance a sequence.
    address public executionVerifier;

    uint256 private _nextTreasuryId = 1;
    uint256 private _nextAmendmentId = 1;

    mapping(uint256 treasuryId => Treasury) private _treasuries;
    mapping(uint256 amendmentId => Amendment) private _amendments;
    mapping(uint256 amendmentId => mapping(address approver => bool)) private _amendmentApproved;

    /// @notice Emitted when a treasury is reserved. Its XRPL account does not exist yet.
    event TreasuryCreated(uint256 indexed treasuryId, uint256 indexed policyId, address indexed creator);
    /// @notice Emitted once per treasury, when its XRPL account is bound.
    event XrplAccountBound(uint256 indexed treasuryId, bytes32 indexed xrplAccountId, string xrplAddress);
    /// @notice Emitted when a guardian freezes a treasury.
    event TreasuryFrozen(uint256 indexed treasuryId, address indexed guardian);
    /// @notice Emitted when a treasury is unfrozen through an amendment.
    event TreasuryUnfrozen(uint256 indexed treasuryId, uint256 indexed amendmentId);
    /// @notice Emitted when a treasury is repointed to a new policy.
    event PolicyChanged(uint256 indexed treasuryId, uint256 indexed oldPolicyId, uint256 indexed newPolicyId);
    /// @notice Emitted when an amendment is proposed.
    event AmendmentProposed(
        uint256 indexed amendmentId, uint256 indexed treasuryId, AmendmentKind kind, uint64 eligibleAt
    );
    /// @notice Emitted on each approval of an amendment.
    event AmendmentApproved(uint256 indexed amendmentId, address indexed approver, uint8 approvals);
    /// @notice Emitted when an amendment takes effect.
    event AmendmentExecuted(uint256 indexed amendmentId);
    /// @notice Emitted when a treasury's XRPL sequence advances.
    event SequenceAdvanced(uint256 indexed treasuryId, uint32 nextSequence);

    /// @notice Emitted when a treasury's starting XRPL sequence is recorded.
    event InitialSequenceSet(uint256 indexed treasuryId, uint32 sequence, address indexed setBy);
    /// @notice Emitted when a collaborating contract address is wired.
    event ContractWired(bytes32 indexed what, address indexed addr);

    error TreasuryNotFound(uint256 treasuryId);
    error AmendmentNotFound(uint256 amendmentId);
    error NotOwner();
    error AlreadyWired();
    error ZeroAddress();
    error NotInstructionSender();
    error NotExecutionVerifier();
    error NotGuardian(uint256 treasuryId, address account);
    error NotApprover(uint256 policyId, address account);
    error NotPolicyAdmin(uint256 policyId, address account);
    error AccountAlreadyBound(uint256 treasuryId);
    error AddressMismatch(string derived, string reported);
    error TreasuryFrozenError(uint256 treasuryId);
    error TreasuryNotFrozen(uint256 treasuryId);
    error PolicyNotFound(uint256 policyId);
    error SamePolicy(uint256 policyId);
    error ProposerCannotApprove(uint256 amendmentId);
    error AlreadyApproved(uint256 amendmentId, address approver);
    error AmendmentAlreadyExecuted(uint256 amendmentId);
    error TimelockNotElapsed(uint64 eligibleAt, uint64 nowTime);
    error InsufficientApprovals(uint8 have, uint8 need);
    error SequenceMustAdvance(uint32 current, uint32 supplied);

    /// @notice The starting sequence cannot be recorded before the account exists.
    error AccountNotBound(uint256 treasuryId);

    /// @notice The starting sequence is fixed once XRPL has consumed one.
    error SequenceAlreadyConfirmed(uint256 treasuryId);

    /// @notice Zero is the "not yet known" marker, so it is not a settable value.
    error InitialSequenceRequired();

    /// @param policyEngine The policy engine to read rules and roles from.
    constructor(PolicyEngine policyEngine) {
        if (address(policyEngine) == address(0)) revert ZeroAddress();
        POLICY_ENGINE = policyEngine;
        OWNER = msg.sender;
    }

    /// @notice Wires the instruction sender. Callable once.
    /// @param sender The AegisInstructionSender address.
    function setInstructionSender(address sender) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (instructionSender != address(0)) revert AlreadyWired();
        if (sender == address(0)) revert ZeroAddress();
        instructionSender = sender;
        emit ContractWired("instructionSender", sender);
    }

    /// @notice Wires the execution verifier. Callable once.
    /// @param verifier The ExecutionVerifier address.
    function setExecutionVerifier(address verifier) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (executionVerifier != address(0)) revert AlreadyWired();
        if (verifier == address(0)) revert ZeroAddress();
        executionVerifier = verifier;
        emit ContractWired("executionVerifier", verifier);
    }

    /// @notice Reserves a treasury bound to a policy. The XRPL account is created later.
    /// @param policyId The policy that will govern it.
    /// @return treasuryId The new treasury's id.
    function createTreasury(uint256 policyId) external returns (uint256 treasuryId) {
        if (!POLICY_ENGINE.policyExists(policyId)) revert PolicyNotFound(policyId);
        if (!POLICY_ENGINE.hasRole(policyId, msg.sender, POLICY_ENGINE.ROLE_POLICY_ADMIN())) {
            revert NotPolicyAdmin(policyId, msg.sender);
        }

        treasuryId = _nextTreasuryId++;
        Treasury storage t = _treasuries[treasuryId];
        t.id = treasuryId;
        t.policyId = policyId;
        // nextSequence stays zero. The XRPL account does not exist yet, and an
        // account that does not exist has no sequence to guess at.

        emit TreasuryCreated(treasuryId, policyId, msg.sender);
    }

    /// @notice Binds the XRPL account a TEE generated for this treasury.
    /// @dev Derives the AccountID from the key and re-encodes the classic
    /// address, rejecting any mismatch with what was reported. A treasury
    /// accepts exactly one binding for its lifetime.
    /// @param treasuryId The treasury.
    /// @param compressedPubKey The 33-byte compressed secp256k1 public key.
    /// @param classicAddress The address the enclave reported.
    function bindXrplAccount(uint256 treasuryId, bytes calldata compressedPubKey, string calldata classicAddress)
        external
    {
        if (msg.sender != instructionSender) revert NotInstructionSender();
        Treasury storage t = _requireTreasury(treasuryId);
        if (t.xrplAccountId != bytes32(0)) revert AccountAlreadyBound(treasuryId);

        (bytes20 accountId, string memory derived) = XrplAddress.deriveAccount(compressedPubKey);
        if (keccak256(bytes(derived)) != keccak256(bytes(classicAddress))) {
            revert AddressMismatch(derived, classicAddress);
        }

        t.xrplAccountId = bytes32(accountId);
        t.xrplAddress = derived;

        emit XrplAccountBound(treasuryId, bytes32(accountId), derived);
    }

    /// @notice Freezes a treasury. One guardian, one transaction, no delay.
    /// @param treasuryId The treasury.
    function freeze(uint256 treasuryId) external {
        Treasury storage t = _requireTreasury(treasuryId);
        if (!POLICY_ENGINE.hasRole(t.policyId, msg.sender, POLICY_ENGINE.ROLE_GUARDIAN())) {
            revert NotGuardian(treasuryId, msg.sender);
        }
        if (t.frozen) revert TreasuryFrozenError(treasuryId);
        t.frozen = true;
        emit TreasuryFrozen(treasuryId, msg.sender);
    }

    /// @notice Proposes a governed amendment: unfreeze, or repoint to a new policy.
    /// @dev Unfreezing is deliberately harder than freezing. Stopping payments
    /// on suspicion should be instant; resuming them should not be.
    /// @param treasuryId The treasury.
    /// @param kind What the amendment does.
    /// @param newPolicyId The new policy, for ChangePolicy; ignored otherwise.
    /// @return amendmentId The new amendment's id.
    function proposeAmendment(uint256 treasuryId, AmendmentKind kind, uint256 newPolicyId)
        external
        returns (uint256 amendmentId)
    {
        Treasury storage t = _requireTreasury(treasuryId);
        uint256 policyId = t.policyId;
        if (!POLICY_ENGINE.hasRole(policyId, msg.sender, POLICY_ENGINE.ROLE_POLICY_ADMIN())) {
            revert NotPolicyAdmin(policyId, msg.sender);
        }

        if (kind == AmendmentKind.Unfreeze) {
            if (!t.frozen) revert TreasuryNotFrozen(treasuryId);
        } else {
            if (!POLICY_ENGINE.policyExists(newPolicyId)) revert PolicyNotFound(newPolicyId);
            if (newPolicyId == policyId) revert SamePolicy(newPolicyId);
        }

        PolicyEngine.Policy memory p = POLICY_ENGINE.getPolicy(policyId);

        amendmentId = _nextAmendmentId++;
        Amendment storage a = _amendments[amendmentId];
        a.treasuryId = treasuryId;
        a.kind = kind;
        a.newPolicyId = newPolicyId;
        a.proposer = msg.sender;
        a.eligibleAt = uint64(block.timestamp) + p.amendTimelock;

        emit AmendmentProposed(amendmentId, treasuryId, kind, a.eligibleAt);
    }

    /// @notice Approves a pending amendment.
    /// @param amendmentId The amendment.
    function approveAmendment(uint256 amendmentId) external {
        Amendment storage a = _requireAmendment(amendmentId);
        if (a.executed) revert AmendmentAlreadyExecuted(amendmentId);

        uint256 policyId = _treasuries[a.treasuryId].policyId;
        if (!POLICY_ENGINE.hasRole(policyId, msg.sender, POLICY_ENGINE.ROLE_APPROVER())) {
            revert NotApprover(policyId, msg.sender);
        }
        if (msg.sender == a.proposer) revert ProposerCannotApprove(amendmentId);
        if (_amendmentApproved[amendmentId][msg.sender]) revert AlreadyApproved(amendmentId, msg.sender);

        _amendmentApproved[amendmentId][msg.sender] = true;
        unchecked {
            ++a.approvals;
        }

        emit AmendmentApproved(amendmentId, msg.sender, a.approvals);
    }

    /// @notice Executes an amendment whose threshold and timelock are both satisfied.
    /// @param amendmentId The amendment.
    function executeAmendment(uint256 amendmentId) external {
        Amendment storage a = _requireAmendment(amendmentId);
        if (a.executed) revert AmendmentAlreadyExecuted(amendmentId);
        if (block.timestamp < a.eligibleAt) revert TimelockNotElapsed(a.eligibleAt, uint64(block.timestamp));

        Treasury storage t = _treasuries[a.treasuryId];
        PolicyEngine.Policy memory p = POLICY_ENGINE.getPolicy(t.policyId);
        if (a.approvals < p.amendApprovals) revert InsufficientApprovals(a.approvals, p.amendApprovals);

        a.executed = true;

        if (a.kind == AmendmentKind.Unfreeze) {
            if (!t.frozen) revert TreasuryNotFrozen(a.treasuryId);
            t.frozen = false;
            emit TreasuryUnfrozen(a.treasuryId, amendmentId);
        } else {
            uint256 old = t.policyId;
            t.policyId = a.newPolicyId;
            emit PolicyChanged(a.treasuryId, old, a.newPolicyId);
        }

        emit AmendmentExecuted(amendmentId);
    }

    /// @notice Advances a treasury's XRPL sequence after a proven outcome.
    /// @dev Called on confirmed settlement and on confirmed non-execution. The
    /// non-execution path matters most: without it one expired transaction wedges
    /// the treasury forever, because XRPL keeps expecting that sequence number.
    /// @param treasuryId The treasury.
    /// @param confirmedSequence The sequence that was consumed on XRPL.
    function advanceSequence(uint256 treasuryId, uint32 confirmedSequence) external {
        if (msg.sender != executionVerifier) revert NotExecutionVerifier();
        Treasury storage t = _requireTreasury(treasuryId);
        if (confirmedSequence < t.nextSequence) revert SequenceMustAdvance(t.nextSequence, confirmedSequence);
        t.nextSequence = confirmedSequence + 1;
        // XRPL has now consumed a sequence for this account, so the starting
        // point is settled as a matter of record and stops being editable.
        t.sequenceConfirmed = true;
        emit SequenceAdvanced(treasuryId, t.nextSequence);
    }

    /// @notice Records the XRPL account's real starting sequence.
    /// @dev This exists because an XRPL account created today does not start at
    /// sequence 1. Since the DeletableAccounts amendment, a newly funded
    /// AccountRoot takes the *ledger index at which it was created* as its first
    /// sequence — a number in the tens of millions. A treasury that assumed 1
    /// would sign a transaction XRPL rejects with `tefPAST_SEQ`, and because a
    /// rejected transaction never reaches a ledger there is no proof that could
    /// advance it: `confirmSettlement` needs a settled payment, and
    /// `confirmFailedExecution` needs a `Payment` proof that only exists for a
    /// transaction a ledger actually included. The treasury would be wedged on
    /// its first payment, permanently.
    ///
    /// It cannot be folded into `bindXrplAccount` either. At KEYGEN the account
    /// has no sequence because it does not exist — XRPL creates it when it is
    /// first funded. So the order is: generate, bind, fund, then record what
    /// funding produced.
    ///
    /// A wrong value here cannot authorise anything. Destination, tag and amount
    /// are policy-checked and digest-bound regardless, and XRPL enforces the
    /// sequence itself: too low is rejected, too high never leaves the queue.
    /// The only cost is a payment that does not land, which is why the value
    /// stays correctable until XRPL confirms one.
    /// @param treasuryId The treasury.
    /// @param sequence The account's current sequence, read from `account_info`.
    function setInitialSequence(uint256 treasuryId, uint32 sequence) external {
        Treasury storage t = _requireTreasury(treasuryId);
        if (!POLICY_ENGINE.hasRole(t.policyId, msg.sender, POLICY_ENGINE.ROLE_POLICY_ADMIN())) {
            revert NotPolicyAdmin(t.policyId, msg.sender);
        }
        if (t.frozen) revert TreasuryFrozenError(treasuryId);
        if (t.xrplAccountId == bytes32(0)) revert AccountNotBound(treasuryId);
        if (t.sequenceConfirmed) revert SequenceAlreadyConfirmed(treasuryId);
        if (sequence == 0) revert InitialSequenceRequired();

        t.nextSequence = sequence;
        emit InitialSequenceSet(treasuryId, sequence, msg.sender);
    }

    /// @notice Reads a treasury.
    /// @param treasuryId The treasury.
    /// @return The stored treasury.
    function getTreasury(uint256 treasuryId) external view returns (Treasury memory) {
        return _requireTreasury(treasuryId);
    }

    /// @notice Reads an amendment.
    /// @param amendmentId The amendment.
    /// @return The stored amendment.
    function getAmendment(uint256 amendmentId) external view returns (Amendment memory) {
        return _requireAmendment(amendmentId);
    }

    /// @notice Whether a treasury is frozen.
    /// @param treasuryId The treasury.
    /// @return True if frozen.
    function isFrozen(uint256 treasuryId) external view returns (bool) {
        return _requireTreasury(treasuryId).frozen;
    }

    /// @notice The policy currently governing a treasury.
    /// @param treasuryId The treasury.
    /// @return The policy id.
    function policyIdOf(uint256 treasuryId) external view returns (uint256) {
        return _requireTreasury(treasuryId).policyId;
    }

    /// @notice The next XRPL sequence this treasury will use.
    /// @param treasuryId The treasury.
    /// @return The sequence number.
    function nextSequenceOf(uint256 treasuryId) external view returns (uint32) {
        return _requireTreasury(treasuryId).nextSequence;
    }

    /// @notice The id the next treasury will receive.
    /// @dev Ids run sequentially from 1, so this is the bound a client needs to
    /// enumerate every treasury without an event index.
    /// @return The next treasury id.
    function nextTreasuryId() external view returns (uint256) {
        return _nextTreasuryId;
    }

    /// @notice The id the next amendment will receive.
    /// @return The next amendment id.
    function nextAmendmentId() external view returns (uint256) {
        return _nextAmendmentId;
    }

    /// @notice Whether an address has already approved an amendment.
    /// @param amendmentId The amendment.
    /// @param approver The address.
    /// @return True if it approved.
    function hasApprovedAmendment(uint256 amendmentId, address approver) external view returns (bool) {
        return _amendmentApproved[amendmentId][approver];
    }

    function _requireTreasury(uint256 treasuryId) private view returns (Treasury storage t) {
        t = _treasuries[treasuryId];
        if (t.id == 0) revert TreasuryNotFound(treasuryId);
    }

    function _requireAmendment(uint256 amendmentId) private view returns (Amendment storage a) {
        a = _amendments[amendmentId];
        if (a.treasuryId == 0) revert AmendmentNotFound(amendmentId);
    }
}
