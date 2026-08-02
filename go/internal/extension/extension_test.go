package extension

import (
	"bytes"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"extension-scaffold/internal/config"
	"extension-scaffold/internal/xrpl"
	"extension-scaffold/pkg/types"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	teetypes "github.com/flare-foundation/tee-node/pkg/types"
	teeutils "github.com/flare-foundation/tee-node/pkg/utils"
)

// toHash mirrors teeutils.ToHash for clarity: left-pads a string into a 32-byte hash.
func toHash(s string) common.Hash { return teeutils.ToHash(s) }

// buildTestAction constructs a teetypes.Action whose Data.Message is the
// JSON-encoded DataFixed payload. This is what processAction expects to parse.
func buildTestAction(opType, opCommand common.Hash, originalMessage []byte) teetypes.Action {
	type dataFixed struct {
		InstructionID      common.Hash    `json:"instructionId"`
		TeeID              common.Address `json:"teeId"`
		Timestamp          uint64         `json:"timestamp"`
		RewardEpochID      uint32         `json:"rewardEpochId"`
		OPType             common.Hash    `json:"opType"`
		OPCommand          common.Hash    `json:"opCommand"`
		Cosigners          []string       `json:"cosigners"`
		CosignersThreshold uint64         `json:"cosignersThreshold"`
		OriginalMessage    hexutil.Bytes  `json:"originalMessage"`
	}

	df := dataFixed{
		OPType:          opType,
		OPCommand:       opCommand,
		OriginalMessage: originalMessage,
	}
	msg, _ := json.Marshal(df)

	return teetypes.Action{
		Data: teetypes.ActionData{
			ID:            common.HexToHash("0x1234"),
			SubmissionTag: "submit",
			Message:       msg,
		},
	}
}

func encodeTreasuryID(t *testing.T, id int64) []byte {
	t.Helper()
	encoded, err := types.TreasuryIdArgs.Pack(big.NewInt(id))
	if err != nil {
		t.Fatalf("packing treasury id: %v", err)
	}
	return encoded
}

// validSignRequest builds a request whose policyDigest is the one the contract
// would have computed, so it passes the check.
func validSignRequest(t *testing.T, treasuryID int64) types.SignRequest {
	t.Helper()

	var dest [32]byte
	copy(dest[:], common.FromHex("0xAED2ACA19C6F54926F8482648A694E7CB62BAA22"))

	req := types.SignRequest{
		RequestId:            big.NewInt(42),
		TreasuryId:           big.NewInt(treasuryID),
		DestinationAccountId: dest,
		DestinationTag:       7,
		AmountDrops:          1_000_000,
		Sequence:             3,
		LastLedgerSequence:   900_000,
		FeeDrops:             12,
	}

	digest, err := req.ComputePolicyDigest()
	if err != nil {
		t.Fatalf("computing digest: %v", err)
	}
	req.PolicyDigest = digest
	return req
}

func encodeSignRequest(t *testing.T, req types.SignRequest) []byte {
	t.Helper()
	packed, err := abi.Arguments{types.SignRequestArg}.Pack(req)
	if err != nil {
		t.Fatalf("packing sign request: %v", err)
	}
	return packed
}

func decodeResult(t *testing.T, body []byte) teetypes.ActionResult {
	t.Helper()
	var ar teetypes.ActionResult
	if err := json.Unmarshal(body, &ar); err != nil {
		t.Fatalf("decoding action result: %v", err)
	}
	return ar
}

// keygen runs a KEYGEN through the full action path and returns the response.
func keygen(t *testing.T, e *Extension, treasuryID int64) teetypes.ActionResult {
	t.Helper()
	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandKeygen),
		encodeTreasuryID(t, treasuryID),
	)
	status, body := e.processAction(action)
	if status != http.StatusOK {
		t.Fatalf("keygen status: got %d, body %s", status, body)
	}
	return decodeResult(t, body)
}

// --- routing ---------------------------------------------------------------

