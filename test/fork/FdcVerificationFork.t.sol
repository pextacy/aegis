// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ExecutionVerifier} from "../../contracts/ExecutionVerifier.sol";
import {PaymentController} from "../../contracts/PaymentController.sol";
import {PolicyEngine} from "../../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../../contracts/TreasuryRegistry.sol";
import {IAegisInstructionSender} from "../../contracts/interfaces/IAegisInstructionSender.sol";
import {IFdcVerification} from "../../contracts/interfaces/IFdcVerification.sol";
import {IFtsoV2} from "../../contracts/interfaces/IFtsoV2.sol";
import {IPayment} from "../../contracts/interfaces/IPayment.sol";

/// @title FdcVerificationFork
/// @notice Checks Aegis' FDC proof encoding against Flare's real verifier.
///
/// @dev Every other settlement test runs against a double that we wrote, which
/// means they prove ExecutionVerifier is self-consistent and nothing about
/// whether Flare agrees. The risk that leaves is specific and total: the Merkle
/// leaf is `keccak256(abi.encode(Response))`, so if our locally-declared
/// IPayment structs differ from Flare's by one field, one order or one width,
/// every real proof is rejected and settlement can never complete. Nothing in
/// the offline suite can see that, because both sides of it are ours.
///
/// So this deploys against the real FdcVerification on a Coston2 fork and lets
/// Flare's own code compute the leaf from a Response we encoded.
///
/// One thing is substituted, and only one: the Relay, which is where
/// FdcVerification reads the round's finalised root. It is replaced with eleven
/// bytes that return storage slot zero, so the test can put a chosen root
/// there. That is a root *oracle*, not the verification — the leaf hashing, the
/// Merkle walk, the attestation-type and source handling all remain Flare's.
/// The substitution is here because this file drives settlement end to end
/// through ExecutionVerifier, which needs a response describing *our own*
/// payment, and getting one of those into a voting round needs the FDC verifier
/// API key.
///
/// For the narrower question — does Flare's verifier accept this encoding
/// against a root Flare itself finalised — see RealAttestationFork.t.sol. It
/// pins a real Payment attestation read from public sources and substitutes
/// nothing at all.
///
/// Skipped unless COSTON2_RPC_URL is set, so the offline suite stays offline.
///
///   COSTON2_RPC_URL=https://coston2-api.flare.network/ext/C/rpc \
///     forge test --match-contract FdcVerificationFork -vv
contract FdcVerificationForkTest is Test {
    // Coston2 system contracts, from config/coston2/deployed-addresses.json.
    address constant FDC_VERIFICATION = 0x906507E0B64bcD494Db73bd0459d1C667e14B933;
    address constant RELAY = 0xa10B672D1c62e5457b17af63d4302add6A99d7dE;
    address constant FTSO_V2 = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d;

    /// @dev Returns storage slot 0 for any calldata:
    /// PUSH1 0 SLOAD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
    bytes constant ROOT_ORACLE = hex"60005460005260206000f3";

    // A real XRPL Testnet payment this system produced and settled. Keeping the
    // real values means the encoding is exercised against numbers a ledger
    // actually recorded rather than round ones chosen to be convenient.
    bytes32 constant TX_ID = 0xE82AA92EE82F483F80D23EE486C985E36B597E2FB907FC39216A9E297271D059;
    string constant TREASURY_ADDR = "rp7AGkpBQuQcEqcVTuphwmhe9oUnxibrtp";
    string constant DEST_ADDR = "r9adtULnuhrainVukgPUw63jXmdFZPCMCL";
    bytes constant TREASURY_PUBKEY = hex"02915E517D0395E48CCAD8991569A306D63511AF179313566B309B61AABE751E6F";
    uint64 constant AMOUNT_DROPS = 1_000_000;
    uint64 constant FEE_DROPS = 12;
    uint32 constant DEST_TAG = 7;
    uint32 constant START_SEQUENCE = 19_574_774;
    uint32 constant LEDGER = 19_574_777;

    PolicyEngine policy;
    TreasuryRegistry registry;
    PaymentController controller;
    ExecutionVerifier verifier;

    address admin = address(this);
    address approver = address(0xA11CE);

    uint256 treasuryId;
    uint256 requestId;
    bytes32 destAccountId;

    function setUp() public {
        string memory rpc = vm.envOr("COSTON2_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        policy = new PolicyEngine();
        registry = new TreasuryRegistry(policy);
        controller = new PaymentController(policy, registry, IFtsoV2(FTSO_V2));
        verifier = new ExecutionVerifier(controller, registry, IFdcVerification(FDC_VERIFICATION));

        registry.setInstructionSender(address(this));
        registry.setExecutionVerifier(address(verifier));
        controller.setInstructionSender(IAegisInstructionSender(address(this)));
        controller.setExecutionVerifier(address(verifier));

        PolicyEngine.Tier[] memory tiers = new PolicyEngine.Tier[](1);
        tiers[0] = PolicyEngine.Tier({maxAmountUsd: 100_000e18, requiredApprovals: 1, timelockSeconds: 0});
        uint256 policyId = policy.createPolicy(tiers, 50_000e18, 30 days, true, 1, 0);
        policy.setRoles(policyId, admin, policy.ROLE_POLICY_ADMIN() | policy.ROLE_PROPOSER());
        policy.setRoles(policyId, approver, policy.ROLE_APPROVER());

        treasuryId = registry.createTreasury(policyId);
        registry.bindXrplAccount(treasuryId, TREASURY_PUBKEY, TREASURY_ADDR);
        registry.setInitialSequence(treasuryId, START_SEQUENCE);

        destAccountId = _accountIdOf(DEST_ADDR);
        policy.setAllowlist(policyId, destAccountId, DEST_TAG, true);

        requestId = controller.propose(treasuryId, destAccountId, DEST_TAG, AMOUNT_DROPS);
        vm.prank(approver);
        controller.approve(requestId);
        controller.dispatch(requestId, LEDGER - 2, LEDGER + 40, FEE_DROPS);
        controller.recordSignature(requestId, hex"1200", TX_ID);
    }

    /// @dev The whole point. Flare's verifier recomputes the leaf from our
    /// Response; if our struct layout disagreed with theirs by a single field
    /// the root would not match and this would revert ProofNotVerified.
    function test_flaresVerifierAcceptsOurPaymentEncoding() public {
        if (_skip()) return;

        IPayment.Proof memory proof = _paymentProof(0, AMOUNT_DROPS + FEE_DROPS, int256(uint256(AMOUNT_DROPS)));
        _publishRoot(proof);

        assertTrue(
            IFdcVerification(FDC_VERIFICATION).verifyPayment(proof),
            "Flare's FdcVerification rejected a leaf built from our IPayment structs"
        );
    }

    function test_settlementCompletesThroughTheRealVerifier() public {
        if (_skip()) return;

        IPayment.Proof memory proof = _paymentProof(0, AMOUNT_DROPS + FEE_DROPS, int256(uint256(AMOUNT_DROPS)));
        _publishRoot(proof);

        verifier.confirmSettlement(requestId, proof);

        assertEq(
            uint8(controller.getRequest(requestId).state),
            uint8(PaymentController.RequestState.Settled),
            "the request did not reach Settled"
        );
        assertEq(registry.nextSequenceOf(treasuryId), START_SEQUENCE + 1, "the sequence did not advance");
    }

    /// @dev A leaf Flare did not attest must fail against Flare's own check,
    /// not merely against ours. Altering the response after the root is
    /// published is the honest way to ask that.
    function test_theRealVerifierRejectsATamperedResponse() public {
        if (_skip()) return;

        IPayment.Proof memory proof = _paymentProof(0, AMOUNT_DROPS + FEE_DROPS, int256(uint256(AMOUNT_DROPS)));
        _publishRoot(proof);

        proof.data.responseBody.receivedAmount = int256(uint256(AMOUNT_DROPS)) * 1000;

        assertFalse(
            IFdcVerification(FDC_VERIFICATION).verifyPayment(proof),
            "Flare's verifier accepted a response altered after attestation"
        );
        vm.expectRevert(ExecutionVerifier.ProofNotVerified.selector);
        verifier.confirmSettlement(requestId, proof);
    }

    // --- helpers -----------------------------------------------------------

    /// @dev This contract stands in for the instruction sender so dispatch can
    /// complete. Nothing here is under test — the enclave path is covered by
    /// scripts/local-integration.sh against the real Go process, and what this
    /// file exists to check is the FDC encoding on the other side of the
    /// lifecycle.
    function requestSignature(IAegisInstructionSender.SignRequest calldata, address[] calldata, uint8)
        external
        payable {}

    /// @dev vm.skip rather than an early return, so an unrun test reports as
    /// skipped instead of as passing. A green tick that only means "no RPC was
    /// configured" is worse than no test at all.
    function _skip() private returns (bool skipped) {
        skipped = address(verifier) == address(0);
        vm.skip(skipped, "COSTON2_RPC_URL is not set");
    }

    /// @dev Puts the proof's own leaf where FdcVerification will look for the
    /// round's root. The Merkle proof is empty, so for a single-leaf tree the
    /// root is the leaf.
    function _publishRoot(IPayment.Proof memory proof) private {
        vm.etch(RELAY, ROOT_ORACLE);
        vm.store(RELAY, bytes32(uint256(0)), keccak256(abi.encode(proof.data)));
    }

    function _paymentProof(uint8 status, uint256 spent, int256 received)
        private
        view
        returns (IPayment.Proof memory proof)
    {
        proof.merkleProof = new bytes32[](0);
        proof.data.attestationType = bytes32("Payment");
        proof.data.sourceId = bytes32("testXRP");
        proof.data.votingRound = 1_000_000;
        proof.data.lowestUsedTimestamp = 1;
        proof.data.requestBody = IPayment.RequestBody({transactionId: TX_ID, inUtxo: 0, utxo: 0});
        proof.data.responseBody = IPayment.ResponseBody({
            blockNumber: LEDGER,
            blockTimestamp: 1,
            sourceAddressHash: keccak256(abi.encode(TREASURY_ADDR)),
            sourceAddressesRoot: bytes32(0),
            receivingAddressHash: keccak256(abi.encode(DEST_ADDR)),
            intendedReceivingAddressHash: keccak256(abi.encode(DEST_ADDR)),
            spentAmount: int256(spent),
            intendedSpentAmount: int256(spent),
            receivedAmount: received,
            intendedReceivedAmount: received,
            standardPaymentReference: verifier.requestReference(requestId),
            oneToOne: true,
            status: status
        });
    }

    /// @dev base58check decode of a classic address, left-aligned into a word.
    function _accountIdOf(string memory addr) private pure returns (bytes32) {
        bytes memory alphabet = bytes("rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz");
        bytes memory input = bytes(addr);
        uint8[] memory digits = new uint8[](25);
        uint256 length = 1;

        for (uint256 i = 0; i < input.length; ++i) {
            uint256 carry = 0;
            for (uint256 j = 0; j < alphabet.length; ++j) {
                if (alphabet[j] == input[i]) {
                    carry = j;
                    break;
                }
            }
            for (uint256 k = 0; k < length; ++k) {
                carry += uint256(digits[k]) * 58;
                digits[k] = uint8(carry & 0xff);
                carry >>= 8;
            }
            while (carry > 0) {
                digits[length++] = uint8(carry & 0xff);
                carry >>= 8;
            }
        }

        // digits holds the number little-endian; the AccountID is bytes 1..20 of
        // the 25-byte big-endian payload.
        bytes20 accountId;
        for (uint256 i = 0; i < 20; ++i) {
            accountId |= bytes20(bytes1(digits[23 - i])) >> (i * 8);
        }
        return bytes32(accountId);
    }
}
