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
    struct PendingInstruction {
        uint256 treasuryId;
        uint256 requestId; // zero for KEYGEN and STATUS
        bytes32 opCommand;
        bool consumed;
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

        _pending[instructionId] =
            PendingInstruction({treasuryId: treasuryId, requestId: 0, opCommand: OP_COMMAND_KEYGEN, consumed: false});

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
            treasuryId: request.treasuryId, requestId: request.requestId, opCommand: OP_COMMAND_SIGNTX, consumed: false
        });

        emit SignatureRequested(instructionId, request.requestId, request.treasuryId);
    }

    /// @notice Asks the TEE whether a treasury has a key.
    /// @param treasuryId The treasury to query.
    /// @return instructionId The FCC instruction id.
    function requestStatus(uint256 treasuryId) external payable returns (bytes32 instructionId) {
        TreasuryRegistry.Treasury memory t = TREASURY_REGISTRY.getTreasury(treasuryId);

        instructionId = _send(OP_COMMAND_STATUS, abi.encode(treasuryId), POLICY_ENGINE.guardiansOf(t.policyId), 0);

        _pending[instructionId] =
            PendingInstruction({treasuryId: treasuryId, requestId: 0, opCommand: OP_COMMAND_STATUS, consumed: false});

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
        address[] memory teeIds = TEE_MACHINE_REGISTRY.getRandomTeeIds(_getExtensionId(), 1);

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

    /// @dev Marks an instruction consumed, refusing anything unknown, replayed,
    /// or answering the wrong command.
    function _consume(bytes32 instructionId, bytes32 expectedCommand) private returns (PendingInstruction storage p) {
        if (msg.sender != resultSubmitter) revert NotResultSubmitter();

        p = _pending[instructionId];
        if (p.opCommand == bytes32(0)) revert UnknownInstruction(instructionId);
        if (p.consumed) revert InstructionAlreadyConsumed(instructionId);
        if (p.opCommand != expectedCommand) revert WrongCommand(expectedCommand, p.opCommand);

        p.consumed = true;
    }

    /// @notice Returns the cached extension ID, reverting if not yet set.
    /// @return The extension ID assigned to this contract.
    function _getExtensionId() internal view returns (uint256) {
        require(_extensionId != 0, "Extension ID is not set.");
        return _extensionId;
    }
}
