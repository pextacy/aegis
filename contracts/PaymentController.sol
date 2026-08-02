// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAegisInstructionSender} from "./interfaces/IAegisInstructionSender.sol";
import {IFtsoV2} from "./interfaces/IFtsoV2.sol";
import {PolicyEngine} from "./PolicyEngine.sol";
import {TreasuryRegistry} from "./TreasuryRegistry.sol";

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
    mapping(uint256 treasuryId => WindowEntry[]) private _window;
    mapping(uint256 treasuryId => uint256) private _windowHead;

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
    error TimelockNotElapsed(uint64 eligibleAt, uint64 nowTime);
    error InsufficientApprovals(uint8 have, uint8 need);

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
        unchecked {
            ++r.approvals;
        }

        emit PaymentApproved(requestId, msg.sender, r.approvals, r.requiredApprovals);

        if (r.approvals >= r.requiredApprovals) {
            r.state = RequestState.Approved;
            emit PaymentReady(requestId, r.eligibleAt);
        }
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
        if (r.approvals < tier.requiredApprovals) revert InsufficientApprovals(r.approvals, tier.requiredApprovals);

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

    function _releaseWindow(uint256 requestId, PaymentRequest storage r) private {
        uint256 amount = r.committedUsd;
        if (amount == 0) return;
        WindowEntry[] storage entries = _window[r.treasuryId];
        uint256 idx = r.windowIndex;
        if (idx < entries.length && entries[idx].amountUsd == uint192(amount)) {
            entries[idx].amountUsd = 0;
        }
        r.committedUsd = 0;
        emit WindowSpendReleased(r.treasuryId, requestId, amount);
    }

    function _requireRequest(uint256 requestId) private view returns (PaymentRequest storage r) {
        r = _requests[requestId];
        if (r.treasuryId == 0) revert RequestNotFound(requestId);
    }
}
