package extension

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"testing"

	"extension-scaffold/internal/config"
	"extension-scaffold/pkg/types"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
)

// TestGenerateConformanceFixtures rewrites testdata/conformance for the Aegis
// wire contract, replacing the scaffold's Hello World set.
//
// It is a test rather than a command so it can reuse the real encoders, and it
// is opt-in so a normal `go test ./...` does not rewrite committed fixtures:
//
//	AEGIS_GEN_FIXTURES=1 go test ./internal/extension -run GenerateConformance
//
// Every expectation below is written out by hand, not recorded from a run. A
// fixture copied from the output it is meant to check would pin whatever the
// code happens to do, which is the opposite of the point.
func TestGenerateConformanceFixtures(t *testing.T) {
	if os.Getenv("AEGIS_GEN_FIXTURES") != "1" {
		t.Skip("set AEGIS_GEN_FIXTURES=1 to rewrite testdata/conformance")
	}

	dir, err := filepath.Abs("../../../testdata/conformance")
	if err != nil {
		t.Fatalf("resolving fixture directory: %v", err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("fixture directory: %v", err)
	}

	fixtures := aegisFixtures(t)

	// Remove the scaffold's Hello World fixtures; they describe an extension
	// that no longer exists.
	existing, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	for _, f := range existing {
		if filepath.Base(f) == "index.json" {
			continue
		}
		if err := os.Remove(f); err != nil {
			t.Fatalf("removing %s: %v", f, err)
		}
	}

	names := make([]string, 0, len(fixtures))
	for _, f := range fixtures {
		name := f["name"].(string)
		body, err := json.MarshalIndent(f, "", "  ")
		if err != nil {
			t.Fatalf("encoding %s: %v", name, err)
		}
		if err := os.WriteFile(filepath.Join(dir, name+".json"), append(body, '\n'), 0o644); err != nil {
			t.Fatalf("writing %s: %v", name, err)
		}
		names = append(names, name)
	}

	index, _ := json.MarshalIndent(map[string]any{"fixtures": names}, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, "index.json"), append(index, '\n'), 0o644); err != nil {
		t.Fatalf("writing index: %v", err)
	}

	t.Logf("wrote %d fixtures to %s", len(names), dir)
}

const fixtureActionID = "0x" + "11111111111111111111111111111111" + "11111111111111111111111111111111"

func b32String(s string) string {
	b := make([]byte, 32)
	copy(b, s)
	return "0x" + hex.EncodeToString(b)
}

func toHexString(b []byte) string {
	return "0x" + hex.EncodeToString(b)
}

// fixtureAction mirrors the body tee-node posts to /action.
func fixtureAction(opType, opCommand string, original []byte) map[string]any {
	dataFixed := map[string]any{
		"instructionId":          fixtureActionID,
		"teeId":                  "0x" + hex.EncodeToString(make([]byte, 20)),
		"timestamp":              1700000000,
		"rewardEpochId":          42,
		"opType":                 b32String(opType),
		"opCommand":              b32String(opCommand),
		"cosigners":              []string{},
		"cosignersThreshold":     0,
		"originalMessage":        toHexString(original),
		"additionalFixedMessage": "0x",
	}
	message, _ := json.Marshal(dataFixed)

	return map[string]any{
		"data": map[string]any{
			"id":            fixtureActionID,
			"type":          "instruction",
			"submissionTag": "submit",
			"message":       toHexString(message),
		},
		"additionalVariableMessages": []any{},
		"timestamps":                 []any{},
		"additionalActionData":       "0x",
		"signatures":                 []any{},
	}
}