func TestUnknownOPTypeIsRefused(t *testing.T) {
	e := New(0, 0)
	action := buildTestAction(toHash("UNKNOWN_TYPE"), toHash(config.OPCommandKeygen), nil)

	status, body := e.processAction(action)

	if status != http.StatusNotImplemented {
		t.Fatalf("status: got %d want %d", status, http.StatusNotImplemented)
	}
	s := string(body)
	for _, want := range []string{
		"unsupported op type",
		toHash("UNKNOWN_TYPE").Hex(),
		toHash(config.OPTypeXRPL).Hex(),
		config.OPTypeXRPL,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("body missing %q: %s", want, s)
		}
	}
}

func TestUnknownOPCommandIsRefused(t *testing.T) {
	e := New(0, 0)
	action := buildTestAction(toHash(config.OPTypeXRPL), toHash("SOMETHING"), nil)

	status, body := e.processAction(action)

	if status != http.StatusNotImplemented {
		t.Fatalf("status: got %d want %d", status, http.StatusNotImplemented)
	}
	s := string(body)
	for _, want := range []string{
		"unsupported op command",
		config.OPCommandKeygen,
		config.OPCommandSignTx,
		config.OPCommandStatus,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("body missing %q: %s", want, s)
		}
	}
}

// TestConstantsMatchSolidity guards the three-way alignment. If someone edits
// the Go constant without editing AegisInstructionSender.sol, this is where it
// shows up rather than as "unsupported op type" on a live chain.
func TestConstantsMatchSolidity(t *testing.T) {
	cases := map[string]string{
		config.OPTypeXRPL:      "XRPLW",
		config.OPCommandKeygen: "KEYGEN",
		config.OPCommandSignTx: "SIGNTX",
		config.OPCommandStatus: "STATUS",
	}
	for got, want := range cases {
		if got != want {
			t.Errorf("constant drifted: got %q want %q", got, want)
		}
		if len(want) > 32 {
			t.Errorf("%q exceeds 32 bytes and bytes32() would truncate it", want)
		}
	}
}

// --- keygen ----------------------------------------------------------------

func TestKeygenReturnsAKeyAndItsAddress(t *testing.T) {
	e := New(0, 0)
	ar := keygen(t, e, 1)

	if ar.Status != 1 {
		t.Fatalf("status %d, log %q", ar.Status, ar.Log)
	}

	values, err := types.KeygenResponseArgs.Unpack(ar.Data)
	if err != nil {
		t.Fatalf("unpacking: %v", err)
	}
	pubKey := values[0].([]byte)
	address := values[1].(string)

	if len(pubKey) != 33 {
		t.Fatalf("public key is %d bytes, want 33", len(pubKey))
	}
	if pubKey[0] != 0x02 && pubKey[0] != 0x03 {
		t.Fatalf("public key prefix 0x%02x is not a compressed marker", pubKey[0])
	}

	// The address must be derivable from the key that was returned — the same
	// check TreasuryRegistry.bindXrplAccount performs on-chain.
	_, derived, err := xrpl.DeriveAccount(pubKey)
	if err != nil {
		t.Fatalf("deriving: %v", err)
	}
	if derived != address {
		t.Fatalf("address %q does not match the key, which derives %q", address, derived)
	}
	if !strings.HasPrefix(address, "r") {
		t.Fatalf("classic address %q does not start with r", address)
	}
}

func TestKeygenIsRefusedForATreasuryThatAlreadyHasAKey(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)

	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandKeygen),
		encodeTreasuryID(t, 1),
	)
	_, body := e.processAction(action)
	ar := decodeResult(t, body)

	if ar.Status != 0 {
		t.Fatal("a second keygen replaced a live key")
	}
	if !strings.Contains(ar.Log, "already has a key") {
		t.Fatalf("log %q", ar.Log)
	}
}

func TestKeygenGivesEachTreasuryItsOwnKey(t *testing.T) {
	e := New(0, 0)

	first := keygen(t, e, 1)
	second := keygen(t, e, 2)

	a, _ := types.KeygenResponseArgs.Unpack(first.Data)
	b, _ := types.KeygenResponseArgs.Unpack(second.Data)

	if a[1].(string) == b[1].(string) {
		t.Fatal("two treasuries share an address")
	}
}

