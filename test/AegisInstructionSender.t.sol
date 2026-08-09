// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AegisInstructionSender} from "../contracts/AegisInstructionSender.sol";
import {PaymentController} from "../contracts/PaymentController.sol";
import {PolicyEngine} from "../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../contracts/TreasuryRegistry.sol";
import {IAegisInstructionSender} from "../contracts/interfaces/IAegisInstructionSender.sol";
import {FtsoStub} from "./helpers/Doubles.sol";
import {TeeExtensionRegistryStub, TeeMachineRegistryStub} from "./helpers/TeeDoubles.sol";

/// @notice The FCC entry point: instruction dispatch, result relay, and the
/// on-chain half of the account binding.
contract AegisInstructionSenderTest is Test {
    PolicyEngine internal policy;
    TreasuryRegistry internal registry;
    PaymentController internal controller;
    AegisInstructionSender internal sender;
    TeeExtensionRegistryStub internal extRegistry;
    TeeMachineRegistryStub internal machineRegistry;
    FtsoStub internal ftso;

    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal approverA = makeAddr("approverA");
    address internal guardianA = makeAddr("guardianA");
    address internal guardianB = makeAddr("guardianB");
    address internal submitter = makeAddr("submitter");
    address internal outsider = makeAddr("outsider");

    uint256 internal policyId;
    uint256 internal treasuryId;

    uint256 internal constant EXTENSION_ID = 0x10001;
    uint256 internal constant XRP_PRICE = 500_000;
    bytes32 internal constant DEST = bytes32(uint256(0xBEEF) << 96);

    /// @dev The XRPL genesis vector, so the binding runs against real data.
    bytes internal constant PUBKEY = hex"0330E7FC9D56BB25D6893BA3F317AE5BCF33B3291BD63DB32654A313222F7FD020";
    string internal constant CLASSIC = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh";

    /// @dev Three real secp256k1 keys with their real XRPL addresses, taken from
    /// validated mainnet transactions. Invented pairs would let a derivation bug
    /// agree with itself.
    bytes internal constant SIGNER_A_KEY = hex"028A4E362A90B01687CF26F2351FDFD1725FE7638F341453A2601DC562CE83F91D";
    string internal constant SIGNER_A_ADDR = "r4sj7Mq8hWyJdFfGCvXWpJoq7JX872582B";
    bytes internal constant SIGNER_B_KEY = hex"02C6478EF003B4CF203A1040E6784A5FEE2CF5FEA34EA7420E3AE1538C38BD26BA";
    string internal constant SIGNER_B_ADDR = "r45fyERJYiFyPFEZSUUbsvVyswiBHkynHm";
    bytes internal constant SIGNER_C_KEY = hex"03BC08FCDE76B929B00A625B4E83B73E8CA83F72195E0B52BCBDC668CF37C4A92B";
    string internal constant SIGNER_C_ADDR = "rDseVXFK1SkWhFH65cqAxf3HmvHCF6b94t";

    /// @dev The setup kinds, mirrored here as literals so that reading them is
    /// not an external call — which would consume the prank or expectRevert it
    /// sits inside. test_kOfNOpCommandsAreTheExpectedStrings pins them against
    /// the contract's own constants.
    uint8 internal constant KIND_SIGNER_LIST = 0;
    uint8 internal constant KIND_RETIRE = 1;

    /// @dev A DER-shaped signature. Its contents are never checked on-chain, so
    /// what matters is that it is non-empty and its key is a bound signer.
    bytes internal constant SIGNATURE = hex"3044022059080417C896697EE10484BE72C0643C5F1D67426241665D0F5A34312A5A8A63"
        hex"022075AF9844112FA3B83706B46FC3D7543250BB108E94B7C5038878BCD5847ACBEF";

    function setUp() public {
        vm.warp(1_700_000_000);

        policy = new PolicyEngine();
        registry = new TreasuryRegistry(policy);
        ftso = new FtsoStub();
        controller = new PaymentController(policy, registry, ftso);

        extRegistry = new TeeExtensionRegistryStub();
        machineRegistry = new TeeMachineRegistryStub();
        sender = new AegisInstructionSender(extRegistry, machineRegistry, registry, policy);

        extRegistry.register(EXTENSION_ID, address(sender));
        sender.setExtensionId();
        sender.setPaymentController(controller);
        sender.setResultSubmitter(submitter);

        registry.setInstructionSender(address(sender));
        registry.setExecutionVerifier(address(this));
        controller.setInstructionSender(sender);
        controller.setExecutionVerifier(address(this));

        ftso.set(XRP_PRICE, 6, uint64(block.timestamp));

        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](1);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: 100_000e18, requiredApprovals: 1, timelockSeconds: 0});

        vm.startPrank(admin);
        policyId = policy.createPolicy(tiers, 50_000e18, 30 days, false, 2, 1 days);
        policy.setRoles(policyId, proposer, policy.ROLE_PROPOSER());
        policy.setRoles(policyId, approverA, policy.ROLE_APPROVER());
        policy.setRoles(policyId, guardianA, policy.ROLE_GUARDIAN());
        policy.setRoles(policyId, guardianB, policy.ROLE_GUARDIAN());
        treasuryId = registry.createTreasury(policyId);
        vm.stopPrank();
    }

    /// @dev A plausible XRPL ledger height. Accounts created since the
    /// DeletableAccounts amendment start at the ledger index they were funded
    /// in, so a treasury's first sequence is a number like this, never 1.
    uint32 internal constant START_SEQUENCE = 19_574_503;

    // --- the three-way constant alignment ---------------------------------

    /// @dev The Go side asserts the same four strings. If one side drifts, one
    /// of these two tests fails instead of a live instruction coming back
    /// "unsupported op type".
    function test_opConstantsAreTheExpectedStrings() public view {
        assertEq(sender.OP_TYPE_XRPL(), bytes32("XRPLW"));
        assertEq(sender.OP_COMMAND_KEYGEN(), bytes32("KEYGEN"));
        assertEq(sender.OP_COMMAND_SIGNTX(), bytes32("SIGNTX"));
        assertEq(sender.OP_COMMAND_STATUS(), bytes32("STATUS"));
    }

    function test_extensionIdIsDiscoveredAboveTheReservedRange() public view {
        assertEq(sender.extensionId(), EXTENSION_ID);
        assertGe(sender.extensionId(), 0x10000, "ids below 0x10000 are reserved for system extensions");
    }

    // --- keygen ------------------------------------------------------------

    function test_keygenSendsTheRightInstruction() public {
        vm.prank(admin);
        sender.requestKeygen(treasuryId);

        TeeExtensionRegistryStub.Sent memory sent = extRegistry.lastSent();
        assertEq(sent.opType, bytes32("XRPLW"));
        assertEq(sent.opCommand, bytes32("KEYGEN"));
        assertEq(sent.message, abi.encode(treasuryId));
        assertEq(sent.teeIds.length, 1, "v1 selects one machine");
    }

    function test_keygenCarriesTheGuardiansAsCosigners() public {
        vm.prank(admin);
        sender.requestKeygen(treasuryId);

        TeeExtensionRegistryStub.Sent memory sent = extRegistry.lastSent();
        assertEq(sent.cosigners.length, 2);
        assertTrue(
            (sent.cosigners[0] == guardianA && sent.cosigners[1] == guardianB)
                || (sent.cosigners[0] == guardianB && sent.cosigners[1] == guardianA),
            "cosigners must be the policy's guardians"
        );
    }

    function test_onlyPolicyAdminMayRequestKeygen() public {
        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.NotPolicyAdmin.selector, policyId, outsider));
        vm.prank(outsider);
        sender.requestKeygen(treasuryId);
    }

    function test_keygenRefusedOnceAnAccountIsBound() public {
        _bindAccount();

        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.AccountAlreadyBound.selector, treasuryId));
        vm.prank(admin);
        sender.requestKeygen(treasuryId);
    }

    // --- binding the keygen result ----------------------------------------

    function test_keygenResultBindsTheDerivedAccount() public {
        bytes32 id = _bindAccount();

        TreasuryRegistry.Treasury memory t = registry.getTreasury(treasuryId);
        assertEq(t.xrplAddress, CLASSIC);
        assertEq(t.xrplAccountId, bytes32(ripemd160(abi.encodePacked(sha256(PUBKEY)))));
        assertTrue(sender.getPending(id).consumed);
    }

    function test_secondBindingReverts() public {
        _bindAccount();

        vm.prank(admin);
        // A second keygen cannot even be requested, so drive the registry
        // directly through the sender's own path with a fresh instruction.
        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.AccountAlreadyBound.selector, treasuryId));
        sender.requestKeygen(treasuryId);
    }

    function test_bindingRejectsAnAddressThatDoesNotMatchTheKey() public {
        vm.prank(admin);
        sender.requestKeygen(treasuryId);
        bytes32 id = _lastInstructionId(bytes32("KEYGEN"));

        vm.expectRevert();
        vm.prank(submitter);
        sender.submitKeygenResult(id, PUBKEY, "rSomethingElseEntirely1234567890ab");
    }

    function test_onlyResultSubmitterMayRelay() public {
        vm.prank(admin);
        sender.requestKeygen(treasuryId);
        bytes32 id = _lastInstructionId(bytes32("KEYGEN"));

        vm.expectRevert(AegisInstructionSender.NotResultSubmitter.selector);
        vm.prank(outsider);
        sender.submitKeygenResult(id, PUBKEY, CLASSIC);
    }

    function test_unknownInstructionIsRefused() public {
        bytes32 bogus = keccak256("never dispatched");
        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.UnknownInstruction.selector, bogus));
        vm.prank(submitter);
        sender.submitKeygenResult(bogus, PUBKEY, CLASSIC);
    }

    function test_resultCannotBeReplayed() public {
        bytes32 id = _bindAccount();

        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.InstructionAlreadyConsumed.selector, id));
        vm.prank(submitter);
        sender.submitKeygenResult(id, PUBKEY, CLASSIC);
    }

    function test_resultMustAnswerTheCommandItWasSentFor() public {
        vm.prank(admin);
        sender.requestKeygen(treasuryId);
        bytes32 id = _lastInstructionId(bytes32("KEYGEN"));

        vm.expectRevert(
            abi.encodeWithSelector(AegisInstructionSender.WrongCommand.selector, bytes32("SIGNTX"), bytes32("KEYGEN"))
        );
        vm.prank(submitter);
        sender.submitSignatureResult(id, hex"1234", bytes32(uint256(1)));
    }

    // --- signature dispatch ------------------------------------------------

    function test_onlyPaymentControllerMayRequestASignature() public {
        IAegisInstructionSender.SignRequest memory req;
        address[] memory cosigners = new address[](0);

        vm.expectRevert(AegisInstructionSender.NotPaymentController.selector);
        vm.prank(outsider);
        sender.requestSignature(req, cosigners, 1);
    }

    function test_dispatchReachesTheTeeWithTheDigest() public {
        _bindAccount();
        uint256 requestId = _proposeApproveDispatch();

        TeeExtensionRegistryStub.Sent memory sent = extRegistry.lastSent();
        assertEq(sent.opType, bytes32("XRPLW"));
        assertEq(sent.opCommand, bytes32("SIGNTX"));

        IAegisInstructionSender.SignRequest memory decoded =
            abi.decode(sent.message, (IAegisInstructionSender.SignRequest));

        PaymentController.PaymentRequest memory r = controller.getRequest(requestId);
        assertEq(decoded.requestId, requestId);
        assertEq(decoded.treasuryId, treasuryId);
        assertEq(decoded.destinationAccountId, DEST);
        assertEq(decoded.amountDrops, r.amountDrops);
        assertEq(decoded.sequence, r.sequence);
        assertEq(decoded.policyDigest, r.policyDigest, "the enclave re-checks exactly this");
    }

    function test_dispatchCarriesGuardiansAndTheTierThreshold() public {
        _bindAccount();
        _proposeApproveDispatch();

        TeeExtensionRegistryStub.Sent memory sent = extRegistry.lastSent();
        assertEq(sent.cosigners.length, 2, "guardians are the FCC cosigners");
        assertEq(sent.cosignersThreshold, 1, "threshold is the tier's required approvals");
    }

    // --- signature result --------------------------------------------------

    function test_signatureResultPublishesTheBlob() public {
        _bindAccount();
        uint256 requestId = _proposeApproveDispatch();
        bytes32 id = _lastInstructionId(bytes32("SIGNTX"));

        bytes memory blob = hex"1200002400000001";
        bytes32 txHash = keccak256("tx");

        vm.expectEmit(true, false, false, true, address(controller));
        emit PaymentController.PaymentSigned(requestId, blob, txHash);

        vm.prank(submitter);
        sender.submitSignatureResult(id, blob, txHash);

        assertEq(uint8(controller.getRequest(requestId).state), uint8(PaymentController.RequestState.Signed));
    }

    function test_signatureResultCannotBeReplayed() public {
        _bindAccount();
        _proposeApproveDispatch();
        bytes32 id = _lastInstructionId(bytes32("SIGNTX"));

        vm.startPrank(submitter);
        sender.submitSignatureResult(id, hex"12", bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.InstructionAlreadyConsumed.selector, id));
        sender.submitSignatureResult(id, hex"12", bytes32(uint256(1)));
        vm.stopPrank();
    }

    // --- wiring ------------------------------------------------------------

    function test_collaboratorsAreWiredOnce() public {
        vm.expectRevert(AegisInstructionSender.AlreadyWired.selector);
        sender.setPaymentController(controller);

        vm.expectRevert(AegisInstructionSender.AlreadyWired.selector);
        sender.setResultSubmitter(submitter);
    }

    function test_onlyOwnerWires() public {
        AegisInstructionSender fresh = new AegisInstructionSender(extRegistry, machineRegistry, registry, policy);

        vm.expectRevert(AegisInstructionSender.NotOwner.selector);
        vm.prank(outsider);
        fresh.setResultSubmitter(outsider);
    }

    // --- guardian enumeration ---------------------------------------------

    function test_guardianListTracksRoleChanges() public {
        assertEq(policy.guardianCount(policyId), 2);

        uint8 approverOnly = policy.ROLE_APPROVER();
        vm.prank(admin);
        policy.setRoles(policyId, guardianA, approverOnly);
        assertEq(policy.guardianCount(policyId), 1);
        assertEq(policy.guardiansOf(policyId)[0], guardianB);

        uint8 guardianRole = policy.ROLE_GUARDIAN();
        vm.prank(admin);
        policy.setRoles(policyId, guardianA, guardianRole);
        assertEq(policy.guardianCount(policyId), 2);
    }

    function test_guardianIsNotDuplicatedByRepeatedGrants() public {
        uint8 guardianRole = policy.ROLE_GUARDIAN();
        vm.startPrank(admin);
        policy.setRoles(policyId, guardianA, guardianRole);
        policy.setRoles(policyId, guardianA, guardianRole);
        vm.stopPrank();

        assertEq(policy.guardianCount(policyId), 2);
    }

    // --- k-of-n ------------------------------------------------------------

    /// @dev The Go side asserts the same three strings. A drift in any of them
    /// surfaces as "unsupported op command" on a live instruction, which is a
    /// long way from the change that caused it.
    function test_kOfNOpCommandsAreTheExpectedStrings() public view {
        assertEq(sender.OP_COMMAND_SKEYGEN(), bytes32("SKEYGN"));
        assertEq(sender.OP_COMMAND_MSIGN(), bytes32("MSIGN"));
        assertEq(sender.OP_COMMAND_SETUP(), bytes32("SETUP"));
        assertEq(sender.SETUP_KIND_SIGNER_LIST(), KIND_SIGNER_LIST);
        assertEq(sender.SETUP_KIND_DISABLE_MASTER_KEY(), KIND_RETIRE);
    }

    function test_signerKeygenGoesToEveryMachineInTheSet() public {
        _configureSignerSet(2, 3);

        vm.prank(admin);
        sender.requestSignerKeygen(treasuryId);

        TeeExtensionRegistryStub.Sent memory sent = extRegistry.lastSent();
        assertEq(sent.opCommand, bytes32("SKEYGN"));
        assertEq(sent.message, abi.encode(treasuryId));
        assertEq(sent.teeIds.length, 3, "one machine per signer slot");
    }

    function test_signerKeygenNeedsAConfiguredSet() public {
        _bindAccount();
        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.SignerSetNotConfigured.selector, treasuryId));
        vm.prank(admin);
        sender.requestSignerKeygen(treasuryId);
    }

    function test_onlyPolicyAdminMayRequestSignerKeygen() public {
        _configureSignerSet(2, 3);
        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.NotPolicyAdmin.selector, policyId, outsider));
        vm.prank(outsider);
        sender.requestSignerKeygen(treasuryId);
    }

    /// @dev One instruction, n machines, n results. The pending record has to
    /// accept every one of them and then stop, which a consumed flag could not
    /// express.
    function test_oneSignerKeygenInstructionAcceptsOneResultPerMachine() public {
        _configureSignerSet(2, 3);

        vm.prank(admin);
        sender.requestSignerKeygen(treasuryId);
        bytes32 id = _lastInstructionId(bytes32("SKEYGN"));

        vm.startPrank(submitter);
        sender.submitSignerKeygenResult(id, SIGNER_A_KEY, SIGNER_A_ADDR);
        sender.submitSignerKeygenResult(id, SIGNER_B_KEY, SIGNER_B_ADDR);
        sender.submitSignerKeygenResult(id, SIGNER_C_KEY, SIGNER_C_ADDR);

        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.InstructionAlreadyConsumed.selector, id));
        sender.submitSignerKeygenResult(id, PUBKEY, CLASSIC);
        vm.stopPrank();

        assertEq(registry.signersOf(treasuryId).length, 3);
    }

    function test_setupInstructionCarriesTheSignerListAndItsDigest() public {
        _readySignerSet(2, 3);

        vm.prank(admin);
        sender.requestSetup(treasuryId, KIND_SIGNER_LIST, 7, 900_000, 12);

        TeeExtensionRegistryStub.Sent memory sent = extRegistry.lastSent();
        assertEq(sent.opCommand, bytes32("SETUP"));

        AegisInstructionSender.SetupRequest memory req = abi.decode(sent.message, (AegisInstructionSender.SetupRequest));
        assertEq(req.treasuryId, treasuryId);
        assertEq(req.kind, 0);
        assertEq(req.quorum, 2);
        assertEq(req.signerAccountIds.length, 3);
        assertEq(
            req.setupDigest,
            sender.setupDigest(treasuryId, 0, 2, req.signerAccountIds, 7, 900_000, 12),
            "the digest describes the fields that were sent"
        );
    }

    /// @dev The signer list comes from the registry, not the caller. Those keys
    /// were generated by enclaves and already verified against the addresses
    /// they claimed, so there is nothing here for a caller to choose.
    function test_setupRefusesTheSignerListStepBeforeTheSetIsFull() public {
        _configureSignerSet(2, 3);
        vm.expectRevert(
            abi.encodeWithSelector(
                AegisInstructionSender.SignerSetNotInState.selector,
                TreasuryRegistry.SignerSetState.Collecting,
                TreasuryRegistry.SignerSetState.Ready
            )
        );
        vm.prank(admin);
        sender.requestSetup(treasuryId, KIND_SIGNER_LIST, 7, 900_000, 12);
    }

    /// @dev Retiring the master key before the list is live would leave an
    /// account nothing could sign for.
    function test_setupRefusesRetirementBeforeTheListIsLive() public {
        _readySignerSet(2, 3);
        vm.expectRevert(
            abi.encodeWithSelector(
                AegisInstructionSender.SignerSetNotInState.selector,
                TreasuryRegistry.SignerSetState.Ready,
                TreasuryRegistry.SignerSetState.Installed
            )
        );
        vm.prank(admin);
        sender.requestSetup(treasuryId, KIND_RETIRE, 8, 900_000, 12);
    }

    function test_retirementCarriesNoSignerList() public {
        _installSignerSet(2, 3);

        vm.prank(admin);
        sender.requestSetup(treasuryId, KIND_RETIRE, 8, 900_000, 12);

        AegisInstructionSender.SetupRequest memory req =
            abi.decode(extRegistry.lastSent().message, (AegisInstructionSender.SetupRequest));
        assertEq(req.kind, 1);
        assertEq(req.quorum, 0);
        assertEq(req.signerAccountIds.length, 0, "a retirement takes no signer list");
    }

    function test_setupRefusesAnUnknownKind() public {
        _readySignerSet(2, 3);
        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.UnknownSetupKind.selector, uint8(7)));
        vm.prank(admin);
        sender.requestSetup(treasuryId, 7, 7, 900_000, 12);
    }

    function test_setupRefusesATransactionThatCouldNeverExpire() public {
        _readySignerSet(2, 3);
        vm.expectRevert(AegisInstructionSender.LastLedgerSequenceRequired.selector);
        vm.prank(admin);
        sender.requestSetup(treasuryId, KIND_SIGNER_LIST, 7, 0, 12);
    }

    function test_setupResultPublishesTheSignedTransaction() public {
        _readySignerSet(2, 3);

        vm.prank(admin);
        sender.requestSetup(treasuryId, KIND_SIGNER_LIST, 7, 900_000, 12);
        bytes32 id = _lastInstructionId(bytes32("SETUP"));

        bytes memory blob = hex"12000C220001000024000000012023000000";
        vm.expectEmit(true, true, false, true);
        emit AegisInstructionSender.SetupTransactionSigned(id, treasuryId, 0, blob, keccak256(blob));
        vm.prank(submitter);
        sender.submitSetupResult(id, 0, blob, keccak256(blob));
    }

    /// @dev Only one machine holds the master key, so one accepted result is the
    /// whole outcome and a second would be a replay rather than a contribution.
    function test_setupResultCannotBeReplayed() public {
        _readySignerSet(2, 3);

        vm.prank(admin);
        sender.requestSetup(treasuryId, KIND_SIGNER_LIST, 7, 900_000, 12);
        bytes32 id = _lastInstructionId(bytes32("SETUP"));

        vm.startPrank(submitter);
        sender.submitSetupResult(id, 0, hex"1200", bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(AegisInstructionSender.InstructionAlreadyConsumed.selector, id));
        sender.submitSetupResult(id, 0, hex"1200", bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_dispatchToAQuorumSendsOneInstructionToEveryMachine() public {
        _installSignerSet(2, 3);
        uint256 requestId = _proposeApproveDispatch();

        TeeExtensionRegistryStub.Sent memory sent = extRegistry.lastSent();
        assertEq(sent.opCommand, bytes32("MSIGN"));
        assertEq(sent.teeIds.length, 3);

        IAegisInstructionSender.MultiSignRequest memory req =
            abi.decode(sent.message, (IAegisInstructionSender.MultiSignRequest));
        assertEq(req.requestId, requestId);
        assertEq(req.sourceAccountId, registry.getTreasury(treasuryId).xrplAccountId);
        assertEq(
            req.multiSignDigest,
            controller.multiSignDigest(req.policyDigest, req.sourceAccountId),
            "both digests travel with the instruction"
        );
    }

    function test_partialSignatureResultsReachTheController() public {
        _installSignerSet(2, 3);
        uint256 requestId = _proposeApproveDispatch();
        bytes32 id = _lastInstructionId(bytes32("MSIGN"));

        vm.startPrank(submitter);
        sender.submitPartialSignatureResult(id, SIGNER_A_KEY, SIGNATURE);
        sender.submitPartialSignatureResult(id, SIGNER_B_KEY, SIGNATURE);
        vm.stopPrank();

        assertEq(controller.partialSignatureCount(requestId), 2);
        assertTrue(controller.getRequest(requestId).state == PaymentController.RequestState.Signed);
    }

    function test_onlyTheResultSubmitterRelaysPartialSignatures() public {
        _installSignerSet(2, 3);
        _proposeApproveDispatch();
        bytes32 id = _lastInstructionId(bytes32("MSIGN"));

        vm.expectRevert(AegisInstructionSender.NotResultSubmitter.selector);
        vm.prank(outsider);
        sender.submitPartialSignatureResult(id, SIGNER_A_KEY, SIGNATURE);
    }

    function test_aPartialSignatureCannotAnswerAKeygenInstruction() public {
        _configureSignerSet(2, 3);
        vm.prank(admin);
        sender.requestSignerKeygen(treasuryId);
        bytes32 id = _lastInstructionId(bytes32("SKEYGN"));

        vm.expectRevert(
            abi.encodeWithSelector(AegisInstructionSender.WrongCommand.selector, bytes32("MSIGN"), bytes32("SKEYGN"))
        );
        vm.prank(submitter);
        sender.submitPartialSignatureResult(id, SIGNER_A_KEY, SIGNATURE);
    }

    // --- helpers -----------------------------------------------------------

    function _configureSignerSet(uint8 quorum, uint8 signerCount) private {
        if (registry.getTreasury(treasuryId).xrplAccountId == bytes32(0)) _bindAccount();
        vm.prank(admin);
        registry.configureSignerSet(treasuryId, quorum, signerCount);
    }

    function _readySignerSet(uint8 quorum, uint8 signerCount) private {
        _configureSignerSet(quorum, signerCount);

        vm.prank(admin);
        sender.requestSignerKeygen(treasuryId);
        bytes32 id = _lastInstructionId(bytes32("SKEYGN"));

        bytes[3] memory keys = [SIGNER_A_KEY, SIGNER_B_KEY, SIGNER_C_KEY];
        string[3] memory addrs = [SIGNER_A_ADDR, SIGNER_B_ADDR, SIGNER_C_ADDR];
        vm.startPrank(submitter);
        for (uint8 i = 0; i < signerCount; ++i) {
            sender.submitSignerKeygenResult(id, keys[i], addrs[i]);
        }
        vm.stopPrank();
    }

    function _installSignerSet(uint8 quorum, uint8 signerCount) private {
        _readySignerSet(quorum, signerCount);
        vm.prank(admin);
        registry.confirmSignerListInstalled(treasuryId, keccak256("installed"));
    }

    function _bindAccount() private returns (bytes32 id) {
        vm.prank(admin);
        sender.requestKeygen(treasuryId);
        id = _lastInstructionId(bytes32("KEYGEN"));

        vm.prank(submitter);
        sender.submitKeygenResult(id, PUBKEY, CLASSIC);
    }

    /// @dev The stub derives instruction ids from a nonce, so this reproduces
    /// the id of the most recent send.
    function _lastInstructionId(bytes32 opCommand) private view returns (bytes32) {
        return keccak256(abi.encode(extRegistry.sentCount(), opCommand));
    }

    function _proposeApproveDispatch() private returns (uint256 requestId) {
        // A payment needs a bound account and a recorded starting sequence. Set
        // up here rather than in setUp, so the keygen and binding tests can
        // still observe a treasury that has neither.
        if (registry.getTreasury(treasuryId).xrplAccountId == bytes32(0)) _bindAccount();
        if (registry.nextSequenceOf(treasuryId) == 0) {
            vm.prank(admin);
            registry.setInitialSequence(treasuryId, START_SEQUENCE);
        }

        vm.prank(proposer);
        requestId = controller.propose(treasuryId, DEST, 0, 1_000_000);
        vm.prank(approverA);
        controller.approve(requestId);
        vm.prank(proposer);
        controller.dispatch(requestId, 899_990, 900_000, 12);
    }
}
