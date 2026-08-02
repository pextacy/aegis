// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PaymentController} from "../contracts/PaymentController.sol";
import {PolicyEngine} from "../contracts/PolicyEngine.sol";
import {TreasuryRegistry} from "../contracts/TreasuryRegistry.sol";
import {FtsoStub} from "./helpers/Doubles.sol";

/// @notice Pins the policy digest across the Solidity/Go boundary.
/// @dev The enclave recomputes this digest from the fields it decoded and
/// refuses to sign on a mismatch. If either side's encoding drifts, every
/// payment fails with "policy digest mismatch" — which looks like a bug and is
/// the system working. This test and TestPolicyDigestMatchesSolidity in
/// pkg/types assert the same constant for the same inputs, so a one-sided change
/// fails here instead of on a live chain.
contract PolicyDigestTest is Test {
    PaymentController internal controller;

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

    function setUp() public {
        PolicyEngine policy = new PolicyEngine();
        TreasuryRegistry registry = new TreasuryRegistry(policy);
        controller = new PaymentController(policy, registry, new FtsoStub());
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
            REQUEST_ID, TREASURY_ID, DESTINATION, DESTINATION_TAG, AMOUNT_DROPS, SEQUENCE, LAST_LEDGER_SEQUENCE, FEE_DROPS
        );
        bytes32 swappedIds = controller.policyDigest(
            TREASURY_ID, REQUEST_ID, DESTINATION, DESTINATION_TAG, AMOUNT_DROPS, SEQUENCE, LAST_LEDGER_SEQUENCE, FEE_DROPS
        );
        bytes32 swappedSequences = controller.policyDigest(
            REQUEST_ID, TREASURY_ID, DESTINATION, DESTINATION_TAG, AMOUNT_DROPS, LAST_LEDGER_SEQUENCE, SEQUENCE, FEE_DROPS
        );

        assertTrue(normal != swappedIds, "swapping requestId and treasuryId must change the digest");
        assertTrue(normal != swappedSequences, "swapping the two sequences must change the digest");
    }

    function test_everyFieldAffectsTheDigest() public view {
        bytes32 base = controller.policyDigest(
            REQUEST_ID, TREASURY_ID, DESTINATION, DESTINATION_TAG, AMOUNT_DROPS, SEQUENCE, LAST_LEDGER_SEQUENCE, FEE_DROPS
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