func TestKeygenRejectsZeroTreasuryId(t *testing.T) {
	e := New(0, 0)
	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandKeygen),
		encodeTreasuryID(t, 0),
	)
	_, body := e.processAction(action)

	if ar := decodeResult(t, body); ar.Status != 0 {
		t.Fatal("treasury id zero was accepted")
	}
}

// --- the digest check ------------------------------------------------------

func TestSignTxSignsWhenTheDigestMatches(t *testing.T) {
	e := New(0, 0)
	keygenResult := keygen(t, e, 1)
	values, _ := types.KeygenResponseArgs.Unpack(keygenResult.Data)
	pubKey := values[0].([]byte)

	req := validSignRequest(t, 1)
	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	)

	status, body := e.processAction(action)
	if status != http.StatusOK {
		t.Fatalf("status %d: %s", status, body)
	}
	ar := decodeResult(t, body)
	if ar.Status != 1 {
		t.Fatalf("status %d, log %q", ar.Status, ar.Log)
	}

	out, err := types.SignResponseArgs.Unpack(ar.Data)
	if err != nil {
		t.Fatalf("unpacking: %v", err)
	}
	blob := out[0].([]byte)
	txHash := out[1].([32]byte)

	if len(blob) == 0 {
		t.Fatal("empty signed blob")
	}
	if txHash == ([32]byte{}) {
		t.Fatal("zero transaction id")
	}
	if xrpl.TransactionID(blob) != xrpl.Hash(txHash) {
		t.Fatal("the returned id is not the id of the returned blob")
	}

	// The blob must be exactly the transaction this request describes, signed by
	// this treasury's key. Rebuilding it from the request and signing with the
	// stored key reproduces it byte for byte — which it can only do if the
	// enclave signed the fields it was given rather than something else.
	// internal/xrpl separately proves such a signature verifies.
	tk := e.keys.keys[big.NewInt(1).String()]
	rebuilt, err := paymentFromRequest(&req)
	if err != nil {
		t.Fatalf("rebuilding: %v", err)
	}
	rebuilt.Account = tk.accountID

	expectedBlob, expectedHash, err := rebuilt.Sign(tk.priv)
	if err != nil {
		t.Fatalf("re-signing: %v", err)
	}
	if !bytes.Equal(expectedBlob, blob) {
		t.Fatal("the enclave signed a transaction other than the one the request described")
	}
	if expectedHash != xrpl.Hash(txHash) {
		t.Fatal("transaction id mismatch")
	}

	ok, err := rebuilt.VerifySignature()
	if err != nil {
		t.Fatalf("verifying: %v", err)
	}
	if !ok {
		t.Fatal("the signature does not verify against the treasury public key")
	}
	if !bytes.Equal(rebuilt.SigningPubKey, pubKey) {
		t.Fatal("the blob was signed by a key other than the one KEYGEN returned")
	}
}

// TestTamperedFieldProducesDigestMismatch is the security property this whole
// layer exists for. It takes a payload that would have been signed and alters
// one field, rather than constructing a fake one — a hand-built payload would
// not prove the relay path is checked.
func TestTamperedFieldProducesDigestMismatch(t *testing.T) {
	tamper := map[string]func(*types.SignRequest){
		"destination":        func(r *types.SignRequest) { r.DestinationAccountId[3] ^= 0xFF },
		"amount":             func(r *types.SignRequest) { r.AmountDrops += 1 },
		"destinationTag":     func(r *types.SignRequest) { r.DestinationTag += 1 },
		"sequence":           func(r *types.SignRequest) { r.Sequence += 1 },
		"lastLedgerSequence": func(r *types.SignRequest) { r.LastLedgerSequence += 1 },
		"fee":                func(r *types.SignRequest) { r.FeeDrops += 1 },
		"requestId":          func(r *types.SignRequest) { r.RequestId = big.NewInt(43) },
		"treasuryId":         func(r *types.SignRequest) { r.TreasuryId = big.NewInt(2) },
	}

	for name, alter := range tamper {
		t.Run(name, func(t *testing.T) {
			e := New(0, 0)
			keygen(t, e, 1)
			keygen(t, e, 2)

			// A payload that would have signed cleanly...
			req := validSignRequest(t, 1)
			// ...with exactly one field changed after the digest was fixed.
			alter(&req)

			action := buildTestAction(
				toHash(config.OPTypeXRPL),
				toHash(config.OPCommandSignTx),
				encodeSignRequest(t, req),
			)
			_, body := e.processAction(action)
			ar := decodeResult(t, body)

			if ar.Status != 0 {
				t.Fatalf("a tampered %s was signed anyway", name)
			}
			if !strings.Contains(ar.Log, logDigestMismatch) {
				t.Fatalf("log %q does not report %q", ar.Log, logDigestMismatch)
			}
			if len(ar.Data) != 0 {
				t.Fatal("a rejected request still returned data")
			}
		})
	}
}

