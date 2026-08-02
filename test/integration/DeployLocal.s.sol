// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AegisInstructionSender} from "../../contracts/AegisInstructionSender.sol";
import {PaymentController} from "../../contracts/PaymentController.sol";
import {PolicyEngine} from "../../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../../contracts/TreasuryRegistry.sol";
import {FtsoStub} from "../helpers/Doubles.sol";
import {TeeExtensionRegistryStub, TeeMachineRegistryStub} from "../helpers/TeeDoubles.sol";

/// @title DeployLocal
/// @notice Stands the whole system up on a local chain for the integration run.
/// @dev Lives under test/ and uses the test doubles deliberately: on a local
/// chain there are no Flare system contracts to talk to. What this exercises is
/// everything Aegis owns — the contracts, the real enclave process, and the
/// binding — against a real chain with real transactions. The only piece not
/// covered is Flare's own instruction relay, which needs Coston2.
///
/// The Coston2 deployment is script/DeployAegis.s.sol and uses the real
/// registries; the two are kept separate so a test double can never reach a
/// live network.
contract DeployLocal is Script {
    function run() external {
        vm.startBroadcast();

        FtsoStub ftso = new FtsoStub();
        TeeExtensionRegistryStub extRegistry = new TeeExtensionRegistryStub();
        TeeMachineRegistryStub machineRegistry = new TeeMachineRegistryStub();

        PolicyEngine policy = new PolicyEngine();
        TreasuryRegistry registry = new TreasuryRegistry(policy);
        PaymentController controller = new PaymentController(policy, registry, ftso);
        AegisInstructionSender sender = new AegisInstructionSender(extRegistry, machineRegistry, registry, policy);

        extRegistry.register(0x10001, address(sender));
        sender.setExtensionId();
        sender.setPaymentController(controller);
        sender.setResultSubmitter(msg.sender);

        registry.setInstructionSender(address(sender));
        controller.setInstructionSender(sender);

        // XRP at $0.50, six decimals, priced now. The integration script warps
        // nothing, so a fresh timestamp keeps the feed inside MAX_PRICE_AGE.
        ftso.set(500_000, 6, uint64(block.timestamp));

        vm.stopBroadcast();

        console.log("POLICY_ENGINE            ", address(policy));
        console.log("TREASURY_REGISTRY        ", address(registry));
        console.log("PAYMENT_CONTROLLER       ", address(controller));
        console.log("AEGIS_INSTRUCTION_SENDER ", address(sender));
        console.log("EXT_REGISTRY_STUB        ", address(extRegistry));
        console.log("FTSO_STUB                ", address(ftso));
    }
}
