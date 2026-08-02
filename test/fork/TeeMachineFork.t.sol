// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AegisInstructionSender} from "../../contracts/AegisInstructionSender.sol";
import {IAegisInstructionSender} from "../../contracts/interfaces/IAegisInstructionSender.sol";
import {PaymentController} from "../../contracts/PaymentController.sol";
import {PolicyEngine} from "../../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../../contracts/TreasuryRegistry.sol";
import {ITeeExtensionRegistry} from "../../contracts/interfaces/ITeeExtensionRegistry.sol";
import {ITeeMachineRegistry} from "../../contracts/interfaces/ITeeMachineRegistry.sol";
import {IFtsoV2} from "../../contracts/interfaces/IFtsoV2.sol";

/// @dev The deployment-time entry points on FlareTeeManager. None of these are
/// called by anything Aegis ships — they are what `pre-build.sh`, the scaffold's
/// Go tooling and `post-build.sh` do — so they are declared here rather than in
/// contracts/.
interface IFccDeployment {
    /// @dev bytes32 rather than uint256. The ABI encoding is identical, but the
    /// signature string is not, so the selector differs and the diamond answers
    /// FunctionNotFound — which is exactly how the first attempt failed.
    struct PublicKey {
        bytes32 x;
        bytes32 y;
    }

    struct TeeMachineData {
        uint256 extensionId;
        address initialOwner;
        bytes32 codeHash;
        bytes32 platform;
        PublicKey publicKey;
        bytes32 governanceHash;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function register(address _stateVerifier, address _instructionsSender) external returns (uint256 _extensionId);

    function setNewTeeGovernance(uint256 _extensionId, address[] calldata _signers, uint64 _threshold) external;

    function getLatestTeeGovernanceHash(uint256 _extensionId) external view returns (bytes32);

    function addTeeVersion(uint256 _extensionId, bytes32 _version, bytes32 _codeHash, bytes32[] calldata _platforms)
        external;

    /// @dev Per-extension, not chain-wide: whoever owns an extension decides who
    /// may run machines for it. Registration reverts OwnerNotAllowed() without
    /// this, which is how its absence first showed up.
    function addAllowedTeeMachineOwners(uint256 _extensionId, address[] calldata _owners) external;

    function isAllowedTeeMachineOwner(uint256 _extensionId, address _owner) external view returns (bool);

    function getTeeMachineOwner(address _teeId) external view returns (address);

    function getTeeMachineStatus(address _teeId) external view returns (uint8);

    function getExtensionId(address _teeId) external view returns (uint256);