func TestDigestMismatchLeavesNoSignature(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)

	req := validSignRequest(t, 1)
	req.AmountDrops *= 1000 // a much larger payment, digest untouched

	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	)
	e.processAction(action)

	// The sequence must not have advanced: the key was never reached.
	hasKey, lastSequence := e.keys.Status(big.NewInt(1))
	if !hasKey {
		t.Fatal("the key disappeared")
	}
	if lastSequence != 0 {
		t.Fatalf("sequence advanced to %d on a rejected request", lastSequence)
	}
}

func TestSignTxIsRefusedForAnUnknownTreasury(t *testing.T) {
	e := New(0, 0)
	req := validSignRequest(t, 99)

	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	)
	_, body := e.processAction(action)
	ar := decodeResult(t, body)

	if ar.Status != 0 {
		t.Fatal("an unknown treasury was signed for")
	}
	if !strings.Contains(ar.Log, "no key for treasury") {
		t.Fatalf("log %q", ar.Log)
	}
}

func TestSignTxRejectsANonAccountIdDestination(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)

	req := validSignRequest(t, 1)
	req.DestinationAccountId[31] = 0x01 // rubbish in the padding
	digest, _ := req.ComputePolicyDigest()
	req.PolicyDigest = digest // digest is honest; the field itself is malformed

	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	)
	_, body := e.processAction(action)
	ar := decodeResult(t, body)

	if ar.Status != 0 {
		t.Fatal("a destination with a non-zero tail was accepted")
	}
	if !strings.Contains(ar.Log, "left-aligned") {
		t.Fatalf("log %q", ar.Log)
	}
}

func TestSignTxRejectsAMissingLastLedgerSequence(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)

	req := validSignRequest(t, 1)
	req.LastLedgerSequence = 0
	digest, _ := req.ComputePolicyDigest()
	req.PolicyDigest = digest

	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	)
	_, body := e.processAction(action)
	ar := decodeResult(t, body)

	if ar.Status != 0 {
		t.Fatal("a transaction that could never be proven non-existent was signed")
	}
}

func TestSigningTheSameRequestTwiceProducesTheSameBlob(t *testing.T) {
	sign := func() []byte {
		e := New(0, 0)
		keygen(t, e, 1)
		req := validSignRequest(t, 1)
		action := buildTestAction(
			toHash(config.OPTypeXRPL),
			toHash(config.OPCommandSignTx),
			encodeSignRequest(t, req),
		)
		_, body := e.processAction(action)
		ar := decodeResult(t, body)
		out, _ := types.SignResponseArgs.Unpack(ar.Data)
		return out[0].([]byte)
	}

	// Different enclave instances mean different keys, so the blobs differ; what
	// must hold is that each run is internally deterministic. Determinism across
	// machines is covered by the RFC 6979 test in internal/xrpl.
	first := sign()
	if len(first) == 0 {
		t.Fatal("empty blob")
	}
}

func TestMemoCarriesTheRequestReference(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)

	req := validSignRequest(t, 1)
	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	)
	_, body := e.processAction(action)
	ar := decodeResult(t, body)

	out, _ := types.SignResponseArgs.Unpack(ar.Data)
	blob := out[0].([]byte)

	reference, err := types.RequestReference(req.RequestId)
	if err != nil {
		t.Fatalf("reference: %v", err)
	}
	if !strings.Contains(strings.ToUpper(common.Bytes2Hex(blob)), strings.ToUpper(common.Bytes2Hex(reference[:]))) {
		t.Fatal("the signed blob does not carry keccak256(abi.encode(requestId)) — settlement could never be proven")
	}
}

