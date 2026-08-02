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
