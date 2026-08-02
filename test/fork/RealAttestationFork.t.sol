// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IFdcVerification} from "../../contracts/interfaces/IFdcVerification.sol";
import {IPayment} from "../../contracts/interfaces/IPayment.sol";

/// @title RealAttestationFork
/// @notice Verifies a genuine, finalised FDC attestation through Flare's real
/// verifier, with nothing substituted.
///
/// @dev FdcVerificationFork.t.sol shows our IPayment structs produce the leaf
/// Flare computes, but it has to put the root where the verifier will read it,
/// because producing a *finalised* root means getting an attestation into a
/// voting round and that needs the FDC verifier API key.
///
/// The key turns out to be needed only for prepareRequest. Everything after it
/// is public: attestation requests are on-chain events on FdcHub, the DA layer
/// serves proofs without authentication, and finalised roots sit in Relay. So a
/// real request somebody else paid for can be read off the chain, its proof
/// fetched, and the whole thing checked against the root the network actually
/// finalised.
///
/// The proof below is a real Payment attestation on testXRP — the exact
/// attestation type and source id Aegis uses — requested in Coston2 block
/// 33546268 and finalised in voting round 1413928. Nothing is etched, stored
/// or stubbed: the root comes from Relay, the verification from FdcVerification,
/// the response bytes from the DA layer.
///
/// Pinned rather than fetched at test time, so the suite stays deterministic and
/// needs no HTTP client. Re-pinning means reading another AttestationRequest
/// event and asking the DA layer for its proof.
///
/// Skipped unless COSTON2_RPC_URL is set.
contract RealAttestationForkTest is Test {
    address constant FDC_VERIFICATION = 0x906507E0B64bcD494Db73bd0459d1C667e14B933;
    address constant RELAY = 0xa10B672D1c62e5457b17af63d4302add6A99d7dE;
    uint256 constant FDC_PROTOCOL_ID = 200;
    uint256 constant VOTING_ROUND = 1413928;

    /// @dev The ABI-encoded IPayment.Response exactly as the DA layer served it.
    bytes constant RESPONSE = hex"5061796d656e7400000000000000000000000000000000000000000000000000"
        hex"7465737458525000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000159328"
        hex"000000000000000000000000000000000000000000000000000000006a6f5e60"
        hex"0a6dc73391aa136be0b5c107768fd7a212cff9f5cb7c38de879565eadd177ae8"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"00000000000000000000000000000000000000000000000000000000012ab174"
        hex"000000000000000000000000000000000000000000000000000000006a6f5e60"
        hex"cdf609c7723cc941b27fc439a68854fe9741d6e2cf239172c74303f84d8c9124"
        hex"66366e68fa22710ed5127e9aab961014553325bb9a1d2573243c661e686b3693"
        hex"fc8233bc3943e56dab5d39223f6c6e907db043187d859c8509daf4631ee83a7e"
        hex"fc8233bc3943e56dab5d39223f6c6e907db043187d859c8509daf4631ee83a7e"
        hex"000000000000000000000000000000000000000000000000000000000001d8f0"
        hex"000000000000000000000000000000000000000000000000000000000001d8f0"
        hex"000000000000000000000000000000000000000000000000000000000001d8e6"
        hex"000000000000000000000000000000000000000000000000000000000001d8e6"
        hex"00f8000000000000000000060001000000000000000000000000000000000000"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000000000000000000";

    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("COSTON2_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
    }

    function _proof() private pure returns (IPayment.Proof memory proof) {
        bytes32[] memory siblings = new bytes32[](6);
        siblings[0] = 0x8a57a93226b841dc4e7684d314c845a0fec84a3c038297626f8fe9fd809a453e;
        siblings[1] = 0xd780f3b6884ab7b27e71ed3b518d22ca1e0f1ab8cb27d7b69990670a0f760c58;
        siblings[2] = 0x6017bf624d51e603a778960f521914e721bcd093b4744641be5a92a2b9e37011;
        siblings[3] = 0x62eadb77df8d1f78bf440550fd35ef6fdbc39b40fd215bc9cf62ef5132d3d73b;
        siblings[4] = 0xa06b1864d8637150005c2fe3d0f4d3442d30ed9f6e63d023bfac71b91d14a886;
        siblings[5] = 0x7d251ed1219f8c325f1cbacf6cce8d4084e5bb9ecdaf4a1fdb29f4d9050de635;
        proof.merkleProof = siblings;
        proof.data = abi.decode(RESPONSE, (IPayment.Response));
    }

    /// @dev The response the DA layer served really is our IPayment.Response. If
    /// the struct had drifted from Flare's, this decode would yield nonsense and
    /// these assertions would fail on values rather than on the proof.
    function test_theDaLayerResponseDecodesAsOurStruct() public {
        _skipUnlessForked();
        IPayment.Proof memory proof = _proof();

        assertEq(proof.data.attestationType, bytes32("Payment"), "not a Payment attestation");
        assertEq(proof.data.sourceId, bytes32("testXRP"), "not a testXRP attestation");
        assertEq(uint256(proof.data.votingRound), VOTING_ROUND, "the response carries a different voting round");
    }

    /// @dev The round really was finalised, on chain, by Flare.
    function test_theRoundIsFinalisedOnChain() public {
        _skipUnlessForked();
        (bool ok, bytes memory data) =
            RELAY.staticcall(abi.encodeWithSignature("merkleRoots(uint256,uint256)", FDC_PROTOCOL_ID, VOTING_ROUND));
        assertTrue(ok, "Relay call failed");
        assertTrue(abi.decode(data, (bytes32)) != bytes32(0), "no finalised root for that round");
    }

    /// @dev The whole point: Flare's verifier accepts a real attestation, read
    /// from public sources, against the root Flare itself finalised. No
    /// substitution anywhere in the path.
    function test_flaresVerifierAcceptsARealFinalisedAttestation() public {
        _skipUnlessForked();
        assertTrue(
            IFdcVerification(FDC_VERIFICATION).verifyPayment(_proof()),
            "the real verifier rejected a real finalised attestation"
        );
    }

    /// @dev And still rejects it once altered, so the test above is not merely
    /// asserting that verifyPayment returns true for anything handed to it.
    function test_itRejectsThatSameAttestationOnceAltered() public {
        _skipUnlessForked();
        IPayment.Proof memory proof = _proof();
        proof.data.responseBody.receivedAmount += 1;
        assertFalse(
            IFdcVerification(FDC_VERIFICATION).verifyPayment(proof), "the real verifier accepted an altered response"
        );
    }

    function _skipUnlessForked() private {
        vm.skip(!forked, "COSTON2_RPC_URL is not set");
    }
}
