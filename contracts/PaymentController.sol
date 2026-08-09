// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAegisInstructionSender} from "./interfaces/IAegisInstructionSender.sol";
import {IFtsoV2} from "./interfaces/IFtsoV2.sol";
import {PolicyEngine} from "./PolicyEngine.sol";
import {TreasuryRegistry} from "./TreasuryRegistry.sol";
import {XrplAddress} from "./lib/XrplAddress.sol";

/// @title PaymentController
/// @author Aegis
/// @notice The payment state machine: propose, approve, dispatch, and the
/// rolling-window accounting that ties them together.
/// @dev `dispatch` re-runs the entire policy check rather than trusting what
/// passed at proposal. The XRP price moves and the rolling window is shared
/// between requests, so a request that was valid an hour ago is not
/// automatically valid now — grandfathering is how treasuries get drained.
contract PaymentController {
    /// @notice Lifecycle of one proposed XRPL payment.
    enum RequestState {
        Proposed,
        Approved,
        Dispatched,
        Signed,
        Settled,
        Failed,
        Cancelled
    }

    /// @notice One proposed payment and everything the contract checked about it.
    struct PaymentRequest {
        uint256 treasuryId;
        bytes32 destinationAccountId;
        uint32 destinationTag;
        uint64 amountDrops;
        uint256 amountUsdAtProposal;
        uint32 sequence;
        uint32 firstLedgerSequence;
        uint32 lastLedgerSequence;
        uint64 feeDrops;
        uint8 approvals;
        uint8 requiredApprovals;
        uint64 eligibleAt;
        RequestState state;
        bytes32 policyDigest;
        address proposer;
        uint256 committedUsd;
        uint256 windowIndex;
        // Appended for k-of-n. Both are zero on a treasury that signs with one
        // key, and both are snapshots taken at dispatch: a quorum changed while
        // a payment is in flight must not move the bar the payment was
        // dispatched under.
        bytes32 multiSignDigest;
        uint8 quorumRequired;
    }

    /// @notice One enclave's share of a k-of-n signature.
    struct PartialSignature {
        bytes32 signerAccountId;
        bytes signerPubKey;
        bytes signature;
    }

    /// @notice One committed spend inside a treasury's rolling window.
    struct WindowEntry {
        uint64 timestamp;
        uint192 amountUsd;
    }

    /// @notice XRP/USD, derived rather than hardcoded. Category byte 1 is crypto.
    bytes21 public constant XRP_USD_FEED = bytes21(abi.encodePacked(uint8(1), bytes7("XRP/USD"), bytes13(0)));

    /// @notice Oldest FTSO value that may price a payment.
    /// @dev A stale feed blocks the payment rather than falling back to a cached
    /// price. Refusing to spend is the correct failure mode for a treasury.
    uint64 public constant MAX_PRICE_AGE = 180;

    /// @notice Drops per XRP.
    uint256 public constant DROPS_PER_XRP = 1_000_000;

    /// @notice The policy engine.
    PolicyEngine public immutable POLICY_ENGINE;
    /// @notice The treasury registry.
    TreasuryRegistry public immutable TREASURY_REGISTRY;
    /// @notice The FtsoV2 feed reader.
    IFtsoV2 public immutable FTSO;

    /// @notice Address allowed to wire the collaborating contracts, once each.
    address public immutable OWNER;

    /// @notice The only address that may record a signature.
    IAegisInstructionSender public instructionSender;
    /// @notice The only address that may settle or fail a request.
    address public executionVerifier;

    uint256 private _nextRequestId = 1;

    mapping(uint256 requestId => PaymentRequest) private _requests;
    mapping(uint256 requestId => mapping(address approver => bool)) private _approved;
    /// @dev Who approved, not just how many. `dispatch` re-checks that each of
    /// these still holds `ROLE_APPROVER`, which a bare count cannot express.
    /// Bounded by the request's `requiredApprovals`, because `approve` refuses
    /// any state but `Proposed` and the threshold is what leaves that state.
    mapping(uint256 requestId => address[]) private _approvers;
    mapping(uint256 treasuryId => WindowEntry[]) private _window;
    mapping(uint256 treasuryId => uint256) private _windowHead;
    mapping(uint256 requestId => PartialSignature[]) private _partialSignatures;
    mapping(uint256 requestId => mapping(bytes32 signerAccountId => bool)) private _hasPartiallySigned;

    /// @notice Emitted when a payment is proposed and has passed every policy check.
    event PaymentProposed(
        uint256 indexed requestId,
        uint256 indexed treasuryId,
        address indexed proposer,
        bytes32 destinationAccountId,
        uint32 destinationTag,
        uint64 amountDrops,
        uint256 amountUsd,
        uint8 requiredApprovals,
        uint64 eligibleAt
    );
    /// @notice Emitted on each approval.
    event PaymentApproved(uint256 indexed requestId, address indexed approver, uint8 approvals, uint8 required);
    /// @notice Emitted when an approver withdraws their own approval.
    event PaymentApprovalRevoked(uint256 indexed requestId, address indexed approver, uint8 approvals, uint8 required);
    /// @notice Emitted when a request reaches its approval threshold.
    event PaymentReady(uint256 indexed requestId, uint64 eligibleAt);
    /// @notice Emitted when a signing instruction goes to the TEE.
    event PaymentDispatched(
        uint256 indexed requestId,
        uint32 sequence,
        uint32 firstLedgerSequence,
        uint32 lastLedgerSequence,
        uint64 feeDrops,
        bytes32 policyDigest
    );
    /// @notice Emitted when the TEE returns a signature. The submitter watches this.
    event PaymentSigned(uint256 indexed requestId, bytes signedBlob, bytes32 txHash);
    /// @notice Emitted for each enclave that contributes to a k-of-n signature.
    /// @dev Every share is published, so a quorum can be reconstructed from chain
    /// data alone with no Aegis service running — which is what lets anyone
    /// assemble and submit the transaction, and what makes the assembler
    /// powerless rather than trusted.
    event PaymentPartiallySigned(
        uint256 indexed requestId, bytes32 indexed signerAccountId, bytes signerPubKey, bytes signature, uint8 collected
    );
    /// @notice Emitted when enough enclaves have signed for the payment to submit.
    event PaymentMultiSigned(uint256 indexed requestId, uint256 indexed treasuryId, uint8 collected, uint8 quorum);
    /// @notice Emitted when a share arrives for a payment that already reached
    /// its quorum, which is a late machine rather than an error.
    event PartialSignatureIgnored(uint256 indexed requestId, bytes32 indexed signerAccountId);
    /// @notice Emitted when an FDC proof confirms settlement.
    event PaymentSettled(uint256 indexed requestId, uint32 sequence);
    /// @notice Emitted when a request ends without moving funds.
    event PaymentFailed(uint256 indexed requestId, bytes32 reason);
    /// @notice Emitted when a proposer withdraws a request before dispatch.
    event PaymentCancelled(uint256 indexed requestId);
    /// @notice Emitted when committed window spend is returned.
    event WindowSpendReleased(uint256 indexed treasuryId, uint256 indexed requestId, uint256 amountUsd);
    /// @notice Emitted when a collaborating contract address is wired.
    event ContractWired(bytes32 indexed what, address indexed addr);

    error NotOwner();
    error AlreadyWired();
    error ZeroAddress();
    error RequestNotFound(uint256 requestId);
    error NotInstructionSender();
    error NotExecutionVerifier();
    error InstructionSenderNotSet();
    error NotProposer(uint256 policyId, address account);
    error NotApprover(uint256 policyId, address account);
    error TreasuryIsFrozen(uint256 treasuryId);
    error XrplAccountNotBound(uint256 treasuryId);
    error ZeroAmount();
    error ZeroDestination();
    error DestinationNotLeftAligned(bytes32 accountId);

    /// @notice A request's rolling-window entry is not where it was recorded.
    /// @dev An invariant assertion. Reachable only through storage corruption,
    /// and loud rather than silent because the alternative is a release that is
    /// reported but did not happen.
    error WindowEntryMismatch(uint256 treasuryId, uint256 requestId, uint256 windowIndex);

    /// @notice The treasury's XRPL starting sequence has not been recorded yet.
    /// @dev Signing against a guessed sequence produces a transaction XRPL
    /// rejects and can never prove, so this refuses instead.
    error SequenceNotInitialised(uint256 treasuryId);
    error LastLedgerSequenceRequired();
    error FirstLedgerSequenceRequired();
    error LedgerRangeInverted(uint32 firstLedgerSequence, uint32 lastLedgerSequence);
    error ZeroFee();
    error StalePrice(uint64 feedTimestamp, uint64 nowTime);
    error InvalidPrice();
    error DestinationNotAllowed(bytes32 accountId, uint32 tag);
    error RollingWindowExceeded(uint256 committed, uint256 requested, uint256 cap);
    error WrongState(RequestState have, RequestState want);
    error ProposerCannotApprove(uint256 requestId);
    error AlreadyApproved(uint256 requestId, address approver);
    error NotApproved(uint256 requestId, address approver);
    error ApproverEntryMissing(uint256 requestId, address approver);
    error TimelockNotElapsed(uint64 eligibleAt, uint64 nowTime);
    error InsufficientApprovals(uint8 have, uint8 need);

    /// @notice A share of a k-of-n signature came from a key that is not in the
    /// treasury's signer list, so XRPL would not count it either.
    error NotATreasurySigner(uint256 treasuryId, bytes32 signerAccountId);

    /// @notice The same enclave cannot contribute twice towards one quorum.
    error AlreadyPartiallySigned(uint256 requestId, bytes32 signerAccountId);

    /// @notice A share arrived for a payment that was never dispatched to a quorum.
    error NotAQuorumPayment(uint256 requestId);

    /// @notice A signature or a key of zero length is not a contribution.
    error EmptySignature(uint256 requestId);

    /// @param policyEngine The policy engine.
    /// @param treasuryRegistry The treasury registry.
    /// @param ftso The FtsoV2 address for this chain.
    constructor(PolicyEngine policyEngine, TreasuryRegistry treasuryRegistry, IFtsoV2 ftso) {
        if (address(policyEngine) == address(0)) revert ZeroAddress();
        if (address(treasuryRegistry) == address(0)) revert ZeroAddress();
        if (address(ftso) == address(0)) revert ZeroAddress();
        POLICY_ENGINE = policyEngine;
        TREASURY_REGISTRY = treasuryRegistry;
        FTSO = ftso;
        OWNER = msg.sender;
    }

    /// @notice Wires the instruction sender. Callable once.
    /// @param sender The AegisInstructionSender address.
    function setInstructionSender(IAegisInstructionSender sender) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (address(instructionSender) != address(0)) revert AlreadyWired();
        if (address(sender) == address(0)) revert ZeroAddress();
        instructionSender = sender;
        emit ContractWired("instructionSender", address(sender));
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

    /// @notice Proposes an XRPL payment, checking every rule up front.
    /// @dev Reverts on the first violation so nobody is asked to approve a
    /// request that could never execute.
    /// @param treasuryId The paying treasury.
    /// @param destAccountId The destination AccountID, left-aligned in bytes32.
    /// @param destTag The destination tag; `0` means none.
    /// @param amountDrops The amount in drops.
    /// @return requestId The new request's id.
    function propose(uint256 treasuryId, bytes32 destAccountId, uint32 destTag, uint64 amountDrops)
        external
        returns (uint256 requestId)
    {
        if (amountDrops == 0) revert ZeroAmount();
        if (destAccountId == bytes32(0)) revert ZeroDestination();
        // A 20-byte AccountID is left-aligned in bytes32, which is how Solidity
        // carries it. A right-aligned value passes every check in this contract
        // and is then unsignable — the enclave refuses it as not an AccountID —
        // so it is caught here rather than after approvals have been collected.
        if (uint256(destAccountId) & type(uint96).max != 0) revert DestinationNotLeftAligned(destAccountId);

        TreasuryRegistry.Treasury memory t = TREASURY_REGISTRY.getTreasury(treasuryId);
        if (t.frozen) revert TreasuryIsFrozen(treasuryId);
        // Refused here rather than at dispatch, for the same reason as the
        // alignment check above: a request that can never be signed must not
        // collect approvals first.
        if (t.nextSequence == 0) revert SequenceNotInitialised(treasuryId);
        if (!POLICY_ENGINE.hasRole(t.policyId, msg.sender, POLICY_ENGINE.ROLE_PROPOSER())) {
            revert NotProposer(t.policyId, msg.sender);
        }

        uint256 amountUsd = _amountUsd(amountDrops);

        if (!POLICY_ENGINE.isDestinationAllowed(t.policyId, destAccountId, destTag)) {
            revert DestinationNotAllowed(destAccountId, destTag);
        }

        PolicyEngine.Tier memory tier = POLICY_ENGINE.resolveTier(t.policyId, amountUsd);
        _requireWindowFits(treasuryId, t.policyId, amountUsd);

        requestId = _nextRequestId++;
        PaymentRequest storage r = _requests[requestId];
        r.treasuryId = treasuryId;
        r.destinationAccountId = destAccountId;
        r.destinationTag = destTag;
        r.amountDrops = amountDrops;
        r.amountUsdAtProposal = amountUsd;
        r.requiredApprovals = tier.requiredApprovals;
        r.eligibleAt = uint64(block.timestamp) + tier.timelockSeconds;
        r.state = RequestState.Proposed;
        r.proposer = msg.sender;

        emit PaymentProposed(
            requestId,
            treasuryId,
            msg.sender,
            destAccountId,
            destTag,
            amountDrops,
            amountUsd,
            tier.requiredApprovals,
            r.eligibleAt
        );
    }

    /// @notice Approves a proposed payment.
    /// @dev The proposer is refused, and so is a second approval from the same
    /// address. Segregation of duties is enforced here rather than requested.
    /// @param requestId The request.
    function approve(uint256 requestId) external {
        PaymentRequest storage r = _requireRequest(requestId);
        if (r.state != RequestState.Proposed) revert WrongState(r.state, RequestState.Proposed);

        uint256 policyId = TREASURY_REGISTRY.policyIdOf(r.treasuryId);
        if (TREASURY_REGISTRY.isFrozen(r.treasuryId)) revert TreasuryIsFrozen(r.treasuryId);
        if (!POLICY_ENGINE.hasRole(policyId, msg.sender, POLICY_ENGINE.ROLE_APPROVER())) {
            revert NotApprover(policyId, msg.sender);
        }
        if (msg.sender == r.proposer) revert ProposerCannotApprove(requestId);
        if (_approved[requestId][msg.sender]) revert AlreadyApproved(requestId, msg.sender);

        _approved[requestId][msg.sender] = true;
        _approvers[requestId].push(msg.sender);
        unchecked {
            ++r.approvals;
        }

        emit PaymentApproved(requestId, msg.sender, r.approvals, r.requiredApprovals);

        if (r.approvals >= r.requiredApprovals) {
            r.state = RequestState.Approved;
            emit PaymentReady(requestId, r.eligibleAt);
        }
    }

    /// @notice Withdraws an approval the caller gave earlier, before dispatch.
    /// @dev The timelock exists so that an approver has time to reconsider.
    /// Without this path the only way to act on reconsidering is a guardian
    /// freeze, which stops every payment the treasury has in flight rather than
    /// the one the approver objects to.
    ///
    /// Three deliberate asymmetries with `approve`:
    ///
    /// - No role check. An address whose `ROLE_APPROVER` was taken away still
    ///   occupies a slot in `approvals` and in the approver set — `dispatch` no
    ///   longer weighs it, but nothing else removes it either. Requiring the role
    ///   here would leave that entry stranded, with no one able to clear it.
    /// - The freeze is not checked. Revoking is a withdrawal of authorisation,
    ///   and every other refusal-to-spend path in this system stays open when a
    ///   treasury is frozen. Blocking it would make a freeze *preserve* the
    ///   approvals it is meant to interrupt.
    /// - Only the approver themselves. Anyone else revoking a third party's
    ///   approval would be a veto that no role in the policy grants.
    /// @param requestId The request.
    function revokeApproval(uint256 requestId) external {
        PaymentRequest storage r = _requireRequest(requestId);
        if (r.state != RequestState.Proposed && r.state != RequestState.Approved) {
            revert WrongState(r.state, RequestState.Proposed);
        }
        if (!_approved[requestId][msg.sender]) revert NotApproved(requestId, msg.sender);

        _approved[requestId][msg.sender] = false;
        _removeApprover(requestId, msg.sender);
        unchecked {
            --r.approvals;
        }

        // Demotion from `Approved` is unconditional, and that is an invariant
        // rather than a shortcut: `approve` refuses any state but `Proposed`, and
        // `PolicyEngine.createPolicy` rejects a tier requiring zero approvals, so
        // a request arrives at `Approved` holding exactly the threshold and never
        // more. Removing one always drops it below.
        //
        // `eligibleAt` is untouched: it is a proposal-time clock, and restarting
        // it here would let a single approver extend the timelock at will.
        if (r.state == RequestState.Approved) {
            r.state = RequestState.Proposed;
        }

        emit PaymentApprovalRevoked(requestId, msg.sender, r.approvals, r.requiredApprovals);
    }

    /// @notice Withdraws a request before it is dispatched.
    /// @param requestId The request.
    function cancel(uint256 requestId) external {
        PaymentRequest storage r = _requireRequest(requestId);
        if (r.state != RequestState.Proposed && r.state != RequestState.Approved) {
            revert WrongState(r.state, RequestState.Proposed);
        }
        if (msg.sender != r.proposer) revert NotProposer(TREASURY_REGISTRY.policyIdOf(r.treasuryId), msg.sender);
        r.state = RequestState.Cancelled;
        emit PaymentCancelled(requestId);
    }

    /// @notice Re-checks the whole policy against current state, then sends the
    /// signing instruction to the TEE.
    /// @dev `firstLedgerSequence` is not part of the policy digest and the
    /// enclave never sees it — it is not an XRPL transaction field. It exists so
    /// that `ExecutionVerifier.confirmNonExecution` can require a proof whose
    /// searched range covers every ledger the payment could have reached.
    /// Without a lower bound, a one-ledger non-existence proof would "prove" a
    /// payment absent that had in fact already landed.
    /// @param requestId The request.
    /// @param firstLedgerSequence The current XRPL ledger. Nothing signed after
    /// this call can appear in an earlier one.
    /// @param lastLedgerSequence The XRPL ledger after which the payment expires.
    /// @param feeDrops The XRPL fee, in drops.
    function dispatch(uint256 requestId, uint32 firstLedgerSequence, uint32 lastLedgerSequence, uint64 feeDrops)
        external
        payable
    {
        if (address(instructionSender) == address(0)) revert InstructionSenderNotSet();
        if (lastLedgerSequence == 0) revert LastLedgerSequenceRequired();
        if (firstLedgerSequence == 0) revert FirstLedgerSequenceRequired();
        if (firstLedgerSequence > lastLedgerSequence) {
            revert LedgerRangeInverted(firstLedgerSequence, lastLedgerSequence);
        }
        if (feeDrops == 0) revert ZeroFee();

        PaymentRequest storage r = _requireRequest(requestId);
        if (r.state != RequestState.Approved) revert WrongState(r.state, RequestState.Approved);
        if (block.timestamp < r.eligibleAt) revert TimelockNotElapsed(r.eligibleAt, uint64(block.timestamp));

        TreasuryRegistry.Treasury memory t = TREASURY_REGISTRY.getTreasury(r.treasuryId);
        if (t.frozen) revert TreasuryIsFrozen(r.treasuryId);
        if (t.xrplAccountId == bytes32(0)) revert XrplAccountNotBound(r.treasuryId);
        if (!POLICY_ENGINE.hasRole(t.policyId, msg.sender, POLICY_ENGINE.ROLE_PROPOSER())) {
            revert NotProposer(t.policyId, msg.sender);
        }

        // Everything below is re-derived from current state, not read back from
        // the proposal. The price has moved and the window is shared.
        uint256 amountUsd = _amountUsd(r.amountDrops);

        if (!POLICY_ENGINE.isDestinationAllowed(t.policyId, r.destinationAccountId, r.destinationTag)) {
            revert DestinationNotAllowed(r.destinationAccountId, r.destinationTag);
        }

        PolicyEngine.Tier memory tier = POLICY_ENGINE.resolveTier(t.policyId, amountUsd);

        // Counted by re-checking who approved, not by reading back how many did.
        // An approval is authority borrowed from a role, and the role can be
        // taken away between approving and dispatching — which is exactly what a
        // policy admin does on discovering that an approver is compromised.
        // Trusting the stored count would let that approver's vote carry the
        // payment anyway, and it is the same grandfathering this function
        // re-runs every other rule to avoid.
        uint8 valid = _validApprovals(requestId, t.policyId);
        if (valid < tier.requiredApprovals) revert InsufficientApprovals(valid, tier.requiredApprovals);

        _requireWindowFits(r.treasuryId, t.policyId, amountUsd);

        // Re-checked at dispatch rather than trusted from proposal, like every
        // other rule here: the whole point of dispatch is that an hour-old
        // answer is not automatically still true.
        uint32 sequence = t.nextSequence;
        if (sequence == 0) revert SequenceNotInitialised(r.treasuryId);

        bytes32 digest = _policyDigest(
            requestId,
            r.treasuryId,
            r.destinationAccountId,
            r.destinationTag,
            r.amountDrops,
            sequence,
            lastLedgerSequence,
            feeDrops
        );

        r.sequence = sequence;
        r.firstLedgerSequence = firstLedgerSequence;
        r.lastLedgerSequence = lastLedgerSequence;
        r.feeDrops = feeDrops;
        r.policyDigest = digest;
        r.state = RequestState.Dispatched;
        r.committedUsd = amountUsd;
        r.windowIndex = _window[r.treasuryId].length;
        // Narrowing is safe: _requireWindowFits has already established that
        // amountUsd fits under rollingWindowUsd, which is a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        _window[r.treasuryId].push(WindowEntry({timestamp: uint64(block.timestamp), amountUsd: uint192(amountUsd)}));

        emit PaymentDispatched(requestId, sequence, firstLedgerSequence, lastLedgerSequence, feeDrops, digest);

        // Which signer the payment goes to is read here rather than at proposal,
        // for the same reason as everything else in this function: a treasury
        // that moved to k-of-n after this request was approved must pay by
        // quorum, and one that has not must not be asked to.
        if (TREASURY_REGISTRY.signingIsQuorum(r.treasuryId)) {
            _dispatchToQuorum(requestId, r, t, tier.requiredApprovals, digest);
        } else {
            instructionSender.requestSignature{value: msg.value}(
                IAegisInstructionSender.SignRequest({
                    requestId: requestId,
                    treasuryId: r.treasuryId,
                    destinationAccountId: r.destinationAccountId,
                    destinationTag: r.destinationTag,
                    amountDrops: r.amountDrops,
                    sequence: sequence,
                    lastLedgerSequence: lastLedgerSequence,
                    feeDrops: feeDrops,
                    policyDigest: digest
                }),
                POLICY_ENGINE.guardiansOf(t.policyId),
                tier.requiredApprovals
            );
        }
    }

    /// @dev Sends the k-of-n signing instruction and records what it will take
    /// to satisfy it. Split out because `dispatch` was already at the limit of
    /// what one stack frame holds.
    function _dispatchToQuorum(
        uint256 requestId,
        PaymentRequest storage r,
        TreasuryRegistry.Treasury memory t,
        uint8 requiredApprovals,
        bytes32 digest
    ) private {
        bytes32 multiDigest = _multiSignDigest(digest, t.xrplAccountId);

        r.multiSignDigest = multiDigest;
        r.quorumRequired = TREASURY_REGISTRY.quorumOf(r.treasuryId);

        instructionSender.requestMultiSignature{value: msg.value}(
            IAegisInstructionSender.MultiSignRequest({
                requestId: requestId,
                treasuryId: r.treasuryId,
                sourceAccountId: t.xrplAccountId,
                destinationAccountId: r.destinationAccountId,
                destinationTag: r.destinationTag,
                amountDrops: r.amountDrops,
                sequence: r.sequence,
                lastLedgerSequence: r.lastLedgerSequence,
                feeDrops: r.feeDrops,
                policyDigest: digest,
                multiSignDigest: multiDigest
            }),
            POLICY_ENGINE.guardiansOf(t.policyId),
            requiredApprovals
        );
    }

    /// @notice Records the signed blob the TEE produced.
    /// @dev Signing is a public event: the blob and its hash are on-chain, so a
    /// signature that was produced cannot be hidden.
    /// @param requestId The request.
    /// @param signedBlob The serialised signed XRPL transaction.
    /// @param txHash The XRPL transaction id.
    function recordSignature(uint256 requestId, bytes calldata signedBlob, bytes32 txHash) external {
        if (msg.sender != address(instructionSender)) revert NotInstructionSender();
        PaymentRequest storage r = _requireRequest(requestId);
        if (r.state != RequestState.Dispatched) revert WrongState(r.state, RequestState.Dispatched);
        r.state = RequestState.Signed;
        emit PaymentSigned(requestId, signedBlob, txHash);
    }

    /// @notice Records one enclave's share of a k-of-n signature.
    /// @dev Two checks, and neither is about trusting the relayer. The key must
    /// derive to an account in the treasury's signer list, because a signature
    /// from anywhere else is one XRPL would not count; and the same signer
    /// cannot contribute twice, because a duplicate would inflate an apparent
    /// quorum the ledger will not honour.
    ///
    /// What is deliberately not checked is the signature itself. Verifying it
    /// means secp256k1 over a SHA-512 half, and there is no precompile for
    /// SHA-512 — so a relayer can submit a share that is well-formed and wrong.
    /// The cost of that is bounded and already the cost of the relaying role:
    /// the assembled transaction is refused by XRPL, the payment is proven
    /// absent, and its window spend is released. It cannot move money, because
    /// nothing here can — settlement is only ever an FDC proof.
    /// @param requestId The request.
    /// @param signerPubKey The signing machine's compressed public key.
    /// @param signature The DER-encoded signature over the multi-signing hash.
    function recordPartialSignature(uint256 requestId, bytes calldata signerPubKey, bytes calldata signature) external {
        if (msg.sender != address(instructionSender)) revert NotInstructionSender();
        PaymentRequest storage r = _requireRequest(requestId);
        if (r.quorumRequired == 0) revert NotAQuorumPayment(requestId);
        if (signerPubKey.length == 0 || signature.length == 0) revert EmptySignature(requestId);

        bytes32 signerAccountId = bytes32(XrplAddress.accountIdFromPubKey(signerPubKey));

        // A machine whose result arrives after the quorum closed is late, not
        // wrong. Reverting would make the relayer's transaction fail for having
        // done its job, so the share is recorded as ignored and dropped.
        if (r.state == RequestState.Signed) {
            emit PartialSignatureIgnored(requestId, signerAccountId);
            return;
        }
        if (r.state != RequestState.Dispatched) revert WrongState(r.state, RequestState.Dispatched);

        if (!TREASURY_REGISTRY.isSigner(r.treasuryId, signerAccountId)) {
            revert NotATreasurySigner(r.treasuryId, signerAccountId);
        }
        if (_hasPartiallySigned[requestId][signerAccountId]) {
            revert AlreadyPartiallySigned(requestId, signerAccountId);
        }

        _hasPartiallySigned[requestId][signerAccountId] = true;
        _partialSignatures[requestId].push(
            PartialSignature({signerAccountId: signerAccountId, signerPubKey: signerPubKey, signature: signature})
        );

        // Bounded by the signer set, which TreasuryRegistry caps at MAX_SIGNERS.
        uint8 collected = uint8(_partialSignatures[requestId].length);
        emit PaymentPartiallySigned(requestId, signerAccountId, signerPubKey, signature, collected);

        if (collected >= r.quorumRequired) {
            r.state = RequestState.Signed;
            emit PaymentMultiSigned(requestId, r.treasuryId, collected, r.quorumRequired);
        }
    }

    /// @notice The shares collected towards a request's k-of-n signature.
    /// @dev This plus the request's own fields is everything an assembler needs.
    /// It holds no authority: every share already covers the whole transaction,
    /// so reordering, dropping or forging one produces a blob XRPL rejects
    /// rather than a payment nobody authorised.
    /// @param requestId The request.
    /// @return The collected shares.
    function partialSignaturesOf(uint256 requestId) external view returns (PartialSignature[] memory) {
        _requireRequest(requestId);
        return _partialSignatures[requestId];
    }

    /// @notice How many shares a request has collected.
    /// @param requestId The request.
    /// @return The count.
    function partialSignatureCount(uint256 requestId) external view returns (uint256) {
        _requireRequest(requestId);
        return _partialSignatures[requestId].length;
    }

    /// @notice Marks a request settled after an FDC proof verified the payment.
    /// @param requestId The request.
    function markSettled(uint256 requestId) external {
        if (msg.sender != executionVerifier) revert NotExecutionVerifier();
        PaymentRequest storage r = _requireRequest(requestId);
        if (r.state != RequestState.Signed) revert WrongState(r.state, RequestState.Signed);
        r.state = RequestState.Settled;
        emit PaymentSettled(requestId, r.sequence);
    }

    /// @notice Marks a request failed and returns its committed window spend.
    /// @dev Reached when an FDC non-existence proof shows the payment never
    /// landed, or when the TEE refused to sign. The release matters: without it
    /// a treasury's budget is consumed by payments that never happened.
    /// @param requestId The request.
    /// @param reason A short machine-readable reason.
    function markFailed(uint256 requestId, bytes32 reason) external {
        if (msg.sender != executionVerifier) revert NotExecutionVerifier();
        PaymentRequest storage r = _requireRequest(requestId);
        if (r.state != RequestState.Dispatched && r.state != RequestState.Signed) {
            revert WrongState(r.state, RequestState.Dispatched);
        }
        r.state = RequestState.Failed;
        _releaseWindow(requestId, r);
        emit PaymentFailed(requestId, reason);
    }

    /// @notice USD committed inside a treasury's current rolling window.
    /// @param treasuryId The treasury.
    /// @return The committed amount, 18-decimal USD.
    function committedUsd(uint256 treasuryId) external view returns (uint256) {
        uint256 policyId = TREASURY_REGISTRY.policyIdOf(treasuryId);
        PolicyEngine.Policy memory p = POLICY_ENGINE.getPolicy(policyId);
        return _committedUsd(treasuryId, p.windowSeconds);
    }

    /// @notice Reads a request.
    /// @param requestId The request.
    /// @return The stored request.
    function getRequest(uint256 requestId) external view returns (PaymentRequest memory) {
        return _requireRequest(requestId);
    }

    /// @notice Whether an address has already approved a request.
    /// @param requestId The request.
    /// @param approver The address.
    /// @return True if it approved.
    function hasApproved(uint256 requestId, address approver) external view returns (bool) {
        return _approved[requestId][approver];
    }

    /// @notice Every address whose approval currently stands on a request.
    /// @dev Withdrawn approvals are removed, so this is the live set rather than
    /// a history. The history is the `PaymentApproved` and
    /// `PaymentApprovalRevoked` event stream.
    /// @param requestId The request.
    /// @return The approvers, in no particular order.
    function approversOf(uint256 requestId) external view returns (address[] memory) {
        return _approvers[requestId];
    }

    /// @notice How many of a request's approvals still come from an address that
    /// holds `ROLE_APPROVER`.
    /// @dev This is the figure `dispatch` tests, and it can be lower than
    /// `getRequest().approvals` — an approver whose role was revoked still
    /// occupies a slot in the count but no longer carries authority. A dashboard
    /// showing only the raw count would tell an operator a payment is ready when
    /// the contract is about to refuse it.
    /// @param requestId The request.
    /// @return The number of approvals still backed by the approver role.
    function validApprovals(uint256 requestId) external view returns (uint8) {
        PaymentRequest storage r = _requireRequest(requestId);
        return _validApprovals(requestId, TREASURY_REGISTRY.policyIdOf(r.treasuryId));
    }

    /// @notice The id the next request will receive.
    /// @dev Ids run sequentially from 1, so this is the bound a client needs to
    /// enumerate every request of every treasury without an event index. The
    /// dashboard is a reader of chain state, not a service that owns a copy of
    /// it, and this is what keeps that true.
    /// @return The next request id.
    function nextRequestId() external view returns (uint256) {
        return _nextRequestId;
    }

    /// @notice Converts drops to 18-decimal USD at the current FTSO price.
    /// @param amountDrops The amount in drops.
    /// @return The USD value.
    function quoteUsd(uint64 amountDrops) external returns (uint256) {
        return _amountUsd(amountDrops);
    }

    /// @notice The digest the TEE independently recomputes before signing.
    /// @dev Field order is part of the contract with the enclave. Changing it
    /// here without changing the Go decoder produces `policy digest mismatch` on
    /// every payment, which looks like a bug and is the system working.
    /// @param requestId The request.
    /// @param treasuryId The treasury.
    /// @param destinationAccountId The destination AccountID.
    /// @param destinationTag The destination tag.
    /// @param amountDrops The amount in drops.
    /// @param sequence The XRPL sequence.
    /// @param lastLedgerSequence The expiry ledger.
    /// @param feeDrops The fee in drops.
    /// @return The keccak256 digest.
    function policyDigest(
        uint256 requestId,
        uint256 treasuryId,
        bytes32 destinationAccountId,
        uint32 destinationTag,
        uint64 amountDrops,
        uint32 sequence,
        uint32 lastLedgerSequence,
        uint64 feeDrops
    ) external pure returns (bytes32) {
        return _policyDigest(
            requestId,
            treasuryId,
            destinationAccountId,
            destinationTag,
            amountDrops,
            sequence,
            lastLedgerSequence,
            feeDrops
        );
    }

    function _policyDigest(
        uint256 requestId,
        uint256 treasuryId,
        bytes32 destinationAccountId,
        uint32 destinationTag,
        uint64 amountDrops,
        uint32 sequence,
        uint32 lastLedgerSequence,
        uint64 feeDrops
    ) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                requestId,
                treasuryId,
                destinationAccountId,
                destinationTag,
                amountDrops,
                sequence,
                lastLedgerSequence,
                feeDrops
            )
        );
    }

    /// @dev Reads XRP/USD and converts drops to an 18-decimal USD figure. A feed
    /// older than MAX_PRICE_AGE reverts; there is no cached fallback anywhere.
    /// @notice The digest binding a policy digest to the account it authorises a
    /// payment from.
    /// @dev Public so the Go side has one definition to be validated against
    /// rather than two, and so an approver can check what an enclave will be
    /// asked to prove.
    /// @param policyDigestValue The payment's policy digest.
    /// @param sourceAccountId The treasury's XRPL AccountID, left-aligned.
    /// @return The digest.
    function multiSignDigest(bytes32 policyDigestValue, bytes32 sourceAccountId) external pure returns (bytes32) {
        return _multiSignDigest(policyDigestValue, sourceAccountId);
    }

    /// @dev keccak256(abi.encode(policyDigest, sourceAccountId)).
    function _multiSignDigest(bytes32 policyDigestValue, bytes32 sourceAccountId) private pure returns (bytes32) {
        return keccak256(abi.encode(policyDigestValue, sourceAccountId));
    }

    function _amountUsd(uint64 amountDrops) private returns (uint256) {
        (uint256 value, int8 decimals, uint64 ts) = FTSO.getFeedById(XRP_USD_FEED);
        if (value == 0) revert InvalidPrice();
        if (block.timestamp < ts || block.timestamp - ts > MAX_PRICE_AGE) {
            revert StalePrice(ts, uint64(block.timestamp));
        }

        // amountDrops * value * 10^(12 - decimals): 10^12 lifts drops (1e-6 XRP)
        // to 18 decimals, then the feed's own decimals are normalised out.
        // Widened to int256 first — `12 - decimals` in int8 would overflow for a
        // sufficiently negative exponent instead of computing it.
        int256 exponent = 12 - int256(decimals);
        uint256 scaled = uint256(amountDrops) * value;
        if (exponent >= 0) {
            return scaled * (10 ** uint256(exponent));
        }
        return scaled / (10 ** uint256(-exponent));
    }

    function _requireWindowFits(uint256 treasuryId, uint256 policyId, uint256 amountUsd) private {
        PolicyEngine.Policy memory p = POLICY_ENGINE.getPolicy(policyId);
        _pruneWindow(treasuryId, p.windowSeconds);
        uint256 committed = _committedUsd(treasuryId, p.windowSeconds);
        if (committed + amountUsd > p.rollingWindowUsd) {
            revert RollingWindowExceeded(committed, amountUsd, p.rollingWindowUsd);
        }
    }

    /// @dev Drops entries that have aged out of the window. Lazy: the cost falls
    /// on whoever next touches the treasury, not on a keeper.
    function _pruneWindow(uint256 treasuryId, uint32 windowSeconds) private {
        WindowEntry[] storage entries = _window[treasuryId];
        uint256 head = _windowHead[treasuryId];
        uint256 len = entries.length;
        uint256 cutoff = block.timestamp > windowSeconds ? block.timestamp - windowSeconds : 0;
        while (head < len && entries[head].timestamp <= cutoff) {
            unchecked {
                ++head;
            }
        }
        _windowHead[treasuryId] = head;
    }

    function _committedUsd(uint256 treasuryId, uint32 windowSeconds) private view returns (uint256 total) {
        WindowEntry[] storage entries = _window[treasuryId];
        uint256 len = entries.length;
        uint256 cutoff = block.timestamp > windowSeconds ? block.timestamp - windowSeconds : 0;
        for (uint256 i = _windowHead[treasuryId]; i < len; ++i) {
            if (entries[i].timestamp > cutoff) {
                total += entries[i].amountUsd;
            }
        }
    }

    /// @dev The entry a request committed is the one it pushed at dispatch, so
    /// the lookup below cannot miss: `windowIndex` was the array length at that
    /// moment, entries are never removed (pruning advances a head index), and
    /// the narrowing is lossless because `amountUsd` fits under a uint128 cap.
    ///
    /// It is asserted rather than assumed because the alternative is the worst
    /// shape a bug here could take: emitting WindowSpendReleased and clearing
    /// the request while the treasury's committed spend silently stays consumed,
    /// which reads in every log and on every screen as a release that happened.
    /// Reverting keeps the failure visible and the accounting honest.
    function _releaseWindow(uint256 requestId, PaymentRequest storage r) private {
        uint256 amount = r.committedUsd;
        if (amount == 0) return;
        WindowEntry[] storage entries = _window[r.treasuryId];
        uint256 idx = r.windowIndex;
        if (idx >= entries.length || entries[idx].amountUsd != uint192(amount)) {
            revert WindowEntryMismatch(r.treasuryId, requestId, idx);
        }
        entries[idx].amountUsd = 0;
        r.committedUsd = 0;
        emit WindowSpendReleased(r.treasuryId, requestId, amount);
    }

    /// @dev Counts approvals still backed by `ROLE_APPROVER` on `policyId`.
    ///
    /// The loop is bounded by the request's `requiredApprovals`: `approve`
    /// refuses any state but `Proposed`, and reaching the threshold is what
    /// leaves that state, so the array can never grow past it. Withdrawing and
    /// re-approving moves within that bound rather than above it. A policy
    /// therefore sets its own gas cost here when it chooses a threshold, which
    /// is the only place the cost is bounded by something a caller controls.
    function _validApprovals(uint256 requestId, uint256 policyId) private view returns (uint8 valid) {
        address[] storage approvers = _approvers[requestId];
        uint8 role = POLICY_ENGINE.ROLE_APPROVER();
        uint256 length = approvers.length;
        for (uint256 i = 0; i < length; ++i) {
            if (POLICY_ENGINE.hasRole(policyId, approvers[i], role)) {
                unchecked {
                    ++valid;
                }
            }
        }
    }

    /// @dev Drops one approver from the live set. Order carries no meaning, so
    /// the last entry fills the gap rather than shifting the tail.
    ///
    /// Reaching the end without a match reverts, for the same reason
    /// `_releaseWindow` refuses to release a window entry it cannot find: the
    /// `_approved` flag and this array are two records of one fact, and the
    /// caller has already read `true` from the first. If they ever disagree, the
    /// count would drop while the address kept its slot, and `dispatch` would
    /// then weigh an approval nobody holds. A revert keeps that visible instead
    /// of letting the two records drift apart in silence.
    function _removeApprover(uint256 requestId, address approver) private {
        address[] storage approvers = _approvers[requestId];
        uint256 length = approvers.length;
        for (uint256 i = 0; i < length; ++i) {
            if (approvers[i] == approver) {
                approvers[i] = approvers[length - 1];
                approvers.pop();
                return;
            }
        }
        revert ApproverEntryMissing(requestId, approver);
    }

    function _requireRequest(uint256 requestId) private view returns (PaymentRequest storage r) {
        r = _requests[requestId];
        if (r.treasuryId == 0) revert RequestNotFound(requestId);
    }
}
