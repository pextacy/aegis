// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AegisInstructionSender} from "../contracts/AegisInstructionSender.sol";
import {PaymentController} from "../contracts/PaymentController.sol";
import {PolicyEngine} from "../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../contracts/TreasuryRegistry.sol";
import {IFtsoV2} from "../contracts/interfaces/IFtsoV2.sol";
import {ITeeExtensionRegistry} from "../contracts/interfaces/ITeeExtensionRegistry.sol";
import {ITeeMachineRegistry} from "../contracts/interfaces/ITeeMachineRegistry.sol";

/// @title DeployAegis
/// @notice Deploys the five Aegis contracts and wires them together.
/// @dev Deliberately separate from the scaffold's deploy-contract tool, which
/// stays untouched so the Hello World end-to-end path keeps working. Register
/// the address this prints with the scaffold's own tool:
///
///   go run ./cmd/register-extension -a <addresses> -c <rpc> \
///     --instructionSender <AEGIS_INSTRUCTION_SENDER>
///
/// System contract addresses come from config/coston2/deployed-addresses.json
/// while FCC is in development. When they move to FlareContractRegistry, this
/// script is the one place that changes.
contract DeployAegis is Script {
    function run() external {
        address ftso = vm.envAddress("FTSO_V2_ADDRESS");
        address teeExtensionRegistry = vm.envAddress("TEE_EXTENSION_REGISTRY_ADDRESS");
        address teeMachineRegistry = vm.envAddress("TEE_MACHINE_REGISTRY_ADDRESS");
        address resultSubmitter = vm.envAddress("RESULT_SUBMITTER_ADDRESS");

        vm.startBroadcast();

        PolicyEngine policy = new PolicyEngine();
        TreasuryRegistry registry = new TreasuryRegistry(policy);
        PaymentController controller = new PaymentController(policy, registry, IFtsoV2(ftso));

        AegisInstructionSender sender = new AegisInstructionSender(
            ITeeExtensionRegistry(teeExtensionRegistry), ITeeMachineRegistry(teeMachineRegistry), registry, policy
        );

        // Each of these is one-shot; a redeploy means new contracts, not a rewire.
        registry.setInstructionSender(address(sender));
        controller.setInstructionSender(sender);
        sender.setPaymentController(controller);
        sender.setResultSubmitter(resultSubmitter);

        vm.stopBroadcast();

        console.log("POLICY_ENGINE            ", address(policy));
        console.log("TREASURY_REGISTRY        ", address(registry));
        console.log("PAYMENT_CONTROLLER       ", address(controller));
        console.log("AEGIS_INSTRUCTION_SENDER ", address(sender));
        console.log("");
        console.log("Register the sender, then call setExtensionId() on it.");
        console.log("ExecutionVerifier is wired in phase 4:");
        console.log("  registry.setExecutionVerifier(<verifier>)");
        console.log("  controller.setExecutionVerifier(<verifier>)");
    }
}
