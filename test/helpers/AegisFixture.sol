// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {PaymentController} from "../../contracts/PaymentController.sol";
import {PolicyEngine} from "../../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../../contracts/TreasuryRegistry.sol";
import {FtsoStub, SenderRecorder} from "./Doubles.sol";

/// @notice Shared deployment and a realistic three-tier policy.
/// @dev Prices XRP at $0.50 with 6 decimals, so 1 XRP is 0.5e18 USD and the
/// tier boundaries land on round XRP amounts, which keeps the boundary tests
/// readable rather than full of magic numbers.
abstract contract AegisFixture is Test {
    PolicyEngine internal policy;
    TreasuryRegistry internal registry;
    PaymentController internal controller;
    FtsoStub internal ftso;
    SenderRecorder internal sender;

    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal approverA = makeAddr("approverA");
    address internal approverB = makeAddr("approverB");
    address internal approverC = makeAddr("approverC");
    address internal guardian = makeAddr("guardian");
    address internal outsider = makeAddr("outsider");

    uint256 internal policyId;
    uint256 internal treasuryId;

    /// @dev $0.50 per XRP, 6 decimals.
    uint256 internal constant XRP_PRICE = 500_000;
    int8 internal constant XRP_DECIMALS = 6;

    uint128 internal constant TIER0_CAP = 1_000e18;
    uint128 internal constant TIER1_CAP = 10_000e18;
    uint128 internal constant TIER2_CAP = 100_000e18;
    uint128 internal constant WINDOW_CAP = 50_000e18;
    uint32 internal constant WINDOW_SECONDS = 30 days;
    uint8 internal constant AMEND_APPROVALS = 2;
    uint32 internal constant AMEND_TIMELOCK = 1 days;

    bytes32 internal constant DEST = bytes32(uint256(0xBEEF) << 96);
    bytes32 internal constant DEST_OTHER = bytes32(uint256(0xCAFE) << 96);

    /// @dev The XRPL genesis vector, reused so the binding is against real data.
    bytes internal constant PUBKEY = hex"0330E7FC9D56BB25D6893BA3F317AE5BCF33B3291BD63DB32654A313222F7FD020";
    string internal constant CLASSIC = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh";

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        policy = new PolicyEngine();
        registry = new TreasuryRegistry(policy);
        ftso = new FtsoStub();
        controller = new PaymentController(policy, registry, ftso);
        sender = new SenderRecorder();

        // This test contract wires the collaborators and stands in for the
        // instruction sender on the registry, so bindXrplAccount is reachable.
        registry.setInstructionSender(address(this));
        registry.setExecutionVerifier(address(this));
        controller.setInstructionSender(sender);
        controller.setExecutionVerifier(address(this));

        setPrice(XRP_PRICE, uint64(block.timestamp));

        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](3);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: TIER0_CAP, requiredApprovals: 1, timelockSeconds: 0});
        tiers[1] = PolicyEngine.Tier({maxAmountUsd: TIER1_CAP, requiredApprovals: 2, timelockSeconds: 1 hours});
        tiers[2] = PolicyEngine.Tier({maxAmountUsd: TIER2_CAP, requiredApprovals: 3, timelockSeconds: 24 hours});

        vm.prank(admin);
        policyId = policy.createPolicy(tiers, WINDOW_CAP, WINDOW_SECONDS, false, AMEND_APPROVALS, AMEND_TIMELOCK);

        vm.startPrank(admin);
        policy.setRoles(policyId, proposer, policy.ROLE_PROPOSER());
        policy.setRoles(policyId, approverA, policy.ROLE_APPROVER());
        policy.setRoles(policyId, approverB, policy.ROLE_APPROVER());
        policy.setRoles(policyId, approverC, policy.ROLE_APPROVER());
        policy.setRoles(policyId, guardian, policy.ROLE_GUARDIAN());
        treasuryId = registry.createTreasury(policyId);
        vm.stopPrank();

        registry.bindXrplAccount(treasuryId, PUBKEY, CLASSIC);
    }

    function setPrice(uint256 value, uint64 timestamp) internal {
        ftso.set(value, XRP_DECIMALS, timestamp);
    }

    /// @dev Drops that price to exactly `usd18` at the fixture price.
    function dropsForUsd(uint256 usd18) internal pure returns (uint64) {
        // usd18 = drops * XRP_PRICE * 10^(12 - 6)  =>  drops = usd18 / (XRP_PRICE * 1e6)
        return uint64(usd18 / (XRP_PRICE * 1e6));
    }

    /// @dev Proposes, collects `approvals` approvals, and returns the request id.
    function proposeAndApprove(uint64 amountDrops, uint8 approvals) internal returns (uint256 requestId) {
        vm.prank(proposer);
        requestId = controller.propose(treasuryId, DEST, 0, amountDrops);
        address[3] memory pool = [approverA, approverB, approverC];
        for (uint8 i = 0; i < approvals; ++i) {
            vm.prank(pool[i]);
            controller.approve(requestId);
        }
    }
}
