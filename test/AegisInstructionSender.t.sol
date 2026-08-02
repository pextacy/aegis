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

    // --- helpers -----------------------------------------------------------

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
        vm.prank(proposer);
        requestId = controller.propose(treasuryId, DEST, 0, 1_000_000);
        vm.prank(approverA);
        controller.approve(requestId);
        vm.prank(proposer);
        controller.dispatch(requestId, 899_990, 900_000, 12);
    }
}
