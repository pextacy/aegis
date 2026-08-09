// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PaymentController} from "../contracts/PaymentController.sol";
import {PolicyEngine} from "../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../contracts/TreasuryRegistry.sol";
import {AegisInstructionSender} from "../contracts/AegisInstructionSender.sol";
import {FtsoStub} from "./helpers/Doubles.sol";
import {TeeExtensionRegistryStub, TeeMachineRegistryStub} from "./helpers/TeeDoubles.sol";

/// @notice Pins the policy digest across the Solidity/Go boundary.
/// @dev The enclave recomputes this digest from the fields it decoded and
/// refuses to sign on a mismatch. If either side's encoding drifts, every
/// payment fails with "policy digest mismatch" — which looks like a bug and is
/// the system working. This test and TestPolicyDigestMatchesSolidity in
/// pkg/types assert the same constant for the same inputs, so a one-sided change
/// fails here instead of on a live chain.
contract PolicyDigestTest is Test {
    PaymentController internal controller;
    AegisInstructionSender internal sender;

    // The fixed vector both sides encode.
    uint256 constant REQUEST_ID = 42;
    uint256 constant TREASURY_ID = 7;
    bytes32 constant DESTINATION = bytes32(bytes20(hex"AED2ACA19C6F54926F8482648A694E7CB62BAA22"));
    uint32 constant DESTINATION_TAG = 12345;
    uint64 constant AMOUNT_DROPS = 1_500_000;
    uint32 constant SEQUENCE = 9;
    uint32 constant LAST_LEDGER_SEQUENCE = 987_654;
    uint64 constant FEE_DROPS = 12;

    /// @dev Recorded from this contract and asserted identically in Go.
    bytes32 constant EXPECTED = 0xbf9544486a0a268526568626764bcc310b3cb2d08054e4d4a328f55032a0b921;

    /// @dev The k-of-n vectors. `SOURCE` is the treasury's own AccountID, which
    /// only the multi-signing path needs to bind, and the two signers are the
    /// real XRPL accounts of the reference signer list.
    bytes32 constant SOURCE = bytes32(bytes20(hex"8421A3546BBE20C59C18C9D03C3ED146E967520B"));
    bytes32 constant SIGNER_ONE = bytes32(bytes20(hex"EE218394F528741B2DE1FF8B9922C2B2DF23F4FB"));
    bytes32 constant SIGNER_TWO = bytes32(bytes20(hex"E6DEED4EC3C93AB52C5334F33E645775FD5F58D7"));
    uint8 constant SETUP_KIND = 0;
    uint32 constant QUORUM = 2;

    /// @dev Recorded from these contracts and asserted identically in Go.
    bytes32 constant EXPECTED_MULTISIGN = 0xf72558001d479890c6a830285ee3d13df88671423a9a94213eb36f5833f2e2f9;
    bytes32 constant EXPECTED_SETUP = 0x1cb7850138053ccbe26d4df387f1135b1fb11befb902c98f963b2430c4ae45f0;

    function setUp() public {
        PolicyEngine policy = new PolicyEngine();
        TreasuryRegistry registry = new TreasuryRegistry(policy);
        controller = new PaymentController(policy, registry, new FtsoStub());
        sender =
            new AegisInstructionSender(new TeeExtensionRegistryStub(), new TeeMachineRegistryStub(), registry, policy);
    }

    /// @dev The digest that binds a payment's policy digest to the account it is
    /// authorised to leave. An enclave holding only a signer key cannot know
    /// that account from its own state, so the two sides must agree exactly or
    /// no k-of-n payment is ever signed.
    function test_multiSignDigestMatchesTheCrossLanguageVector() public view {
        bytes32 digest = controller.multiSignDigest(EXPECTED, SOURCE);
        console.logBytes32(digest);
        assertEq(digest, EXPECTED_MULTISIGN, "the Go side asserts this same value");
    }

    /// @dev Changing the account has to change the digest, or the binding is
    /// decorative and a payment could be redirected to another signer list.
    function test_multiSignDigestBindsTheAccount() public view {
        bytes32 elsewhere = bytes32(bytes20(hex"350F40A56D86D57ED58408028117B8F29A99281C"));
        assertTrue(
            controller.multiSignDigest(EXPECTED, SOURCE) != controller.multiSignDigest(EXPECTED, elsewhere),
            "two accounts produced the same digest"
        );
    }

    /// @dev The digest an enclave recomputes before signing a signer list.
    function test_setupDigestMatchesTheCrossLanguageVector() public view {
        bytes32[] memory signers = new bytes32[](2);
        signers[0] = SIGNER_ONE;
        signers[1] = SIGNER_TWO;

        bytes32 digest =
            sender.setupDigest(TREASURY_ID, SETUP_KIND, QUORUM, signers, SEQUENCE, LAST_LEDGER_SEQUENCE, FEE_DROPS);
        console.logBytes32(digest);
        assertEq(digest, EXPECTED_SETUP, "the Go side asserts this same value");
    }

    /// @dev Adding a signer has to change the digest. This is the exact tamper
    /// the check exists for: a relayer writing itself into every future quorum.
    function test_setupDigestCoversEverySigner() public view {
        bytes32[] memory two = new bytes32[](2);
        two[0] = SIGNER_ONE;
        two[1] = SIGNER_TWO;

        bytes32[] memory three = new bytes32[](3);
        three[0] = SIGNER_ONE;
        three[1] = SIGNER_TWO;
        three[2] = SOURCE;

        assertTrue(
            sender.setupDigest(TREASURY_ID, SETUP_KIND, QUORUM, two, SEQUENCE, LAST_LEDGER_SEQUENCE, FEE_DROPS)
                != sender.setupDigest(
                    TREASURY_ID, SETUP_KIND, QUORUM, three, SEQUENCE, LAST_LEDGER_SEQUENCE, FEE_DROPS
                ),
            "an extra signer left the digest unchanged"
        );
    }

    /// @dev And so does the order they are in, because the enclave sorts them
    /// but hashes what it was sent.
    function test_setupDigestCoversTheSignerOrder() public view {
        bytes32[] memory forward = new bytes32[](2);
        forward[0] = SIGNER_ONE;
        forward[1] = SIGNER_TWO;

        bytes32[] memory backward = new bytes32[](2);
        backward[0] = SIGNER_TWO;
        backward[1] = SIGNER_ONE;

        assertTrue(
            sender.setupDigest(TREASURY_ID, SETUP_KIND, QUORUM, forward, SEQUENCE, LAST_LEDGER_SEQUENCE, FEE_DROPS)
                != sender.setupDigest(
                    TREASURY_ID, SETUP_KIND, QUORUM, backward, SEQUENCE, LAST_LEDGER_SEQUENCE, FEE_DROPS
                ),
            "reordering the signers left the digest unchanged"
        );
    }

    function test_digestMatchesTheCrossLanguageVector() public view {
        bytes32 digest = controller.policyDigest(
            REQUEST_ID,
            TREASURY_ID,
            DESTINATION,
            DESTINATION_TAG,
            AMOUNT_DROPS,
            SEQUENCE,
            LAST_LEDGER_SEQUENCE,
            FEE_DROPS
        );
        console.logBytes32(digest);
        assertEq(digest, EXPECTED, "the Go side asserts this same value for these same fields");
    }

    /// @dev Field order is part of the digest. Swapping two values of the same
    /// width has to change it, or a reordering on one side would go unnoticed.
    function test_fieldOrderIsLoadBearing() public view {
        bytes32 normal = controller.policyDigest(
            REQUEST_ID,
            TREASURY_ID,
            DESTINATION,
            DESTINATION_TAG,
            AMOUNT_DROPS,
            SEQUENCE,
            LAST_LEDGER_SEQUENCE,
            FEE_DROPS
        );
        bytes32 swappedIds = controller.policyDigest(
            TREASURY_ID,
            REQUEST_ID,
            DESTINATION,
            DESTINATION_TAG,
            AMOUNT_DROPS,
            SEQUENCE,
            LAST_LEDGER_SEQUENCE,
            FEE_DROPS
        );
        bytes32 swappedSequences = controller.policyDigest(
            REQUEST_ID,
            TREASURY_ID,
            DESTINATION,
            DESTINATION_TAG,
            AMOUNT_DROPS,
            LAST_LEDGER_SEQUENCE,
            SEQUENCE,
            FEE_DROPS
        );

        assertTrue(normal != swappedIds, "swapping requestId and treasuryId must change the digest");
        assertTrue(normal != swappedSequences, "swapping the two sequences must change the digest");
    }

    function test_everyFieldAffectsTheDigest() public view {
        bytes32 base = controller.policyDigest(
            REQUEST_ID,
            TREASURY_ID,
            DESTINATION,
            DESTINATION_TAG,
            AMOUNT_DROPS,
            SEQUENCE,
            LAST_LEDGER_SEQUENCE,
            FEE_DROPS
        );

        assertTrue(
            base
                != controller.policyDigest(
                    REQUEST_ID + 1,
                    TREASURY_ID,
                    DESTINATION,
                    DESTINATION_TAG,
                    AMOUNT_DROPS,
                    SEQUENCE,
                    LAST_LEDGER_SEQUENCE,
                    FEE_DROPS
                ),
            "requestId"
        );
        assertTrue(
            base
                != controller.policyDigest(
                    REQUEST_ID,
                    TREASURY_ID,
                    bytes32(uint256(DESTINATION) ^ 1),
                    DESTINATION_TAG,
                    AMOUNT_DROPS,
                    SEQUENCE,
                    LAST_LEDGER_SEQUENCE,
                    FEE_DROPS
                ),
            "destination"
        );
        assertTrue(
            base
                != controller.policyDigest(
                    REQUEST_ID,
                    TREASURY_ID,
                    DESTINATION,
                    DESTINATION_TAG,
                    AMOUNT_DROPS + 1,
                    SEQUENCE,
                    LAST_LEDGER_SEQUENCE,
                    FEE_DROPS
                ),
            "amount"
        );
        assertTrue(
            base
                != controller.policyDigest(
                    REQUEST_ID,
                    TREASURY_ID,
                    DESTINATION,
                    DESTINATION_TAG,
                    AMOUNT_DROPS,
                    SEQUENCE,
                    LAST_LEDGER_SEQUENCE,
                    FEE_DROPS + 1
                ),
            "fee"
        );
    }
}
