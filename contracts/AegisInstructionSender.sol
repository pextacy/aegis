// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAegisInstructionSender} from "./interfaces/IAegisInstructionSender.sol";
import {ITeeExtensionRegistry} from "./interfaces/ITeeExtensionRegistry.sol";
import {ITeeMachineRegistry} from "./interfaces/ITeeMachineRegistry.sol";
import {PaymentController} from "./PaymentController.sol";
import {PolicyEngine} from "./PolicyEngine.sol";
import {TreasuryRegistry} from "./TreasuryRegistry.sol";

/// @title AegisInstructionSender
/// @author Aegis
/// @notice The only place in Aegis that touches signing.
/// @dev Everything in PolicyEngine, TreasuryRegistry and PaymentController is
/// signing-agnostic, which is what makes the PMW migration a module swap rather
/// than a rewrite: when PMW's interface is public, requestSignature calls it
/// instead of the custom extension and nothing else changes.
///
/// DO NOT MODIFY: constructor, setExtensionId(), _getExtensionId()
contract AegisInstructionSender is IAegisInstructionSender {
    /// @notice Operation type for XRPL wallet actions.
    /// @dev Must be byte-identical to config.OPTypeXRPL in Go and to the
    /// teeutils.ToHash call in internal/extension. bytes32() truncates at 32
    /// bytes, which is why these strings are short.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_TYPE_XRPL = bytes32("XRPLW");

    /// @notice Command that generates a treasury's XRPL key inside the enclave.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_COMMAND_KEYGEN = bytes32("KEYGEN");

    /// @notice Command that signs a payment, subject to the policy digest check.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_COMMAND_SIGNTX = bytes32("SIGNTX");

    /// @notice Command that reports whether a treasury has a key.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_COMMAND_STATUS = bytes32("STATUS");

    /// @notice Command that generates one machine's signer key for a treasury.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_COMMAND_SKEYGEN = bytes32("SKEYGN");

    /// @notice Command that asks one machine for its share of a k-of-n signature.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_COMMAND_MSIGN = bytes32("MSIGN");

    /// @notice Command that signs a transaction moving a treasury to k-of-n.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_COMMAND_SETUP = bytes32("SETUP");

    /// @notice Setup kind: install the signer list. Must equal
    /// types.SetupKindSignerList in the Go extension.
    uint8 public constant SETUP_KIND_SIGNER_LIST = 0;

    /// @notice Setup kind: retire the master key. Must equal
    /// types.SetupKindDisableMasterKey in the Go extension.
    uint8 public constant SETUP_KIND_DISABLE_MASTER_KEY = 1;

    /// @notice Reference to the TEE extension registry contract.
    ITeeExtensionRegistry public immutable TEE_EXTENSION_REGISTRY;
    /// @notice Reference to the TEE machine registry contract.
    ITeeMachineRegistry public immutable TEE_MACHINE_REGISTRY;

    /// @notice The treasury registry this sender binds accounts on.
    TreasuryRegistry public immutable TREASURY_REGISTRY;
    /// @notice The policy engine, read for roles and guardians.
    PolicyEngine public immutable POLICY_ENGINE;

    /// @notice Address allowed to wire the payment controller and submitter.
    address public immutable OWNER;

    /// @notice First public extension ID. The registry reserves IDs below this
    /// for system/reserved extensions such as PMW and the TEE-based FDC; public
    /// extensions are assigned from here up.
    uint256 private constant FIRST_PUBLIC_EXTENSION_ID = 0x10000; // 65536

    uint256 private _extensionId;

    /// @notice The only contract permitted to request a signature.
    PaymentController public paymentController;

    /// @notice The operator relaying TEE results back on-chain.
    /// @dev The FCC layer does not yet expose verified result delivery through
    /// the public interface, so results arrive from a nominated address. This is
    /// bounded: a signature result cannot move funds, because settlement is only
    /// ever confirmed by an FDC proof in ExecutionVerifier, and a keygen result
    /// is checked on-chain against the key it claims to describe. It is still
    /// the one place that trusts a relayer, and it is stated rather than hidden.
    address public resultSubmitter;

    /// @notice How a dispatched instruction maps back to what asked for it.
    /// @dev `expected` is how many machines the instruction went to. It is one
    /// for every single-machine command and n for the k-of-n ones, which is what
    /// lets the same record accept n results without letting it accept n + 1.
    struct PendingInstruction {
        uint256 treasuryId;
        uint256 requestId; // zero for everything but SIGNTX and MSIGN
        bytes32 opCommand;
        uint8 expected;
        uint8 answered;
        bool consumed;
    }

    /// @notice The payload of a SETUP instruction.
    /// @dev Field order is part of `setupDigest`, exactly as SignRequest's order
    /// is part of the policy digest. Changing it means changing
    /// types.SetupRequest and setupDigestArgs in the Go extension in the same
    /// commit, or every setup instruction fails with "setup digest mismatch".
    struct SetupRequest {
        uint256 treasuryId;
        uint8 kind;
        uint32 quorum;
        bytes32[] signerAccountIds;
        uint32 sequence;
        uint32 lastLedgerSequence;
        uint64 feeDrops;
        bytes32 setupDigest;
    }

    mapping(bytes32 instructionId => PendingInstruction) private _pending;

    /// @notice Emitted when a keygen instruction goes to the TEE.
    event KeygenRequested(bytes32 indexed instructionId, uint256 indexed treasuryId);
    /// @notice Emitted when a signing instruction goes to the TEE.
    event SignatureRequested(bytes32 indexed instructionId, uint256 indexed requestId, uint256 indexed treasuryId);
    /// @notice Emitted when a status instruction goes to the TEE.
    event StatusRequested(bytes32 indexed instructionId, uint256 indexed treasuryId);
    /// @notice Emitted when a keygen result is accepted and the account bound.
    event KeygenResultSubmitted(bytes32 indexed instructionId, uint256 indexed treasuryId, string classicAddress);
    /// @notice Emitted when a signature result is accepted.
    event SignatureResultSubmitted(bytes32 indexed instructionId, uint256 indexed requestId, bytes32 txHash);
    /// @notice Emitted when a signer keygen instruction goes to the machine set.
    event SignerKeygenRequested(bytes32 indexed instructionId, uint256 indexed treasuryId, uint8 machines);
    /// @notice Emitted when a k-of-n signing instruction goes to the machine set.
    event MultiSignatureRequested(
        bytes32 indexed instructionId, uint256 indexed requestId, uint256 indexed treasuryId, uint8 machines
    );
    /// @notice Emitted when a setup instruction goes to the machine set.
    event SetupRequested(bytes32 indexed instructionId, uint256 indexed treasuryId, uint8 kind, bytes32 setupDigest);
    /// @notice Emitted when a signer key result is accepted and bound.
    event SignerKeygenResultSubmitted(bytes32 indexed instructionId, uint256 indexed treasuryId, string signerAddress);
    /// @notice Emitted when one machine's share of a k-of-n signature is accepted.
    event PartialSignatureResultSubmitted(bytes32 indexed instructionId, uint256 indexed requestId, uint8 answered);
    /// @notice Emitted with the signed setup transaction, for the submitter.
    /// @dev The blob is published rather than returned, so that what was signed
    /// on a treasury's behalf is on-chain and cannot be quietly different from
    /// what reaches XRPL.
    event SetupTransactionSigned(
        bytes32 indexed instructionId, uint256 indexed treasuryId, uint8 kind, bytes signedBlob, bytes32 txHash
    );
    /// @notice Emitted when a collaborating contract address is wired.
    event ContractWired(bytes32 indexed what, address indexed addr);

    error NotOwner();
    error AlreadyWired();
    error ZeroAddress();
    error NotPaymentController();
    error NotResultSubmitter();
    error NotPolicyAdmin(uint256 policyId, address account);
    error PaymentControllerNotSet();
    error UnknownInstruction(bytes32 instructionId);
    error InstructionAlreadyConsumed(bytes32 instructionId);
    error WrongCommand(bytes32 expected, bytes32 actual);
    error AccountAlreadyBound(uint256 treasuryId);

    /// @notice A k-of-n instruction was asked for on a treasury that has not
    /// committed to one.
    error SignerSetNotConfigured(uint256 treasuryId);

    /// @notice The signer set is not in the state this instruction needs.
    error SignerSetNotInState(TreasuryRegistry.SignerSetState have, TreasuryRegistry.SignerSetState want);

    /// @notice A setup kind the extension does not implement. There is no
    /// default: an unrecognised kind is refused rather than treated as one of
    /// the two that exist.
    error UnknownSetupKind(uint8 kind);

    /// @notice Both setup transactions need an expiry and a fee, for the same
    /// reason every other transaction here does.
    error LastLedgerSequenceRequired();

    /// @notice A zero fee is not a transaction XRPL will accept.
    error ZeroFee();

    /// @notice A handover transaction cannot be signed before the treasury knows
    /// what sequence its XRPL account is at.
    error SequenceNotInitialised(uint256 treasuryId);

    /// @notice Initializes the contract with registry addresses.
    /// @param _teeExtensionRegistry Address of the TEE extension registry.
    /// @param _teeMachineRegistry Address of the TEE machine registry.
    /// @param _treasuryRegistry Address of the Aegis treasury registry.
    /// @param _policyEngine Address of the Aegis policy engine.
    constructor(
        ITeeExtensionRegistry _teeExtensionRegistry,
        ITeeMachineRegistry _teeMachineRegistry,
        TreasuryRegistry _treasuryRegistry,
        PolicyEngine _policyEngine
    ) {
        require(address(_teeExtensionRegistry) != address(0), "TeeExtensionRegistry cannot be zero address");
        require(address(_teeMachineRegistry) != address(0), "TeeMachineRegistry cannot be zero address");
        require(address(_teeExtensionRegistry).code.length > 0, "TeeExtensionRegistry has no code");
        require(address(_teeMachineRegistry).code.length > 0, "TeeMachineRegistry has no code");
        require(address(_treasuryRegistry) != address(0), "TreasuryRegistry cannot be zero address");
        require(address(_policyEngine) != address(0), "PolicyEngine cannot be zero address");
        TEE_EXTENSION_REGISTRY = _teeExtensionRegistry;
        TEE_MACHINE_REGISTRY = _teeMachineRegistry;
        TREASURY_REGISTRY = _treasuryRegistry;
        POLICY_ENGINE = _policyEngine;
        OWNER = msg.sender;
    }

    /// @notice Finds and sets this contract's extension id. Can only be set once.
    /// DO NOT MODIFY this function.
    function setExtensionId() external {
        require(_extensionId == 0, "Extension ID is already set.");
        uint256 c = TEE_EXTENSION_REGISTRY.nextPublicExtensionId();
        for (uint256 i = FIRST_PUBLIC_EXTENSION_ID; i < c; ++i) {
            if (TEE_EXTENSION_REGISTRY.getTeeExtensionInstructionsSender(i) == address(this)) {
                _extensionId = i;
                return;
            }
        }
        revert("Extension ID not found.");
    }

    /// @notice Wires the payment controller. Callable once.
    /// @param controller The PaymentController address.
    function setPaymentController(PaymentController controller) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (address(paymentController) != address(0)) revert AlreadyWired();
        if (address(controller) == address(0)) revert ZeroAddress();
        paymentController = controller;
        emit ContractWired("paymentController", address(controller));
    }

    /// @notice Wires the address permitted to relay TEE results. Callable once.
    /// @param submitter The relaying operator's address.
    function setResultSubmitter(address submitter) external {
        if (msg.sender != OWNER) revert NotOwner();
        if (resultSubmitter != address(0)) revert AlreadyWired();
        if (submitter == address(0)) revert ZeroAddress();
        resultSubmitter = submitter;
        emit ContractWired("resultSubmitter", submitter);
    }

    /// @notice Asks the TEE to generate this treasury's XRPL key.
    /// @dev Keys are born in the enclave and never imported. Sending an
    /// encrypted key through calldata would put it into permanent public
    /// storage, and encryption breaks given enough time.
    /// @param treasuryId The treasury to generate for.
    /// @return instructionId The FCC instruction id.
    function requestKeygen(uint256 treasuryId) external payable returns (bytes32 instructionId) {
        TreasuryRegistry.Treasury memory t = TREASURY_REGISTRY.getTreasury(treasuryId);
        if (t.xrplAccountId != bytes32(0)) revert AccountAlreadyBound(treasuryId);
        if (!POLICY_ENGINE.hasRole(t.policyId, msg.sender, POLICY_ENGINE.ROLE_POLICY_ADMIN())) {
            revert NotPolicyAdmin(t.policyId, msg.sender);
        }

        instructionId = _send(OP_COMMAND_KEYGEN, abi.encode(treasuryId), POLICY_ENGINE.guardiansOf(t.policyId), 0);

        _pending[instructionId] = PendingInstruction({
            treasuryId: treasuryId,
            requestId: 0,
            opCommand: OP_COMMAND_KEYGEN,
            expected: 1,
            answered: 0,
            consumed: false
        });

        emit KeygenRequested(instructionId, treasuryId);
    }

    /// @inheritdoc IAegisInstructionSender
    /// @dev The cosigners are the policy's guardians and the threshold is the
    /// tier's required approval count, so FCC independently enforces a second
    /// authorisation gate on top of Aegis' own approval accounting.
    function requestSignature(SignRequest calldata request, address[] calldata cosigners, uint8 cosignersThreshold)
        external
        payable
    {
        if (msg.sender != address(paymentController)) revert NotPaymentController();

        bytes32 instructionId = _send(OP_COMMAND_SIGNTX, abi.encode(request), cosigners, cosignersThreshold);

        _pending[instructionId] = PendingInstruction({
            treasuryId: request.treasuryId,
            requestId: request.requestId,
            opCommand: OP_COMMAND_SIGNTX,
            expected: 1,
            answered: 0,
            consumed: false
        });

        emit SignatureRequested(instructionId, request.requestId, request.treasuryId);
    }

    /// @notice Asks the TEE whether a treasury has a key.
    /// @param treasuryId The treasury to query.
    /// @return instructionId The FCC instruction id.
    function requestStatus(uint256 treasuryId) external payable returns (bytes32 instructionId) {
        TreasuryRegistry.Treasury memory t = TREASURY_REGISTRY.getTreasury(treasuryId);

        instructionId = _send(OP_COMMAND_STATUS, abi.encode(treasuryId), POLICY_ENGINE.guardiansOf(t.policyId), 0);

        _pending[instructionId] = PendingInstruction({
            treasuryId: treasuryId,
            requestId: 0,
            opCommand: OP_COMMAND_STATUS,
            expected: 1,
            answered: 0,
            consumed: false
        });

        emit StatusRequested(instructionId, treasuryId);
    }

    /// @notice Relays a KEYGEN result and binds the account on-chain.
    /// @dev TreasuryRegistry derives the AccountID from the key and re-encodes
    /// the classic address, so a result whose address does not belong to its key
    /// is rejected here regardless of who submitted it.
    /// @param instructionId The instruction this result answers.
    /// @param compressedPubKey The 33-byte compressed secp256k1 public key.
    /// @param classicAddress The address the enclave reported.
    function submitKeygenResult(bytes32 instructionId, bytes calldata compressedPubKey, string calldata classicAddress)
        external
    {
        PendingInstruction storage p = _consume(instructionId, OP_COMMAND_KEYGEN);
        TREASURY_REGISTRY.bindXrplAccount(p.treasuryId, compressedPubKey, classicAddress);
        emit KeygenResultSubmitted(instructionId, p.treasuryId, classicAddress);
    }

    /// @notice Relays a SIGNTX result and publishes the signed blob on-chain.
    /// @param instructionId The instruction this result answers.
    /// @param signedBlob The serialised signed XRPL transaction.
    /// @param txHash The XRPL transaction id.
    function submitSignatureResult(bytes32 instructionId, bytes calldata signedBlob, bytes32 txHash) external {
        if (address(paymentController) == address(0)) revert PaymentControllerNotSet();
        PendingInstruction storage p = _consume(instructionId, OP_COMMAND_SIGNTX);
        paymentController.recordSignature(p.requestId, signedBlob, txHash);
        emit SignatureResultSubmitted(instructionId, p.requestId, txHash);
    }

    /// @notice Asks every machine in the set to generate its signer key.
    /// @dev The instruction goes to as many machines as the treasury's signer
    /// set asks for, and each answers with a key of its own. FCC selects those
    /// machines at random rather than by name, so this works when the extension
    /// has exactly the machines the set is sized for — the interface offers no
    /// way to address a specific one, and that limitation is Flare's rather than
    /// something Aegis can design around.
    /// @param treasuryId The treasury.
    /// @return instructionId The FCC instruction id.
    function requestSignerKeygen(uint256 treasuryId) external payable returns (bytes32 instructionId) {
        TreasuryRegistry.Treasury memory t = TREASURY_REGISTRY.getTreasury(treasuryId);
        if (!POLICY_ENGINE.hasRole(t.policyId, msg.sender, POLICY_ENGINE.ROLE_POLICY_ADMIN())) {
            revert NotPolicyAdmin(t.policyId, msg.sender);
        }

        TreasuryRegistry.SignerSet memory s = TREASURY_REGISTRY.getSignerSet(treasuryId);
        if (s.state == TreasuryRegistry.SignerSetState.None) revert SignerSetNotConfigured(treasuryId);
        if (s.state != TreasuryRegistry.SignerSetState.Collecting) {
            revert SignerSetNotInState(s.state, TreasuryRegistry.SignerSetState.Collecting);
        }

        instructionId =
            _send(OP_COMMAND_SKEYGEN, abi.encode(treasuryId), POLICY_ENGINE.guardiansOf(t.policyId), 0, s.signerCount);

        _pending[instructionId] = PendingInstruction({
            treasuryId: treasuryId,
            requestId: 0,
            opCommand: OP_COMMAND_SKEYGEN,
            expected: s.signerCount,
            answered: 0,
            consumed: false
        });

        emit SignerKeygenRequested(instructionId, treasuryId, s.signerCount);
    }

    /// @inheritdoc IAegisInstructionSender
    /// @dev Fanned out to the whole set, because a quorum is assembled from
    /// whichever machines answer rather than from a chosen few.
    function requestMultiSignature(
        MultiSignRequest calldata request,
        address[] calldata cosigners,
        uint8 cosignersThreshold
    ) external payable {
        if (msg.sender != address(paymentController)) revert NotPaymentController();

        TreasuryRegistry.SignerSet memory s = TREASURY_REGISTRY.getSignerSet(request.treasuryId);
        if (s.state == TreasuryRegistry.SignerSetState.None) revert SignerSetNotConfigured(request.treasuryId);

        bytes32 instructionId =
            _send(OP_COMMAND_MSIGN, abi.encode(request), cosigners, cosignersThreshold, s.signerCount);

        _pending[instructionId] = PendingInstruction({
            treasuryId: request.treasuryId,
            requestId: request.requestId,
            opCommand: OP_COMMAND_MSIGN,
            expected: s.signerCount,
            answered: 0,
            consumed: false
        });

        emit MultiSignatureRequested(instructionId, request.requestId, request.treasuryId, s.signerCount);
    }

    /// @notice Asks the TEE to sign a transaction that moves a treasury to k-of-n.
    /// @dev The digest computed here is what the enclave recomputes before it
    /// signs, and it is not a formality: installing a signer list decides who can
    /// ever spend from this treasury again, so a relayer that added one account
    /// on the way would have added itself to every future quorum.
    ///
    /// The signer accounts come from the registry rather than from the caller.
    /// They are the keys the enclaves generated and the contract already
    /// verified against the addresses they claimed, so there is nothing for a
    /// caller to choose here.
    /// @dev The sequence is read from the registry rather than taken from the
    /// caller. A handover transaction consumes one exactly as a payment does, so
    /// letting an operator choose it is how a treasury ends up signing against a
    /// number XRPL has already passed — and a `tefPAST_SEQ` transaction never
    /// reaches a ledger, so no proof exists that could move the treasury on.
    /// @param treasuryId The treasury.
    /// @param kind SETUP_KIND_SIGNER_LIST or SETUP_KIND_DISABLE_MASTER_KEY.
    /// @param lastLedgerSequence The ledger after which it expires.
    /// @param feeDrops The XRPL fee, in drops.
    /// @return instructionId The FCC instruction id.
    function requestSetup(uint256 treasuryId, uint8 kind, uint32 lastLedgerSequence, uint64 feeDrops)
        external
        payable
        returns (bytes32 instructionId)
    {
        if (kind != SETUP_KIND_SIGNER_LIST && kind != SETUP_KIND_DISABLE_MASTER_KEY) {
            revert UnknownSetupKind(kind);
        }
        if (lastLedgerSequence == 0) revert LastLedgerSequenceRequired();
        if (feeDrops == 0) revert ZeroFee();

        TreasuryRegistry.Treasury memory t = TREASURY_REGISTRY.getTreasury(treasuryId);
        if (!POLICY_ENGINE.hasRole(t.policyId, msg.sender, POLICY_ENGINE.ROLE_POLICY_ADMIN())) {
            revert NotPolicyAdmin(t.policyId, msg.sender);
        }

        TreasuryRegistry.SignerSet memory s = TREASURY_REGISTRY.getSignerSet(treasuryId);

        uint32 quorum;
        bytes32[] memory signers;
        if (kind == SETUP_KIND_SIGNER_LIST) {
            if (s.state != TreasuryRegistry.SignerSetState.Ready) {
                revert SignerSetNotInState(s.state, TreasuryRegistry.SignerSetState.Ready);
            }
            quorum = s.quorum;
            signers = TREASURY_REGISTRY.signersOf(treasuryId);
        } else {
            // Retiring the master key before the list is live would leave an
            // account nothing can sign for. XRPL refuses it; so does this.
            if (s.state != TreasuryRegistry.SignerSetState.Installed) {
                revert SignerSetNotInState(s.state, TreasuryRegistry.SignerSetState.Installed);
            }
            signers = new bytes32[](0);
        }

        // Read here rather than taken from the caller, and checked after the
        // state machine so a wrong step is named as a wrong step.
        uint32 sequence = t.nextSequence;
        if (sequence == 0) revert SequenceNotInitialised(treasuryId);

        bytes32 digest = _setupDigest(treasuryId, kind, quorum, signers, sequence, lastLedgerSequence, feeDrops);

        bytes memory message = abi.encode(
            SetupRequest({
                treasuryId: treasuryId,
                kind: kind,
                quorum: quorum,
                signerAccountIds: signers,
                sequence: sequence,
                lastLedgerSequence: lastLedgerSequence,
                feeDrops: feeDrops,
                setupDigest: digest
            })
        );

        instructionId = _send(OP_COMMAND_SETUP, message, POLICY_ENGINE.guardiansOf(t.policyId), 0, s.signerCount);

        _pending[instructionId] = PendingInstruction({
            treasuryId: treasuryId,
            requestId: 0,
            opCommand: OP_COMMAND_SETUP,
            // Only the machine holding the master key can answer; the rest
            // refuse for want of a key. One accepted result is the whole
            // outcome, so a second would be a replay rather than a contribution.
            expected: 1,
            answered: 0,
            consumed: false
        });

        emit SetupRequested(instructionId, treasuryId, kind, digest);
    }

    /// @notice Relays one machine's signer key and binds it on-chain.
    /// @param instructionId The instruction this result answers.
    /// @param compressedPubKey The 33-byte compressed secp256k1 public key.
    /// @param classicAddress The address the enclave reported.
    function submitSignerKeygenResult(
        bytes32 instructionId,
        bytes calldata compressedPubKey,
        string calldata classicAddress
    ) external {
        PendingInstruction storage p = _consume(instructionId, OP_COMMAND_SKEYGEN);
        TREASURY_REGISTRY.bindSignerKey(p.treasuryId, compressedPubKey, classicAddress);
        emit SignerKeygenResultSubmitted(instructionId, p.treasuryId, classicAddress);
    }

    /// @notice Relays one machine's share of a k-of-n signature.
    /// @dev The controller checks the key derives to a bound signer and refuses
    /// a second contribution from the same one, so the only thing a relayer can
    /// do with a fabricated signature is produce a transaction XRPL rejects.
    /// @param instructionId The instruction this result answers.
    /// @param signerPubKey The signing machine's compressed public key.
    /// @param signature The DER-encoded signature over the multi-signing hash.
    function submitPartialSignatureResult(bytes32 instructionId, bytes calldata signerPubKey, bytes calldata signature)
        external
    {
        if (address(paymentController) == address(0)) revert PaymentControllerNotSet();
        PendingInstruction storage p = _consume(instructionId, OP_COMMAND_MSIGN);
        paymentController.recordPartialSignature(p.requestId, signerPubKey, signature);
        emit PartialSignatureResultSubmitted(instructionId, p.requestId, p.answered);
    }

    /// @notice Relays a signed setup transaction and publishes it on-chain.
    /// @dev Nothing on-chain changes state here. The signer set moves forward
    /// only when a policy admin records that the transaction reached XRPL, with
    /// the hash that proves where to look.
    /// @param instructionId The instruction this result answers.
    /// @param kind Which setup transaction was signed.
    /// @param signedBlob The serialised signed XRPL transaction.
    /// @param txHash The XRPL transaction id.
    function submitSetupResult(bytes32 instructionId, uint8 kind, bytes calldata signedBlob, bytes32 txHash) external {
        PendingInstruction storage p = _consume(instructionId, OP_COMMAND_SETUP);
        emit SetupTransactionSigned(instructionId, p.treasuryId, kind, signedBlob, txHash);
    }

    /// @notice The digest the enclave recomputes before signing a setup transaction.
    /// @dev Public so a caller can check what it is about to authorise, and so
    /// the Go side has one definition to be validated against rather than two.
    /// @param treasuryId The treasury.
    /// @param kind The setup kind.
    /// @param quorum The quorum, zero for the retirement step.
    /// @param signerAccountIds The signer list, empty for the retirement step.
    /// @param sequence The XRPL sequence.
    /// @param lastLedgerSequence The expiry ledger.
    /// @param feeDrops The fee in drops.
    /// @return The digest.
    function setupDigest(
        uint256 treasuryId,
        uint8 kind,
        uint32 quorum,
        bytes32[] calldata signerAccountIds,
        uint32 sequence,
        uint32 lastLedgerSequence,
        uint64 feeDrops
    ) external pure returns (bytes32) {
        return _setupDigest(treasuryId, kind, quorum, signerAccountIds, sequence, lastLedgerSequence, feeDrops);
    }

    /// @notice Reads a dispatched instruction.
    /// @param instructionId The instruction id.
    /// @return The stored record.
    function getPending(bytes32 instructionId) external view returns (PendingInstruction memory) {
        return _pending[instructionId];
    }

    /// @notice The extension id assigned to this contract.
    /// @return The extension id.
    function extensionId() external view returns (uint256) {
        return _getExtensionId();
    }

    /// @dev Builds and dispatches one instruction to a randomly selected machine.
    function _send(bytes32 opCommand, bytes memory message, address[] memory cosigners, uint8 cosignersThreshold)
        private
        returns (bytes32)
    {
        return _send(opCommand, message, cosigners, cosignersThreshold, 1);
    }

    /// @dev Builds and dispatches one instruction to `machines` selected machines.
    function _send(
        bytes32 opCommand,
        bytes memory message,
        address[] memory cosigners,
        uint8 cosignersThreshold,
        uint8 machines
    ) private returns (bytes32) {
        address[] memory teeIds = TEE_MACHINE_REGISTRY.getRandomTeeIds(_getExtensionId(), machines);

        ITeeExtensionRegistry.TeeInstructionParams memory params = ITeeExtensionRegistry.TeeInstructionParams({
            opType: OP_TYPE_XRPL,
            opCommand: opCommand,
            message: message,
            cosigners: cosigners,
            cosignersThreshold: cosignersThreshold,
            claimBackAddress: msg.sender
        });

        return TEE_EXTENSION_REGISTRY.sendInstructions{value: msg.value}(teeIds, params);
    }

    /// @dev Records one answer to an instruction, refusing anything unknown,
    /// replayed, or answering the wrong command.
    ///
    /// An instruction sent to n machines accepts n answers and no more. The
    /// count is the bound rather than a flag, because "already consumed" is the
    /// wrong question when the whole point is that several machines reply.
    function _consume(bytes32 instructionId, bytes32 expectedCommand) private returns (PendingInstruction storage p) {
        if (msg.sender != resultSubmitter) revert NotResultSubmitter();

        p = _pending[instructionId];
        if (p.opCommand == bytes32(0)) revert UnknownInstruction(instructionId);
        if (p.consumed) revert InstructionAlreadyConsumed(instructionId);
        if (p.opCommand != expectedCommand) revert WrongCommand(expectedCommand, p.opCommand);

        unchecked {
            ++p.answered;
        }
        if (p.answered >= p.expected) {
            p.consumed = true;
        }
    }

    /// @dev keccak256 over the fields a setup instruction carries.
    function _setupDigest(
        uint256 treasuryId,
        uint8 kind,
        uint32 quorum,
        bytes32[] memory signerAccountIds,
        uint32 sequence,
        uint32 lastLedgerSequence,
        uint64 feeDrops
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(treasuryId, kind, quorum, signerAccountIds, sequence, lastLedgerSequence, feeDrops));
    }

    /// @notice Returns the cached extension ID, reverting if not yet set.
    /// @return The extension ID assigned to this contract.
    function _getExtensionId() internal view returns (uint256) {
        require(_extensionId != 0, "Extension ID is not set.");
        return _extensionId;
    }
}
