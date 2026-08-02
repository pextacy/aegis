// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IFdcVerification} from "./interfaces/IFdcVerification.sol";
import {IPayment} from "./interfaces/IPayment.sol";
import {IReferencedPaymentNonexistence} from "./interfaces/IReferencedPaymentNonexistence.sol";
import {PaymentController} from "./PaymentController.sol";
import {TreasuryRegistry} from "./TreasuryRegistry.sol";
import {XrplAddress} from "./lib/XrplAddress.sol";

/// @title ExecutionVerifier
/// @author Aegis
/// @notice Reconciles on-chain state against what actually happened on XRPL,
/// using FDC attestations rather than anyone's word for it.
/// @dev This is what separates Aegis from a signing service. The TEE never
/// learns whether a transaction landed and the submitter is never trusted: every
/// state transition out of `Signed` is driven by a proof that this contract
/// re-verifies against the round's Merkle root.
///
/// There are three proven outcomes, and they differ in exactly one consequence —
/// whether the XRPL sequence was consumed:
///
/// | Proof | State | Window | Sequence |
/// |---|---|---|---|
/// | `Payment`, status success | `Settled` | kept | advanced |
/// | `Payment`, status failure | `Failed` | released | advanced |
/// | `ReferencedPaymentNonexistence` | `Failed` | released | **not** advanced |
///
/// A transaction that reached a ledger consumes its sequence even when it
/// delivers nothing, so the treasury must move past it. A transaction that
/// expired without ever being included consumed nothing, and XRPL still expects
/// that sequence number — advancing there is what would wedge the treasury, not
/// what prevents it.
contract ExecutionVerifier {
    /// @notice The payment state machine.
    PaymentController public immutable CONTROLLER;
    /// @notice The treasury registry, for the source address and the sequence.
    TreasuryRegistry public immutable REGISTRY;
    /// @notice Flare's FDC verification contract.
    IFdcVerification public immutable FDC;

    /// @notice FDC attestation type for a payment that happened.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant ATTESTATION_TYPE_PAYMENT = bytes32("Payment");

    /// @notice FDC attestation type for a payment that did not happen.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant ATTESTATION_TYPE_NONEXISTENCE = bytes32("ReferencedPaymentNonexistence");

    /// @notice FDC source id for XRPL Testnet.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant SOURCE_ID_TEST_XRP = bytes32("testXRP");

    /// @notice The `status` value a successful payment carries.
    uint8 public constant PAYMENT_STATUS_SUCCESS = 0;

    /// @notice Reason recorded when the transaction reached a ledger and failed there.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant REASON_FAILED_ON_LEDGER = bytes32("XRPL_TX_FAILED");

    /// @notice Reason recorded when the transaction expired without being included.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant REASON_NEVER_EXECUTED = bytes32("XRPL_TX_ABSENT");

    /// @notice Emitted when a proof confirms the payment settled.
    event SettlementConfirmed(
        uint256 indexed requestId, uint256 indexed treasuryId, bytes32 indexed transactionId, uint32 sequence
    );
    /// @notice Emitted when a proof shows the transaction reached a ledger and failed.
    event ExecutionFailed(
        uint256 indexed requestId, uint256 indexed treasuryId, bytes32 indexed transactionId, uint8 status
    );
    /// @notice Emitted when a proof shows the payment never appeared.
    event NonExecutionConfirmed(
        uint256 indexed requestId, uint256 indexed treasuryId, uint64 minimalBlockNumber, uint64 deadlineBlockNumber
    );
    /// @notice Emitted when a proof arrives for a request that already reached a
    /// terminal state. Two submitters racing is expected, not an error.
    event ProofAlreadyConsumed(uint256 indexed requestId, PaymentController.RequestState state);

    error ZeroAddress();
    error ProofNotVerified();
    error WrongAttestationType(bytes32 got, bytes32 want);
    error WrongSource(bytes32 got, bytes32 want);
    error NotAwaitingSettlement(PaymentController.RequestState state);
    error NotDispatched(PaymentController.RequestState state);
    error ReferenceMismatch(bytes32 got, bytes32 want);
    error SourceMismatch(bytes32 got, bytes32 want);
    error DestinationMismatch(bytes32 got, bytes32 want);
    error SpentAmountMismatch(int256 got, int256 want);
    error PaymentDidNotSucceed(uint8 status);
    error PaymentSucceeded();
    error SourceConstrained();
    error SearchStartsTooLate(uint64 minimalBlockNumber, uint64 firstLedgerSequence);
    error SearchEndsTooEarly(uint64 deadlineBlockNumber, uint32 lastLedgerSequence);
    error SearchAmountTooHigh(uint256 amount, uint64 amountDrops);

    /// @param controller The payment controller.
    /// @param registry The treasury registry.
    /// @param fdc Flare's FDC verification contract for this chain.
    constructor(PaymentController controller, TreasuryRegistry registry, IFdcVerification fdc) {
        if (address(controller) == address(0)) revert ZeroAddress();
        if (address(registry) == address(0)) revert ZeroAddress();
        if (address(fdc) == address(0)) revert ZeroAddress();
        CONTROLLER = controller;
        REGISTRY = registry;
        FDC = fdc;
    }

    /// @notice Settles a request against a proof that its payment succeeded.
    /// @dev Every field the contract authorised is compared against what the
    /// attestation observed. The proof carries no request id of its own — the
    /// memo reference is what ties the XRPL transaction back to this request, so
    /// a valid proof for somebody else's payment fails on that comparison.
    /// @param requestId The request.
    /// @param proof The FDC `Payment` attestation and its Merkle proof.
    function confirmSettlement(uint256 requestId, IPayment.Proof calldata proof) external {
        PaymentController.PaymentRequest memory r = CONTROLLER.getRequest(requestId);
        if (_alreadyTerminal(requestId, r.state)) return;
        if (r.state != PaymentController.RequestState.Signed) revert NotAwaitingSettlement(r.state);

        IPayment.ResponseBody calldata body = _verifiedPayment(requestId, r, proof);
        if (body.status != PAYMENT_STATUS_SUCCESS) revert PaymentDidNotSucceed(body.status);

        // A successful payment debits amount and fee from the source and credits
        // the amount to the destination it actually reached.
        _requireDestination(body.receivingAddressHash, r.destinationAccountId);
        _requireSpent(body.spentAmount, r.amountDrops, r.feeDrops);

        CONTROLLER.markSettled(requestId);
        REGISTRY.advanceSequence(r.treasuryId, r.sequence);

        emit SettlementConfirmed(requestId, r.treasuryId, proof.data.requestBody.transactionId, r.sequence);
    }

    /// @notice Fails a request against a proof that its transaction reached a
    /// ledger and did not deliver.
    /// @dev A transaction that fails on XRPL still consumes its sequence and its
    /// fee. The window spend is returned because no money moved, and the
    /// sequence advances because XRPL has already moved past it.
    ///
    /// The intended fields are what is checked here: on a failed payment the
    /// attestation reports the receiving address and amount the sender meant to
    /// reach, and reports the fee alone as actually spent.
    /// @param requestId The request.
    /// @param proof The FDC `Payment` attestation and its Merkle proof.
    function confirmFailedExecution(uint256 requestId, IPayment.Proof calldata proof) external {
        PaymentController.PaymentRequest memory r = CONTROLLER.getRequest(requestId);
        if (_alreadyTerminal(requestId, r.state)) return;
        if (r.state != PaymentController.RequestState.Signed) revert NotAwaitingSettlement(r.state);

        IPayment.ResponseBody calldata body = _verifiedPayment(requestId, r, proof);
        if (body.status == PAYMENT_STATUS_SUCCESS) revert PaymentSucceeded();

        _requireDestination(body.intendedReceivingAddressHash, r.destinationAccountId);
        _requireSpent(body.intendedSpentAmount, r.amountDrops, r.feeDrops);

        CONTROLLER.markFailed(requestId, REASON_FAILED_ON_LEDGER);
        REGISTRY.advanceSequence(r.treasuryId, r.sequence);

        emit ExecutionFailed(requestId, r.treasuryId, proof.data.requestBody.transactionId, body.status);
    }

    /// @notice Fails a request against a proof that its payment never appeared.
    /// @dev The searched range must cover every ledger the payment could have
    /// reached — from the ledger current at dispatch to the one it expires
    /// after. A narrower range would prove nothing about the ledgers it skipped,
    /// and accepting one would let a settled payment be recorded as failed.
    ///
    /// The sequence is deliberately not advanced. Nothing was included, so XRPL
    /// still expects that sequence number and the next dispatch reuses it.
    /// @param requestId The request.
    /// @param proof The FDC `ReferencedPaymentNonexistence` attestation and its Merkle proof.
    function confirmNonExecution(uint256 requestId, IReferencedPaymentNonexistence.Proof calldata proof) external {
        PaymentController.PaymentRequest memory r = CONTROLLER.getRequest(requestId);
        if (_alreadyTerminal(requestId, r.state)) return;
        if (r.state != PaymentController.RequestState.Dispatched && r.state != PaymentController.RequestState.Signed) {
            revert NotDispatched(r.state);
        }

        if (proof.data.attestationType != ATTESTATION_TYPE_NONEXISTENCE) {
            revert WrongAttestationType(proof.data.attestationType, ATTESTATION_TYPE_NONEXISTENCE);
        }
        if (proof.data.sourceId != SOURCE_ID_TEST_XRP) revert WrongSource(proof.data.sourceId, SOURCE_ID_TEST_XRP);
        if (!FDC.verifyReferencedPaymentNonexistence(proof)) revert ProofNotVerified();

        IReferencedPaymentNonexistence.RequestBody calldata q = proof.data.requestBody;

        bytes32 want = requestReference(requestId);
        if (q.standardPaymentReference != want) revert ReferenceMismatch(q.standardPaymentReference, want);
        _requireDestination(q.destinationAddressHash, r.destinationAccountId);

        // A lower threshold matches more payments, so it is a stronger claim; a
        // higher one could miss the payment this request authorised.
        if (q.amount > r.amountDrops) revert SearchAmountTooHigh(q.amount, r.amountDrops);
        // Constraining source addresses narrows the search the same way.
        if (q.checkSourceAddresses) revert SourceConstrained();

        if (q.minimalBlockNumber > r.firstLedgerSequence) {
            revert SearchStartsTooLate(q.minimalBlockNumber, r.firstLedgerSequence);
        }
        if (q.deadlineBlockNumber < r.lastLedgerSequence) {
            revert SearchEndsTooEarly(q.deadlineBlockNumber, r.lastLedgerSequence);
        }

        CONTROLLER.markFailed(requestId, REASON_NEVER_EXECUTED);

        emit NonExecutionConfirmed(requestId, r.treasuryId, q.minimalBlockNumber, q.deadlineBlockNumber);
    }

    /// @notice The 32-byte memo reference that links an XRPL transaction to a request.
    /// @dev Must stay identical to the Go `types.RequestReference` the enclave
    /// writes into the memo. Changing one without the other means a settlement
    /// can never be proven.
    /// @param requestId The request.
    /// @return The reference.
    function requestReference(uint256 requestId) public pure returns (bytes32) {
        return keccak256(abi.encode(requestId));
    }

    /// @notice The standard address hash FDC reports for an XRPL AccountID.
    /// @dev FDC hashes the address as text, so the AccountID is re-encoded to a
    /// classic address here rather than compared as bytes.
    /// @param xrplAccountId The 20-byte AccountID, left-aligned in bytes32.
    /// @return The standard address hash.
    function addressHashOf(bytes32 xrplAccountId) public pure returns (bytes32) {
        return keccak256(abi.encode(XrplAddress.encodeClassicAddress(bytes20(xrplAccountId))));
    }

    /// @dev Shared identity checks for both `Payment` paths: the attestation is
    /// the type and source we expect, it verifies against its round's root, the
    /// memo reference is this request's, and the money left this treasury.
    function _verifiedPayment(
        uint256 requestId,
        PaymentController.PaymentRequest memory r,
        IPayment.Proof calldata proof
    ) private view returns (IPayment.ResponseBody calldata body) {
        if (proof.data.attestationType != ATTESTATION_TYPE_PAYMENT) {
            revert WrongAttestationType(proof.data.attestationType, ATTESTATION_TYPE_PAYMENT);
        }
        if (proof.data.sourceId != SOURCE_ID_TEST_XRP) revert WrongSource(proof.data.sourceId, SOURCE_ID_TEST_XRP);
        if (!FDC.verifyPayment(proof)) revert ProofNotVerified();

        body = proof.data.responseBody;

        bytes32 want = requestReference(requestId);
        if (body.standardPaymentReference != want) revert ReferenceMismatch(body.standardPaymentReference, want);

        bytes32 source = keccak256(abi.encode(REGISTRY.getTreasury(r.treasuryId).xrplAddress));
        if (body.sourceAddressHash != source) revert SourceMismatch(body.sourceAddressHash, source);
    }

    /// @dev Two submitters racing is the expected case, not an error: whoever
    /// arrives second finds a terminal state and returns without reverting.
    function _alreadyTerminal(uint256 requestId, PaymentController.RequestState state) private returns (bool) {
        if (state == PaymentController.RequestState.Settled || state == PaymentController.RequestState.Failed) {
            emit ProofAlreadyConsumed(requestId, state);
            return true;
        }
        return false;
    }

    function _requireDestination(bytes32 got, bytes32 destinationAccountId) private pure {
        bytes32 want = addressHashOf(destinationAccountId);
        if (got != want) revert DestinationMismatch(got, want);
    }

    function _requireSpent(int256 got, uint64 amountDrops, uint64 feeDrops) private pure {
        int256 want = int256(uint256(amountDrops) + uint256(feeDrops));
        if (got != want) revert SpentAmountMismatch(got, want);
    }
}
