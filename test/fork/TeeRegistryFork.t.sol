// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AegisInstructionSender} from "../../contracts/AegisInstructionSender.sol";
import {PaymentController} from "../../contracts/PaymentController.sol";
import {PolicyEngine} from "../../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../../contracts/TreasuryRegistry.sol";
import {ITeeExtensionRegistry} from "../../contracts/interfaces/ITeeExtensionRegistry.sol";
import {ITeeMachineRegistry} from "../../contracts/interfaces/ITeeMachineRegistry.sol";
import {IFtsoV2} from "../../contracts/interfaces/IFtsoV2.sol";

/// @dev The registration entry point, which the scaffold's Go tooling calls and
/// no Aegis contract does. Declared here rather than in contracts/ because
/// nothing Aegis ships needs it — registration is a deployment step.
interface ITeeExtensionRegistration {
    function register(address _stateVerifier, address _instructionsSender) external returns (uint256 _extensionId);
}

/// @title TeeRegistryFork
/// @notice Checks the FCC extension registration and discovery path against
/// Flare's real TEE manager.
///
/// @dev ITeeExtensionRegistry and ITeeMachineRegistry are declared locally,
/// because flare-smart-contracts-v2 is not published as a package. Every
/// offline test of them therefore runs against stubs we wrote, which can only
/// show that Aegis agrees with itself. A wrong selector or return type would
/// not fail at deploy — it would fail on the first instruction, in production.
///
/// So this registers the real AegisInstructionSender against the real
/// FlareTeeManager on a Coston2 fork. Nothing is substituted: registration is
/// permissionless, and the ids handed out are the real counter's.
///
/// Two things it does not do. It does not run `setExtensionId()`, whose scan
/// walks every public extension on the chain and would fetch several hundred
/// storage slots over RPC per call — the public endpoint answers that with an
/// HTTP 429, and the cost of that loop is a real limitation recorded in the
/// README rather than hidden behind a test that cannot run. And it cannot
/// register a TEE machine, which needs a real attestation, so `getRandomTeeIds`
/// has nothing to return; the test pins that the failure is the real contract
/// refusing on its own terms rather than an interface mismatch, which is the
/// half that is ours to get wrong.
///
/// Skipped unless COSTON2_RPC_URL is set.
contract TeeRegistryForkTest is Test {
    address constant FLARE_TEE_MANAGER = 0x1a9C4A0f9D76c0b1D91d22E24E573a9b377618aE;
    address constant FTSO_V2 = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d;
    uint256 constant FIRST_PUBLIC_EXTENSION_ID = 0x10000;

    PolicyEngine policy;
    TreasuryRegistry registry;
    PaymentController controller;
    AegisInstructionSender sender;

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
    }

    /// @dev The interface Aegis declares locally must match the deployed one.
    /// A wrong selector or return type here does not fail loudly at deploy — it
    /// fails on the first instruction, in production.
    function test_theRealRegistryMatchesOurInterface() public {
        if (_skip()) return;

        uint256 next = ITeeExtensionRegistry(FLARE_TEE_MANAGER).nextPublicExtensionId();
        assertGt(next, FIRST_PUBLIC_EXTENSION_ID, "the real registry has no public extensions");

        // A registered id resolves to a contract, which is what the scan reads.
        address existing =
            ITeeExtensionRegistry(FLARE_TEE_MANAGER).getTeeExtensionInstructionsSender(FIRST_PUBLIC_EXTENSION_ID);
        assertTrue(existing != address(0), "extension 0x10000 resolves to nothing on the real registry");
    }

    /// @dev Registration itself, against the real contract: the id it hands out
    /// is a public one, it is the counter's previous value, and the registry
    /// points it at our sender afterwards. That is everything `setExtensionId()`
    /// later looks for.
    ///
    /// The scan is deliberately not run here. It walks every public extension
    /// from FIRST_PUBLIC_EXTENSION_ID upward — several hundred on Coston2 today
    /// — and each iteration is a separate storage read the fork fetches over
    /// RPC, which earns an HTTP 429 from the public endpoint and would make this
    /// suite fail for reasons that have nothing to do with Aegis. The cost of
    /// that loop is a real limitation and is recorded in the README rather than
    /// pretended away here.
    function test_registrationAssignsAPublicIdPointingAtOurSender() public {
        if (_skip()) return;

        uint256 before = ITeeExtensionRegistry(FLARE_TEE_MANAGER).nextPublicExtensionId();

        uint256 assigned = ITeeExtensionRegistration(FLARE_TEE_MANAGER).register(address(controller), address(sender));
        assertGe(assigned, FIRST_PUBLIC_EXTENSION_ID, "the registry assigned a system-reserved id");
        assertEq(assigned, before, "the assigned id is not the previous nextPublicExtensionId");

        assertEq(
            ITeeExtensionRegistry(FLARE_TEE_MANAGER).getTeeExtensionInstructionsSender(assigned),
            address(sender),
            "the registry does not point the assigned id at our sender"
        );
    }

    /// @dev A second registration takes a new id while the TEE machine stays
    /// bound to the old one, which is the MachineManager.TooMany() that
    /// CLAUDE.md warns `pre-build.sh --force` causes. Pinned against the real
    /// contract rather than trusted from the warning.
    function test_registeringTwiceTakesADifferentId() public {
        if (_skip()) return;

        uint256 first = ITeeExtensionRegistration(FLARE_TEE_MANAGER).register(address(controller), address(sender));
        uint256 second = ITeeExtensionRegistration(FLARE_TEE_MANAGER).register(address(controller), address(sender));
        assertTrue(first != second, "the real registry reused an extension id");
        assertEq(second, first + 1, "ids are not handed out consecutively");
    }

    /// @dev No machine can be registered without a real attestation, so the
    /// selection has nothing to return. The point is that it fails there, in
    /// the real contract's own logic, rather than earlier on a bad interface.
    function test_machineSelectionFailsOnlyForWantOfAMachine() public {
        if (_skip()) return;

        uint256 assigned = ITeeExtensionRegistration(FLARE_TEE_MANAGER).register(address(controller), address(sender));

        try ITeeMachineRegistry(FLARE_TEE_MANAGER).getRandomTeeIds(assigned, 1) returns (address[] memory ids) {
            assertEq(ids.length, 0, "a machine appeared for an extension that never registered one");
        } catch (bytes memory reason) {
            // A custom error is the real contract refusing on its own terms. An
            // interface mismatch would surface as empty returndata instead.
            assertGe(reason.length, 4, "machine selection failed without a reason, which suggests a wrong interface");
        }
    }

    function _skip() private returns (bool skipped) {
        skipped = address(sender) == address(0);
        vm.skip(skipped, "COSTON2_RPC_URL is not set");
    }
}