    function register(
        TeeMachineData calldata _teeMachineData,
        Signature calldata _teeMachineDataSignature,
        address _teeProxyId,
        string calldata _url,
        address _claimBackAddress
    ) external payable;
}

/// @title TeeMachineFork
/// @notice Registers a TEE machine against the real FlareTeeManager and drives
/// a real instruction through it.
///
/// @dev This is the last piece of the FCC path that had never run against
/// anything but a stub: `AegisInstructionSender.requestSignature` calling
/// `sendInstructions` on Flare's registry with a machine selected by
/// `getRandomTeeIds`. Every offline test of it used TeeExtensionRegistryStub,
/// which accepts whatever we send.
///
/// It is worth being exact about what this does and does not prove, because
/// "registered a TEE machine" sounds like more than it is.
///
/// On-chain registration takes a machine record, a signature over it, an
/// allowlisted code hash and a matching governance hash. It does not take a
/// hardware attestation quote — the scaffold's own tooling says as much, logging
/// "Code hash is from proxy /info response — not independently verified against
/// attestation". The chain's gate is that the *extension owner* has allowlisted
/// that code hash for their own extension, which is a per-extension decision,
/// not a global one. So a test that registers its own extension, allowlists its
/// own code hash and registers a machine holding its own key is exercising the
/// real registration path rather than bypassing one.
///
/// What it proves: a machine registers against the real manager with a
/// signature the real contract verified, and `requestSignature` reaches machine
/// selection inside that contract. Everything up to that point — the extension
/// id, the sender authorisation, the instruction params, the fee — is right
/// against the deployed code rather than against a stub of ours.
///
/// What it does not prove, and this is the exact remaining boundary: a
/// registered machine is not a *selectable* one. `getRandomTeeIds` reads
/// `extensionActiveTeeIds`, which a machine only joins after `toProduction` is
/// called with an `ITeeAvailabilityCheck.Proof` — an FDC2 attestation that the
/// enclave answered a challenge. That needs a real attestation round, which
/// needs the FDC verifier credential. So both tests below that touch selection
/// assert `TooMany()`: one machine asked for, zero active.
///
/// Skipped unless COSTON2_RPC_URL is set.
contract TeeMachineForkTest is Test {
    address constant FLARE_TEE_MANAGER = 0x1a9C4A0f9D76c0b1D91d22E24E573a9b377618aE;
    address constant FTSO_V2 = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d;

    // A throwaway keypair standing in for the enclave's. The coordinates are the
    // uncompressed public key for this private key; `register` checks the
    // signature against them, so they have to agree.
    uint256 constant TEE_PRIVATE_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    bytes32 constant TEE_PUBKEY_X = 0xba5734d8f7091719471e7f7ed6b9df170dc70cc661ca05e688601ad984f068b0;
    bytes32 constant TEE_PUBKEY_Y = 0xd67351e5f06073092499336ab0839ef8a521afd334e53807205fa2f08eec74f4;

    /// @dev The simulated-TEE code hash the scaffold produces starts 0x194844cf.
    /// The exact value only has to match what this test allowlists for its own
    /// extension.
    bytes32 constant CODE_HASH = hex"194844cf00000000000000000000000000000000000000000000000000000000";
    /// @dev One of the platforms the registry recognises. The set is fixed —
    /// GCP_INTEL_TDX, GCP_AMD_SEV, GCP_AMD_SEV_ES and TEST_PLATFORM — and
    /// anything else is rejected by `addTeeVersion`, which is how the wrong
    /// value here first showed up.
    bytes32 constant PLATFORM = bytes32("TEST_PLATFORM");

    PolicyEngine policy;
    TreasuryRegistry registry;
    PaymentController controller;
    AegisInstructionSender sender;

    uint256 extensionId;
    bytes32 governanceHash;

    function setUp() public {
        string memory rpc = vm.envOr("COSTON2_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        policy = new PolicyEngine();
        registry = new TreasuryRegistry(policy);
        controller = new PaymentController(policy, registry, IFtsoV2(FTSO_V2));
        sender = new AegisInstructionSender(
            ITeeExtensionRegistry(FLARE_TEE_MANAGER), ITeeMachineRegistry(FLARE_TEE_MANAGER), registry, policy
        );

        vm.deal(address(this), 100 ether);

        extensionId = IFccDeployment(FLARE_TEE_MANAGER).register(address(controller), address(sender));

        // Governance: one signer, threshold one — the same default post-build.sh
        // and the TEE node both fall back to. Setting one side only is what
        // produces InvalidGovernanceHash.
        address[] memory signers = new address[](1);
        signers[0] = address(this);
        IFccDeployment(FLARE_TEE_MANAGER).setNewTeeGovernance(extensionId, signers, 1);
        governanceHash = IFccDeployment(FLARE_TEE_MANAGER).getLatestTeeGovernanceHash(extensionId);

        bytes32[] memory platforms = new bytes32[](1);
        platforms[0] = PLATFORM;
        IFccDeployment(FLARE_TEE_MANAGER).addTeeVersion(extensionId, bytes32("v0.1.0"), CODE_HASH, platforms);

        address[] memory owners = new address[](1);
        owners[0] = address(this);
        IFccDeployment(FLARE_TEE_MANAGER).addAllowedTeeMachineOwners(extensionId, owners);
    }

    function test_theExtensionOwnerControlsItsOwnMachineAllowlist() public {
        if (_skip()) return;
        assertTrue(
            IFccDeployment(FLARE_TEE_MANAGER).isAllowedTeeMachineOwner(extensionId, address(this)),
            "the real registry did not record the machine owner we allowed"
        );
    }

    function test_governanceHashIsRecordedForOurExtension() public {
        if (_skip()) return;
        assertTrue(governanceHash != bytes32(0), "the real registry recorded no governance hash");
    }

    /// @dev A machine registered against the real manager, with a signature the
    /// real contract verified. Getting here took the exact payload the chain
    /// expects — see the digest construction in `_registerMachine` — so this
    /// passing means our understanding of the registration contract is right,
    /// not merely that a transaction went through.
    function test_aMachineRegistersAgainstTheRealManager() public {
        if (_skip()) return;

        _registerMachine();
        address teeId = vm.addr(TEE_PRIVATE_KEY);

        assertEq(
            IFccDeployment(FLARE_TEE_MANAGER).getTeeMachineOwner(teeId),
            address(this),
            "the real manager did not record us as the machine owner"
        );
        assertEq(
            IFccDeployment(FLARE_TEE_MANAGER).getExtensionId(teeId),
            extensionId,
            "the machine was not bound to our extension"
        );
    }

    /// @dev And here is the boundary, named precisely.
    ///
    /// A registered machine is not yet a selectable one. `getRandomTeeIds`
    /// reads `extensionActiveTeeIds`, which a machine only joins once
    /// `toProduction` has been called with an `ITeeAvailabilityCheck.Proof` —
    /// an FDC2 attestation that the enclave answered a challenge. That proof
    /// needs a real attestation round, which is the credential this repository
    /// does not have.
    ///
    /// So the failure is `TooMany()`: one machine asked for, zero active. That
    /// is the whole of what is left unverified on the relay's contract side,
    /// and it is one call with one proof type rather than a vague gap.
    function test_selectionStillNeedsAnAvailabilityProvenMachine() public {
        if (_skip()) return;

        _registerMachine();

        vm.expectRevert(bytes4(keccak256("TooMany()")));
        ITeeMachineRegistry(FLARE_TEE_MANAGER).getRandomTeeIds(extensionId, 1);
    }

    /// @dev The whole point of the file: a real instruction, through the real
    /// FlareTeeManager, sent by the contract that does it in production.
    /// @dev The instruction path, against the real manager.
    function test_requestSignatureReachesMachineSelection() public {
        if (_skip()) return;

        _registerMachine();
        sender.setPaymentController(controller);
        sender.setResultSubmitter(address(this));

        // setExtensionId() is the production way in, and it scans every public
        // extension on the chain — several hundred storage reads the fork would
        // fetch one RPC round-trip at a time, which the public endpoint answers
        // with an HTTP 429. The scan is not what this test is about, so the id
        // is written straight to slot 0 (see forge inspect storage-layout).
        vm.store(address(sender), bytes32(uint256(0)), bytes32(extensionId));
        assertEq(sender.extensionId(), extensionId, "the extension id was not set");

        controller.setInstructionSender(sender);

        // Our instruction path reaches the real manager and gets as far as
        // machine selection, failing there for want of an availability-proven
        // machine rather than anywhere earlier. Everything before that point —
        // the extension id, the sender authorisation, the instruction params —
        // is therefore right against the real contract.
        //
        // A low-level call rather than vm.expectRevert: the revert comes back
        // through requestSignature at the same depth as the cheatcode, which
        // expectRevert refuses to match. Reading the returndata says exactly
        // which check fired, which is the point.
        // Under prank the value is drawn from the controller's balance, not the
        // test's, so it needs funding or the call dies OutOfFunds before it
        // reaches anything worth asserting.
        vm.deal(address(controller), 10 ether);

        vm.prank(address(controller));
        (bool ok, bytes memory reason) = address(sender).call{value: 1 ether}(
            abi.encodeCall(IAegisInstructionSender.requestSignature, (_signRequest(), new address[](0), 1))
        );

        assertFalse(ok, "an instruction succeeded with no availability-proven machine");
        assertEq(bytes4(reason), bytes4(keccak256("TooMany()")), "the call failed before reaching machine selection");
    }

    // --- helpers -----------------------------------------------------------

    function _registerMachine() private {
        IFccDeployment.TeeMachineData memory data = IFccDeployment.TeeMachineData({
            extensionId: extensionId,
            initialOwner: address(this),
            codeHash: CODE_HASH,
            platform: PLATFORM,
            publicKey: IFccDeployment.PublicKey({x: TEE_PUBKEY_X, y: TEE_PUBKEY_Y}),
            governanceHash: governanceHash
        });

        // MachineManagerFacet.register recovers with
        //   ECDSA.recover(SignedPayload.ethSignedHash(TEE_MACHINE_REGISTER,
        //                                             keccak256(abi.encode(data))), v, r, s)
        // and go-flare-common's signing.Payload shows what that expands to: a
        // (prefix, chainId, dataHash) tuple, keccak'd, then EIP-191 prefixed.
        //
        // The chain id is in there deliberately — it is what stops a machine
        // registration signed for one network from being replayed on another.
        // Getting any layer of this wrong recovers a valid but different
        // address and fails InvalidTeePublicKeyOrSignature(), which is what
        // every earlier attempt did. v stays 27/28: OpenZeppelin's ECDSA
        // rejects 0/1 outright with ECDSAInvalidSignature().
        bytes32 payloadHash =
            keccak256(abi.encode(bytes32("TEE_MACHINE_REGISTER"), uint256(block.chainid), keccak256(abi.encode(data))));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEE_PRIVATE_KEY, digest);

        IFccDeployment(FLARE_TEE_MANAGER).register{value: 1 gwei}(
            data,
            IFccDeployment.Signature({v: v, r: r, s: s}),
            vm.addr(TEE_PRIVATE_KEY),
            "https://example.invalid",
            address(this)
        );
    }

    /// @dev Field values do not matter here — the enclave is what checks them
    /// against the policy digest, and that is covered by
    /// scripts/local-integration.sh against the real Go process. What is under
    /// test is that the instruction is accepted by the real registry at all.
    function _signRequest() private pure returns (IAegisInstructionSender.SignRequest memory) {
        return IAegisInstructionSender.SignRequest({
            requestId: 1,
            treasuryId: 1,
            destinationAccountId: bytes32(uint256(1) << 96),
            destinationTag: 7,
            amountDrops: 1_000_000,
            sequence: 19_574_774,
            lastLedgerSequence: 19_574_817,
            feeDrops: 12,
            policyDigest: keccak256("digest")
        });
    }

    function _skip() private returns (bool skipped) {
        skipped = address(sender) == address(0);
        vm.skip(skipped, "COSTON2_RPC_URL is not set");
    }
}