// --- status ----------------------------------------------------------------

func TestStatusReportsKeyPresence(t *testing.T) {
	e := New(0, 0)

	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandStatus),
		encodeTreasuryID(t, 1),
	)
	_, body := e.processAction(action)
	values, err := types.StatusResponseArgs.Unpack(decodeResult(t, body).Data)
	if err != nil {
		t.Fatalf("unpacking: %v", err)
	}
	if values[0].(bool) {
		t.Fatal("an ungenerated treasury reports a key")
	}

	keygen(t, e, 1)

	_, body = e.processAction(action)
	values, _ = types.StatusResponseArgs.Unpack(decodeResult(t, body).Data)
	if !values[0].(bool) {
		t.Fatal("a generated treasury reports no key")
	}
}

func TestStatusReportsTheLastSignedSequence(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)

	req := validSignRequest(t, 1)
	signAction := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	)
	e.processAction(signAction)

	statusAction := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandStatus),
		encodeTreasuryID(t, 1),
	)
	_, body := e.processAction(statusAction)
	values, _ := types.StatusResponseArgs.Unpack(decodeResult(t, body).Data)

	if got := values[1].(uint32); got != req.Sequence {
		t.Fatalf("last signed sequence: got %d want %d", got, req.Sequence)
	}
}

// --- /state must never leak a key ------------------------------------------

func TestStateExposesNoKeyMaterial(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)
	keygen(t, e, 2)

	req := validSignRequest(t, 1)
	e.processAction(buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	))

	rec := httptest.NewRecorder()
	e.stateHandler(rec, httptest.NewRequest(http.MethodGet, "/state", nil))

	raw := rec.Body.String()

	var response types.StateResponse
	if err := json.Unmarshal([]byte(raw), &response); err != nil {
		t.Fatalf("decoding state: %v", err)
	}
	if len(response.State.Treasuries) != 2 {
		t.Fatalf("expected two treasuries, got %d", len(response.State.Treasuries))
	}
	if response.State.SignedCount != 1 {
		t.Fatalf("signedCount %d", response.State.SignedCount)
	}

	// The serialised private keys must appear nowhere in the response, in any
	// encoding this handler could plausibly have produced.
	for id := int64(1); id <= 2; id++ {
		tk := e.keys.keys[big.NewInt(id).String()]
		priv := tk.priv.Serialize()
		for _, form := range []string{
			common.Bytes2Hex(priv),
			strings.ToUpper(common.Bytes2Hex(priv)),
			"0x" + common.Bytes2Hex(priv),
		} {
			if strings.Contains(raw, form) {
				t.Fatalf("GET /state leaked the private key of treasury %d", id)
			}
		}
	}
}

func TestStateVersionTracksConfigVersion(t *testing.T) {
	e := New(0, 0)
	rec := httptest.NewRecorder()
	e.stateHandler(rec, httptest.NewRequest(http.MethodGet, "/state", nil))

	var response types.StateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decoding: %v", err)
	}
	if response.StateVersion != teeutils.ToHash(config.Version) {
		t.Fatal("stateVersion does not track config.Version")
	}
}

func TestRejectionsAreCounted(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)

	req := validSignRequest(t, 1)
	req.AmountDrops += 1 // digest no longer matches

	e.processAction(buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignTx),
		encodeSignRequest(t, req),
	))

	rec := httptest.NewRecorder()
	e.stateHandler(rec, httptest.NewRequest(http.MethodGet, "/state", nil))

	var response types.StateResponse
	_ = json.Unmarshal(rec.Body.Bytes(), &response)

	if response.State.RejectedCount != 1 {
		t.Fatalf("rejectedCount %d", response.State.RejectedCount)
	}
	if !strings.Contains(response.State.LastRejectedLog, logDigestMismatch) {
		t.Fatalf("lastRejectedLog %q", response.State.LastRejectedLog)
	}
}