func aegisFixtures(t *testing.T) []map[string]any {
	t.Helper()

	treasury := func(id int64) []byte {
		encoded, err := types.TreasuryIdArgs.Pack(big.NewInt(id))
		if err != nil {
			t.Fatalf("packing treasury id: %v", err)
		}
		return encoded
	}

	signRequest := func(req types.SignRequest) []byte {
		encoded, err := abi.Arguments{types.SignRequestArg}.Pack(req)
		if err != nil {
			t.Fatalf("packing sign request: %v", err)
		}
		return encoded
	}

	var dest [32]byte
	copy(dest[:], common.FromHex("0xAED2ACA19C6F54926F8482648A694E7CB62BAA22"))

	base := types.SignRequest{
		RequestId:            big.NewInt(42),
		TreasuryId:           big.NewInt(1),
		DestinationAccountId: dest,
		DestinationTag:       7,
		AmountDrops:          1_000_000,
		Sequence:             3,
		LastLedgerSequence:   900_000,
		FeeDrops:             12,
	}
	honest := base
	digest, err := honest.ComputePolicyDigest()
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	honest.PolicyDigest = digest

	// The same fields with a digest that does not describe them — exactly what a
	// relayer that altered the payload would produce.
	tampered := honest
	tampered.AmountDrops = honest.AmountDrops * 10

	statusAbsent, err := types.StatusResponseArgs.Pack(false, uint32(0))
	if err != nil {
		t.Fatalf("packing status: %v", err)
	}
	statusPresent, err := types.StatusResponseArgs.Pack(true, honest.Sequence)
	if err != nil {
		t.Fatalf("packing status: %v", err)
	}

	okResult := func(command string) map[string]any {
		return map[string]any{
			"status":    1,
			"log":       "ok",
			"opType":    b32String(config.OPTypeXRPL),
			"opCommand": b32String(command),
		}
	}

	return []map[string]any{
		{
			"name":        "01-keygen-success",
			"description": "KEYGEN generates a treasury key in the enclave and reports status 1",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, config.OPCommandKeygen, treasury(1)),
			},
			// The key is random, so the response data cannot be pinned. What is
			// pinned is that the operation succeeds and identifies itself.
			"expect": map[string]any{"status": 200, "json_subset": okResult(config.OPCommandKeygen)},
		},
		{
			"name":        "02-keygen-refused-when-a-key-exists",
			"description": "A second KEYGEN never replaces a live key, which would strand the XRP already sent to it",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, config.OPCommandKeygen, treasury(1)),
			},
			"expect": map[string]any{
				"status":      200,
				"json_subset": map[string]any{"status": 0, "data": "0x"},
				"log_prefix":  "error: ",
			},
		},
		{
			"name":        "03-keygen-rejects-zero-treasury-id",
			"description": "Treasury id zero is not a treasury",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, config.OPCommandKeygen, treasury(0)),
			},
			"expect": map[string]any{
				"status":      200,
				"json_subset": map[string]any{"status": 0, "data": "0x"},
				"log_prefix":  "error: ",
			},
		},
		{
			"name":        "04-status-reports-no-key",
			"description": "STATUS for an ungenerated treasury reports (false, 0)",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, config.OPCommandStatus, treasury(99)),
			},
			"expect": map[string]any{
				"status": 200,
				"json_subset": map[string]any{
					"status": 1, "log": "ok", "data": toHexString(statusAbsent),
				},
			},
		},
		{
			"name":        "05-signtx-digest-mismatch",
			"description": "Fields that do not hash to the digest the contract computed are refused, and nothing is signed",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, config.OPCommandSignTx, signRequest(tampered)),
			},
			"expect": map[string]any{
				"status": 200,
				"json_subset": map[string]any{
					"status": 0,
					"data":   "0x",
					"log":    "error: " + logDigestMismatch,
				},
			},
		},
		{
			"name":        "06-signtx-unknown-treasury",
			"description": "A signing request for a treasury with no key is refused rather than generating one",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, config.OPCommandSignTx, signRequest(signRequestFor(t, 77))),
			},
			"expect": map[string]any{
				"status":      200,
				"json_subset": map[string]any{"status": 0, "data": "0x"},
				"log_prefix":  "error: ",
			},
		},
		{
			"name":        "07-signtx-success",
			"description": "A request whose fields hash to its digest is signed",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, config.OPCommandSignTx, signRequest(honest)),
			},
			// The blob depends on the random key, so only the outcome is pinned.
			"expect": map[string]any{"status": 200, "json_subset": okResult(config.OPCommandSignTx)},
		},
		{
			"name":        "08-status-reports-the-signed-sequence",
			"description": "STATUS reports the key and the sequence the signature consumed, and nothing else",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, config.OPCommandStatus, treasury(1)),
			},
			"expect": map[string]any{
				"status": 200,
				"json_subset": map[string]any{
					"status": 1, "log": "ok", "data": toHexString(statusPresent),
				},
			},
		},
		{
			"name":        "09-unknown-op-type",
			"description": "An unrecognised opType is 501, naming both the received and expected hashes",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction("NOT_XRPLW", config.OPCommandKeygen, treasury(1)),
			},
			"expect": map[string]any{"status": 501, "text_contains": "unsupported op type"},
		},
		{
			"name":        "10-unknown-op-command",
			"description": "An unrecognised opCommand is 501 and lists the three that exist",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": fixtureAction(config.OPTypeXRPL, "NOPE", treasury(1)),
			},
			"expect": map[string]any{"status": 501, "text_contains": "unsupported op command"},
		},
		{
			"name":        "11-invalid-action-json",
			"description": "A body that is not an Action is 400",
			"request": map[string]any{
				"method": "POST", "path": "/action", "raw_body": "not json at all",
			},
			"expect": map[string]any{"status": 400},
		},
		{
			"name": "12-message-not-datafixed",
			"description": "An Action whose message does not parse as DataFixed is 400. " +
				"Note that a syntactically valid but empty object is not this case: " +
				"it parses, yields a zero opType, and is refused as unsupported instead.",
			"request": map[string]any{
				"method": "POST", "path": "/action",
				"body": map[string]any{
					"data": map[string]any{
						"id":            fixtureActionID,
						"type":          "instruction",
						"submissionTag": "submit",
						"message":       toHexString([]byte("this is not DataFixed")),
					},
					"additionalVariableMessages": []any{},
					"timestamps":                 []any{},
					"additionalActionData":       "0x",
					"signatures":                 []any{},
				},
			},
			"expect": map[string]any{"status": 400},
		},
		{
			"name":        "13-get-action-not-allowed",
			"description": "GET /action is 405",
			"request":     map[string]any{"method": "GET", "path": "/action"},
			"expect":      map[string]any{"status": 405},
		},
		{
			"name":        "14-post-state-not-allowed",
			"description": "POST /state is 405",
			"request":     map[string]any{"method": "POST", "path": "/state", "raw_body": ""},
			"expect":      map[string]any{"status": 405},
		},
		{
			"name":        "15-unknown-path",
			"description": "An unknown path is 404",
			"request":     map[string]any{"method": "GET", "path": "/does-not-exist"},
			"expect":      map[string]any{"status": 404},
		},
		{
			"name": "16-get-state",
			"description": "GET /state reports the version and observable state. " +
				"Addresses depend on the generated keys, so only stateVersion is pinned here; " +
				"that no key material appears is asserted in TestStateExposesNoKeyMaterial.",
			"request": map[string]any{"method": "GET", "path": "/state"},
			"expect": map[string]any{
				"status":      200,
				"json_subset": map[string]any{"stateVersion": b32String(config.Version)},
			},
		},
	}
}

// signRequestFor builds an honestly-digested request for a treasury that has no
// key, so the refusal under test is about the missing key and nothing else.
func signRequestFor(t *testing.T, treasuryID int64) types.SignRequest {
	t.Helper()

	var dest [32]byte
	copy(dest[:], common.FromHex("0xAED2ACA19C6F54926F8482648A694E7CB62BAA22"))

	req := types.SignRequest{
		RequestId:            big.NewInt(int64(treasuryID) * 100),
		TreasuryId:           big.NewInt(treasuryID),
		DestinationAccountId: dest,
		DestinationTag:       1,
		AmountDrops:          500_000,
		Sequence:             1,
		LastLedgerSequence:   800_000,
		FeeDrops:             12,
	}
	digest, err := req.ComputePolicyDigest()
	if err != nil {
		t.Fatal(fmt.Errorf("digest: %w", err))
	}
	req.PolicyDigest = digest
	return req
}
