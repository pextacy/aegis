package types

import (
	"encoding/hex"
	"math/big"
	"strings"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// The same fixed vector test/PolicyDigest.t.sol encodes. Both sides assert the
// same result, so an encoding change on one side fails here rather than turning
// every payment on a live chain into "policy digest mismatch".
var digestVector = SignRequest{
	RequestId:            big.NewInt(42),
	TreasuryId:           big.NewInt(7),
	DestinationAccountId: leftAligned("AED2ACA19C6F54926F8482648A694E7CB62BAA22"),
	DestinationTag:       12345,
	AmountDrops:          1_500_000,
	Sequence:             9,
	LastLedgerSequence:   987_654,
	FeeDrops:             12,
}

const expectedDigest = "bf9544486a0a268526568626764bcc310b3cb2d08054e4d4a328f55032a0b921"

func leftAligned(hexBytes string) [32]byte {
	raw, err := hex.DecodeString(hexBytes)
	if err != nil {
		panic(err)
	}
	var out [32]byte
	copy(out[:], raw)
	return out
}

// TestPolicyDigestMatchesSolidity is the cross-boundary guard. Its counterpart
// is test_digestMatchesTheCrossLanguageVector in test/PolicyDigest.t.sol.
func TestPolicyDigestMatchesSolidity(t *testing.T) {
	req := digestVector

	got, err := req.ComputePolicyDigest()
	if err != nil {
		t.Fatalf("ComputePolicyDigest: %v", err)
	}

	if hex.EncodeToString(got[:]) != expectedDigest {
		t.Fatalf(
			"digest disagrees with Solidity\n got: %s\nwant: %s\n"+
				"If this changed deliberately, PaymentController._policyDigest, this "+
				"encoding and the decoder registration must all change in the same commit.",
			hex.EncodeToString(got[:]), expectedDigest,
		)
	}
}

func TestDigestMatchesAcceptsTheContractsOwnDigest(t *testing.T) {
	req := digestVector
	digest, err := req.ComputePolicyDigest()
	if err != nil {
		t.Fatalf("computing: %v", err)
	}
	req.PolicyDigest = digest

	ok, err := req.DigestMatches()
	if err != nil {
		t.Fatalf("DigestMatches: %v", err)
	}
	if !ok {
		t.Fatal("a request carrying its own digest was rejected")
	}
}

func TestDigestMatchesRejectsEveryTamperedField(t *testing.T) {
	alterations := map[string]func(*SignRequest){
		"requestId":            func(r *SignRequest) { r.RequestId = big.NewInt(43) },
		"treasuryId":           func(r *SignRequest) { r.TreasuryId = big.NewInt(8) },
		"destinationAccountId": func(r *SignRequest) { r.DestinationAccountId[0] ^= 0xFF },
		"destinationTag":       func(r *SignRequest) { r.DestinationTag++ },
		"amountDrops":          func(r *SignRequest) { r.AmountDrops++ },
		"sequence":             func(r *SignRequest) { r.Sequence++ },
		"lastLedgerSequence":   func(r *SignRequest) { r.LastLedgerSequence++ },
		"feeDrops":             func(r *SignRequest) { r.FeeDrops++ },
	}

	for name, alter := range alterations {
		t.Run(name, func(t *testing.T) {
			req := digestVector
			digest, err := req.ComputePolicyDigest()
			if err != nil {
				t.Fatalf("computing: %v", err)
			}
			req.PolicyDigest = digest

			alter(&req)

			ok, err := req.DigestMatches()
			if err != nil {
				t.Fatalf("DigestMatches: %v", err)
			}
			if ok {
				t.Fatalf("a tampered %s still matched the digest", name)
			}
		})
	}
}

// TestRequestReferenceMatchesAbiEncode pins the memo value ExecutionVerifier
// matches against the FDC payment reference.
func TestRequestReferenceMatchesAbiEncode(t *testing.T) {
	got, err := RequestReference(big.NewInt(42))
	if err != nil {
		t.Fatalf("RequestReference: %v", err)
	}

	// keccak256(abi.encode(uint256(42))) — a uint256 encodes to a single
	// right-aligned 32-byte word, so this is the hash of that word.
	var word [32]byte
	word[31] = 42
	want := common.Bytes2Hex(crypto.Keccak256(word[:]))

	if !strings.EqualFold(common.Bytes2Hex(got[:]), want) {
		t.Fatalf("reference\n got: %s\nwant: %s", common.Bytes2Hex(got[:]), want)
	}
}

func TestRequestReferenceRejectsNil(t *testing.T) {
	if _, err := RequestReference(nil); err == nil {
		t.Fatal("a nil request id was accepted")
	}
}

func TestPolicyDigestTreatsNilIdsAsZero(t *testing.T) {
	// A decoder that dropped a field would leave a nil big.Int. Producing a
	// digest for it rather than panicking keeps the failure on the comparison,
	// where it is reported as a mismatch rather than a crashed handler.
	req := SignRequest{}
	if _, err := req.ComputePolicyDigest(); err != nil {
		t.Fatalf("ComputePolicyDigest on a zero request: %v", err)
	}
}

// The k-of-n vectors test/PolicyDigest.t.sol encodes. Both sides assert the
// same constants, so a one-sided change to either digest fails here instead of
// turning every k-of-n payment into a refusal on a live chain.
var (
	multiSignSource = [32]byte{
		0x84, 0x21, 0xA3, 0x54, 0x6B, 0xBE, 0x20, 0xC5, 0x9C, 0x18,
		0xC9, 0xD0, 0x3C, 0x3E, 0xD1, 0x46, 0xE9, 0x67, 0x52, 0x0B,
	}
	setupSignerOne = [32]byte{
		0xEE, 0x21, 0x83, 0x94, 0xF5, 0x28, 0x74, 0x1B, 0x2D, 0xE1,
		0xFF, 0x8B, 0x99, 0x22, 0xC2, 0xB2, 0xDF, 0x23, 0xF4, 0xFB,
	}
	setupSignerTwo = [32]byte{
		0xE6, 0xDE, 0xED, 0x4E, 0xC3, 0xC9, 0x3A, 0xB5, 0x2C, 0x53,
		0x34, 0xF3, 0x3E, 0x64, 0x57, 0x75, 0xFD, 0x5F, 0x58, 0xD7,
	}
)

const (
	expectedMultiSignDigest = "0xf72558001d479890c6a830285ee3d13df88671423a9a94213eb36f5833f2e2f9"
	expectedSetupDigest     = "0x1cb7850138053ccbe26d4df387f1135b1fb11befb902c98f963b2430c4ae45f0"
)

// multiSignVector is the digest vector's payment, carried in the k-of-n shape.
func multiSignVector(t *testing.T) MultiSignRequest {
	t.Helper()

	policy, err := digestVector.ComputePolicyDigest()
	if err != nil {
		t.Fatalf("ComputePolicyDigest: %v", err)
	}

	return MultiSignRequest{
		RequestId:            digestVector.RequestId,
		TreasuryId:           digestVector.TreasuryId,
		SourceAccountId:      multiSignSource,
		DestinationAccountId: digestVector.DestinationAccountId,
		DestinationTag:       digestVector.DestinationTag,
		AmountDrops:          digestVector.AmountDrops,
		Sequence:             digestVector.Sequence,
		LastLedgerSequence:   digestVector.LastLedgerSequence,
		FeeDrops:             digestVector.FeeDrops,
		PolicyDigest:         policy,
	}
}

// TestMultiSignDigestMatchesSolidity is the cross-boundary guard for the digest
// that binds a payment to the account it leaves. Its counterpart is
// test_multiSignDigestMatchesTheCrossLanguageVector.
func TestMultiSignDigestMatchesSolidity(t *testing.T) {
	req := multiSignVector(t)

	got, err := req.ComputeMultiSignDigest()
	if err != nil {
		t.Fatalf("ComputeMultiSignDigest: %v", err)
	}

	if want := common.HexToHash(expectedMultiSignDigest); common.BytesToHash(got[:]) != want {
		t.Fatalf(
			"multi-sign digest disagrees with Solidity\n got: %s\nwant: %s\n"+
				"one side's encoding has drifted; both must change together",
			common.BytesToHash(got[:]).Hex(), want.Hex(),
		)
	}
}

// TestMultiSignDigestRejectsAnotherAccount is the failing half: a payment
// redirected at a different treasury account must not match. Without this the
// binding would be decorative.
func TestMultiSignDigestRejectsAnotherAccount(t *testing.T) {
	req := multiSignVector(t)
	digest, err := req.ComputeMultiSignDigest()
	if err != nil {
		t.Fatalf("ComputeMultiSignDigest: %v", err)
	}
	req.MultiSignDigest = digest

	ok, err := req.MultiSignDigestMatches()
	if err != nil {
		t.Fatalf("MultiSignDigestMatches: %v", err)
	}
	if !ok {
		t.Fatal("a request carrying its own digest was rejected")
	}

	req.SourceAccountId = setupSignerOne
	ok, err = req.MultiSignDigestMatches()
	if err != nil {
		t.Fatalf("MultiSignDigestMatches: %v", err)
	}
	if ok {
		t.Fatal("a payment pointed at another account still matched its digest")
	}
}

// TestSetupDigestMatchesSolidity is the cross-boundary guard for the digest an
// enclave recomputes before installing a signer list. Its counterpart is
// test_setupDigestMatchesTheCrossLanguageVector.
func TestSetupDigestMatchesSolidity(t *testing.T) {
	req := SetupRequest{
		TreasuryId:         digestVector.TreasuryId,
		Kind:               SetupKindSignerList,
		Quorum:             2,
		SignerAccountIds:   [][32]byte{setupSignerOne, setupSignerTwo},
		Sequence:           digestVector.Sequence,
		LastLedgerSequence: digestVector.LastLedgerSequence,
		FeeDrops:           digestVector.FeeDrops,
	}

	got, err := req.ComputeSetupDigest()
	if err != nil {
		t.Fatalf("ComputeSetupDigest: %v", err)
	}

	if want := common.HexToHash(expectedSetupDigest); common.BytesToHash(got[:]) != want {
		t.Fatalf(
			"setup digest disagrees with Solidity\n got: %s\nwant: %s\n"+
				"one side's encoding has drifted; both must change together",
			common.BytesToHash(got[:]).Hex(), want.Hex(),
		)
	}
}

// TestSetupDigestCoversTheWholeSignerList is the tamper this check exists for:
// a relayer adding one account, and so writing itself into every future quorum.
func TestSetupDigestCoversTheWholeSignerList(t *testing.T) {
	req := SetupRequest{
		TreasuryId:         digestVector.TreasuryId,
		Kind:               SetupKindSignerList,
		Quorum:             2,
		SignerAccountIds:   [][32]byte{setupSignerOne, setupSignerTwo},
		Sequence:           digestVector.Sequence,
		LastLedgerSequence: digestVector.LastLedgerSequence,
		FeeDrops:           digestVector.FeeDrops,
	}
	digest, err := req.ComputeSetupDigest()
	if err != nil {
		t.Fatalf("ComputeSetupDigest: %v", err)
	}
	req.SetupDigest = digest

	tampered := []struct {
		name   string
		mutate func(*SetupRequest)
	}{
		{"one signer added", func(s *SetupRequest) {
			s.SignerAccountIds = append([][32]byte{}, append(s.SignerAccountIds, multiSignSource)...)
		}},
		{"the signers reordered", func(s *SetupRequest) {
			s.SignerAccountIds = [][32]byte{setupSignerTwo, setupSignerOne}
		}},
		{"the quorum lowered", func(s *SetupRequest) { s.Quorum = 1 }},
		{"a different kind", func(s *SetupRequest) { s.Kind = SetupKindDisableMasterKey }},
		{"a different treasury", func(s *SetupRequest) { s.TreasuryId = big.NewInt(999) }},
		{"a different sequence", func(s *SetupRequest) { s.Sequence++ }},
		{"a later expiry", func(s *SetupRequest) { s.LastLedgerSequence++ }},
		{"a raised fee", func(s *SetupRequest) { s.FeeDrops++ }},
	}

	for _, tc := range tampered {
		t.Run(tc.name, func(t *testing.T) {
			altered := req
			tc.mutate(&altered)

			ok, err := altered.DigestMatches()
			if err != nil {
				t.Fatalf("DigestMatches: %v", err)
			}
			if ok {
				t.Fatalf("a setup request with %s still matched its digest", tc.name)
			}
		})
	}
}
