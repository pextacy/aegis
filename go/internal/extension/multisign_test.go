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

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/ecdsa"
	"github.com/ethereum/go-ethereum/accounts/abi"
	teetypes "github.com/flare-foundation/tee-node/pkg/types"
)

// --- helpers ---------------------------------------------------------------

// signerKeygen runs an SKEYGN through the full action path.
func signerKeygen(t *testing.T, e *Extension, treasuryID int64) teetypes.ActionResult {
	t.Helper()
	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandSignerKeygen),
		encodeTreasuryID(t, treasuryID),
	)
	status, body := e.processAction(action)
	if status != http.StatusOK {
		t.Fatalf("signer keygen status: got %d, body %s", status, body)
	}
	return decodeResult(t, body)
}

// keygenAddress pulls the classic address out of a KEYGEN or SKEYGN result.
func keygenAddress(t *testing.T, ar teetypes.ActionResult) (pubKey []byte, address string) {
	t.Helper()
	if ar.Status != 1 {
		t.Fatalf("keygen failed: status %d, log %q", ar.Status, ar.Log)
	}
	values, err := types.KeygenResponseArgs.Unpack(ar.Data)
	if err != nil {
		t.Fatalf("unpacking keygen result: %v", err)
	}
	return values[0].([]byte), values[1].(string)
}

// accountWord left-aligns a classic address's AccountID into a bytes32, which is
// how Solidity carries one.
func accountWord(t *testing.T, address string) [32]byte {
	t.Helper()
	id, err := xrpl.DecodeClassicAddress(address)
	if err != nil {
		t.Fatalf("decoding %s: %v", address, err)
	}
	var word [32]byte
	copy(word[:], id[:])
	return word
}

// validMultiSignRequest builds a request carrying both digests the contract
// would have computed, so it passes every check.
func validMultiSignRequest(t *testing.T, treasuryID int64, source [32]byte) types.MultiSignRequest {
	t.Helper()

	base := validSignRequest(t, treasuryID)
	req := types.MultiSignRequest{
		RequestId:            base.RequestId,
		TreasuryId:           base.TreasuryId,
		SourceAccountId:      source,
		DestinationAccountId: base.DestinationAccountId,
		DestinationTag:       base.DestinationTag,
		AmountDrops:          base.AmountDrops,
		Sequence:             base.Sequence,
		LastLedgerSequence:   base.LastLedgerSequence,
		FeeDrops:             base.FeeDrops,
		PolicyDigest:         base.PolicyDigest,
	}

	digest, err := req.ComputeMultiSignDigest()
	if err != nil {
		t.Fatalf("computing multi-sign digest: %v", err)
	}
	req.MultiSignDigest = digest
	return req
}

func encodeMultiSignRequest(t *testing.T, req types.MultiSignRequest) []byte {
	t.Helper()
	packed, err := abi.Arguments{types.MultiSignRequestArg}.Pack(req)
	if err != nil {
		t.Fatalf("packing multi-sign request: %v", err)
	}
	return packed
}

func multiSign(t *testing.T, e *Extension, req types.MultiSignRequest) teetypes.ActionResult {
	t.Helper()
	action := buildTestAction(
		toHash(config.OPTypeXRPL),
		toHash(config.OPCommandMultiSign),
		encodeMultiSignRequest(t, req),
	)
	status, body := e.processAction(action)
	if status != http.StatusOK {
		t.Fatalf("multi-sign status: got %d, body %s", status, body)
	}
	return decodeResult(t, body)
}

// partialSignature turns an MSIGN result into the Signer the assembler takes.
func partialSignature(t *testing.T, ar teetypes.ActionResult) xrpl.Signer {
	t.Helper()
	if ar.Status != 1 {
		t.Fatalf("multi-sign failed: status %d, log %q", ar.Status, ar.Log)
	}
	values, err := types.PartialSignatureResponseArgs.Unpack(ar.Data)
	if err != nil {
		t.Fatalf("unpacking partial signature: %v", err)
	}

	pubKey := values[0].([]byte)
	account, err := xrpl.AccountIDFromPubKey(pubKey)
	if err != nil {
		t.Fatalf("deriving signer account: %v", err)
	}
	return xrpl.Signer{Account: account, SigningPubKey: pubKey, TxnSignature: values[1].([]byte)}
}

func validSetupRequest(t *testing.T, treasuryID int64, kind uint8, quorum uint32, signers [][32]byte) types.SetupRequest {
	t.Helper()
	req := types.SetupRequest{
		TreasuryId:         big.NewInt(treasuryID),
		Kind:               kind,
		Quorum:             quorum,
		SignerAccountIds:   signers,
		Sequence:           5,
		LastLedgerSequence: 900_000,
		FeeDrops:           12,
	}
	digest, err := req.ComputeSetupDigest()
	if err != nil {
		t.Fatalf("computing setup digest: %v", err)
	}
	req.SetupDigest = digest
	return req
}

func setup(t *testing.T, e *Extension, req types.SetupRequest) teetypes.ActionResult {
	t.Helper()
	packed, err := abi.Arguments{types.SetupRequestArg}.Pack(req)
	if err != nil {
		t.Fatalf("packing setup request: %v", err)
	}
	action := buildTestAction(toHash(config.OPTypeXRPL), toHash(config.OPCommandSetup), packed)
	status, body := e.processAction(action)
	if status != http.StatusOK {
		t.Fatalf("setup status: got %d, body %s", status, body)
	}
	return decodeResult(t, body)
}

func setupBlob(t *testing.T, ar teetypes.ActionResult) ([]byte, [32]byte) {
	t.Helper()
	if ar.Status != 1 {
		t.Fatalf("setup failed: status %d, log %q", ar.Status, ar.Log)
	}
	values, err := types.SignResponseArgs.Unpack(ar.Data)
	if err != nil {
		t.Fatalf("unpacking setup result: %v", err)
	}
	return values[0].([]byte), values[1].([32]byte)
}

// extractTxnSignature recovers the signature from a signed blob.
//
// The field order the serialiser is validated against puts TxnSignature (7,4)
// directly after SigningPubKey (7,3), so the 33-byte compressed key is the
// landmark. This exists so a test can check what actually signed a blob rather
// than only what the blob looks like.
func extractTxnSignature(t *testing.T, blob, pubKey []byte) []byte {
	t.Helper()

	marker := append([]byte{0x73, byte(len(pubKey))}, pubKey...)
	i := bytes.Index(blob, marker)
	if i < 0 {
		t.Fatal("the signed blob does not carry the expected SigningPubKey")
	}

	j := i + len(marker)
	if j+2 > len(blob) || blob[j] != 0x74 {
		t.Fatal("TxnSignature does not follow SigningPubKey in the signed blob")
	}
	length := int(blob[j+1])
	if j+2+length > len(blob) {
		t.Fatal("the signed blob is truncated inside TxnSignature")
	}
	return blob[j+2 : j+2+length]
}

// --- signer keys -----------------------------------------------------------

// TestSignerKeyIsDistinctFromTheMasterKey is the property the two keystore maps
// exist for. One machine can be both the treasury's creator and one of its
// signers, and confusing the two would let a payment be signed by the key that
// is retired precisely so it cannot sign payments.
func TestSignerKeyIsDistinctFromTheMasterKey(t *testing.T) {
	e := New(0, 0)

	_, masterAddress := keygenAddress(t, keygen(t, e, 1))
	_, signerAddress := keygenAddress(t, signerKeygen(t, e, 1))

	if masterAddress == signerAddress {
		t.Fatal("the signer key and the master key derived the same address")
	}
	if masterAddress == "" || signerAddress == "" {
		t.Fatal("an address came back empty")
	}
}

// TestSecondSignerKeygenIsRefused: replacing a live signer key would silently
// drop this machine out of every quorum the account's signer list expects it in.
func TestSecondSignerKeygenIsRefused(t *testing.T) {
	e := New(0, 0)
	signerKeygen(t, e, 1)

	if ar := signerKeygen(t, e, 1); ar.Status != 0 {
		t.Fatalf("a second signer keygen succeeded: status %d", ar.Status)
	}
}

// TestSignerKeygenIsIndependentPerMachine: n machines asked for the same
// treasury produce n different signers, which is what makes the list k-of-n
// rather than k copies of one key.
func TestSignerKeygenIsIndependentPerMachine(t *testing.T) {
	seen := make(map[string]struct{})
	for i := 0; i < 3; i++ {
		_, address := keygenAddress(t, signerKeygen(t, New(0, 0), 1))
		if _, dup := seen[address]; dup {
			t.Fatalf("two machines produced the same signer address %s", address)
		}
		seen[address] = struct{}{}
	}
}

// --- multi-signing ---------------------------------------------------------

// TestQuorumOfMachinesProducesASubmittableTransaction is the whole path: three
// machines each hold one signer key, each signs the same request, and the
// collected contributions assemble into one transaction whose every signature
// verifies.
func TestQuorumOfMachinesProducesASubmittableTransaction(t *testing.T) {
	treasury := New(0, 0)
	_, treasuryAddress := keygenAddress(t, keygen(t, treasury, 1))
	source := accountWord(t, treasuryAddress)

	req := validMultiSignRequest(t, 1, source)

	machines := []*Extension{New(0, 0), New(0, 0), New(0, 0)}
	collected := make([]xrpl.Signer, 0, len(machines))
	for _, m := range machines {
		signerKeygen(t, m, 1)
		collected = append(collected, partialSignature(t, multiSign(t, m, req)))
	}

	payment, err := multiSignPaymentFromRequest(&req)
	if err != nil {
		t.Fatalf("rebuilding payment: %v", err)
	}

	blob, txHash, err := payment.AssembleMultisigned(collected)
	if err != nil {
		t.Fatalf("assembling: %v", err)
	}
	if len(blob) == 0 || txHash == (xrpl.Hash{}) {
		t.Fatal("assembly produced nothing")
	}

	valid, err := payment.VerifyMultiSignature()
	if err != nil {
		t.Fatalf("verifying: %v", err)
	}
	if len(valid) != len(machines) {
		t.Fatalf("verified %d of %d contributions", len(valid), len(machines))
	}
}

// TestMultiSignRefusesATamperedField drives the digest check with a real payload
// whose amount was altered afterwards, which is the tampering the relay path is
// not trusted to rule out. Constructing a fake payload would not test the same
// thing.
func TestMultiSignRefusesATamperedField(t *testing.T) {
	e := New(0, 0)
	signerKeygen(t, e, 1)

	treasury := New(0, 0)
	_, address := keygenAddress(t, keygen(t, treasury, 1))

	req := validMultiSignRequest(t, 1, accountWord(t, address))
	req.AmountDrops += 1 // the digest still describes the original amount

	ar := multiSign(t, e, req)
	if ar.Status != 0 {
		t.Fatalf("a tampered payment was signed: status %d", ar.Status)
	}
	if !strings.Contains(ar.Log, logDigestMismatch) {
		t.Fatalf("log %q does not name the policy digest mismatch", ar.Log)
	}
	if len(ar.Data) != 0 {
		t.Fatal("a refusal carried a signature")
	}
}

// TestMultiSignRefusesATamperedSourceAccount is the check that only exists
// because of k-of-n. A signer key does not know which treasury it signs for, so
// the account arrives with the instruction — and without its own digest, a
// relayer could point a legitimately-approved payment at a different account's
// signer list.
func TestMultiSignRefusesATamperedSourceAccount(t *testing.T) {
	e := New(0, 0)
	signerKeygen(t, e, 1)

	treasury := New(0, 0)
	_, address := keygenAddress(t, keygen(t, treasury, 1))
	other := New(0, 0)
	_, otherAddress := keygenAddress(t, keygen(t, other, 2))

	req := validMultiSignRequest(t, 1, accountWord(t, address))
	req.SourceAccountId = accountWord(t, otherAddress) // policy digest still matches

	ar := multiSign(t, e, req)
	if ar.Status != 0 {
		t.Fatalf("a redirected payment was signed: status %d", ar.Status)
	}
	if !strings.Contains(ar.Log, logSourceMismatch) {
		t.Fatalf("log %q does not name the source account mismatch", ar.Log)
	}
	if len(ar.Data) != 0 {
		t.Fatal("a refusal carried a signature")
	}
}

// TestMultiSignWillNotUseTheMasterKey proves the separation is enforced rather
// than merely intended: a machine holding only a master key for this treasury
// refuses to contribute a signature.
func TestMultiSignWillNotUseTheMasterKey(t *testing.T) {
	e := New(0, 0)
	_, address := keygenAddress(t, keygen(t, e, 1))

	req := validMultiSignRequest(t, 1, accountWord(t, address))

	ar := multiSign(t, e, req)
	if ar.Status != 0 {
		t.Fatalf("the master key produced a k-of-n contribution: status %d", ar.Status)
	}
	if !strings.Contains(ar.Log, "no signer key") {
		t.Fatalf("log %q does not say why", ar.Log)
	}
}

// TestMultiSignRefusesAnUnknownTreasury: no lazy generation, no fallback.
func TestMultiSignRefusesAnUnknownTreasury(t *testing.T) {
	e := New(0, 0)
	signerKeygen(t, e, 1)

	treasury := New(0, 0)
	_, address := keygenAddress(t, keygen(t, treasury, 9))

	req := validMultiSignRequest(t, 9, accountWord(t, address))
	if ar := multiSign(t, e, req); ar.Status != 0 {
		t.Fatalf("signed for a treasury this machine has no key for: status %d", ar.Status)
	}
}

// TestMultiSignIsRepeatable: asked twice, a machine contributes the same
// signature rather than a second one that also counts.
func TestMultiSignIsRepeatable(t *testing.T) {
	e := New(0, 0)
	signerKeygen(t, e, 1)

	treasury := New(0, 0)
	_, address := keygenAddress(t, keygen(t, treasury, 1))
	req := validMultiSignRequest(t, 1, accountWord(t, address))

	first := partialSignature(t, multiSign(t, e, req))
	second := partialSignature(t, multiSign(t, e, req))

	if !bytes.Equal(first.TxnSignature, second.TxnSignature) {
		t.Fatal("the same request produced two different signatures")
	}
}

// --- setup transactions ----------------------------------------------------

// TestSetupSignsTheSignerListWithTheMasterKey checks the transaction that hands
// authority to the signer set: signed by the key that created the account,
// carrying the account itself, its quorum and every signer.
func TestSetupSignsTheSignerListWithTheMasterKey(t *testing.T) {
	e := New(0, 0)
	masterKey, treasuryAddress := keygenAddress(t, keygen(t, e, 1))

	signers := make([][32]byte, 0, 3)
	entries := make([]xrpl.SignerEntry, 0, 3)
	for i := 0; i < 3; i++ {
		_, address := keygenAddress(t, signerKeygen(t, New(0, 0), 1))
		signers = append(signers, accountWord(t, address))
		id, err := xrpl.DecodeClassicAddress(address)
		if err != nil {
			t.Fatalf("decoding signer address: %v", err)
		}
		entries = append(entries, xrpl.SignerEntry{Account: id, Weight: 1})
	}

	req := validSetupRequest(t, 1, types.SetupKindSignerList, 2, signers)
	blob, txHash := setupBlob(t, setup(t, e, req))

	if got := xrpl.TransactionID(blob); got != xrpl.Hash(txHash) {
		t.Fatal("the returned hash is not the hash of the returned blob")
	}

	// Rebuild the same transaction from the fields the enclave was given, and
	// check the signature in the blob against the master key over its hash.
	treasuryID, err := xrpl.DecodeClassicAddress(treasuryAddress)
	if err != nil {
		t.Fatalf("decoding treasury address: %v", err)
	}
	rebuilt := &xrpl.SignerListSet{
		Account:            treasuryID,
		Quorum:             req.Quorum,
		Entries:            entries,
		Sequence:           req.Sequence,
		LastLedgerSequence: req.LastLedgerSequence,
		FeeDrops:           req.FeeDrops,
		Flags:              xrpl.TfFullyCanonicalSig,
		SigningPubKey:      masterKey,
	}
	rebuilt.SortEntries()

	digest, err := rebuilt.SigningHash()
	if err != nil {
		t.Fatalf("hashing rebuilt transaction: %v", err)
	}
	verifySignature(t, blob, masterKey, digest)
}

// TestSetupRefusesATamperedSignerList adds one account to the list after the
// digest was computed. Installing a signer list decides who can ever spend from
// this treasury again, so a relayer adding itself is the attack that matters
// most here.
func TestSetupRefusesATamperedSignerList(t *testing.T) {
	e := New(0, 0)
	keygen(t, e, 1)

	_, first := keygenAddress(t, signerKeygen(t, New(0, 0), 1))
	_, intruder := keygenAddress(t, signerKeygen(t, New(0, 0), 1))

	req := validSetupRequest(t, 1, types.SetupKindSignerList, 1, [][32]byte{accountWord(t, first)})
	req.SignerAccountIds = append(req.SignerAccountIds, accountWord(t, intruder))

	ar := setup(t, e, req)
	if ar.Status != 0 {
		t.Fatalf("a tampered signer list was signed: status %d", ar.Status)
	}
	if !strings.Contains(ar.Log, logSetupDigestMismatch) {
		t.Fatalf("log %q does not name the setup digest mismatch", ar.Log)
	}
	if len(ar.Data) != 0 {
		t.Fatal("a refusal carried a signed transaction")
	}
}

// TestSetupRefusesWithoutTheMasterKey: a machine that holds only a signer key
// cannot delegate authority it does not have.
func TestSetupRefusesWithoutTheMasterKey(t *testing.T) {
	e := New(0, 0)
	signerKeygen(t, e, 1)

	_, other := keygenAddress(t, signerKeygen(t, New(0, 0), 1))
	req := validSetupRequest(t, 1, types.SetupKindSignerList, 1, [][32]byte{accountWord(t, other)})

	ar := setup(t, e, req)
	if ar.Status != 0 {
		t.Fatalf("a machine without the master key signed a signer list: status %d", ar.Status)
	}
	if !strings.Contains(ar.Log, "no master key") {
		t.Fatalf("log %q does not say why", ar.Log)
	}
}

// TestSetupRetiresTheMasterKey covers the second and final step: the key's last
// act is making itself unusable, which is what turns the signer list from an
// additional authority into the only one.
func TestSetupRetiresTheMasterKey(t *testing.T) {
	e := New(0, 0)
	masterKey, treasuryAddress := keygenAddress(t, keygen(t, e, 1))

	req := validSetupRequest(t, 1, types.SetupKindDisableMasterKey, 0, nil)
	blob, txHash := setupBlob(t, setup(t, e, req))

	if got := xrpl.TransactionID(blob); got != xrpl.Hash(txHash) {
		t.Fatal("the returned hash is not the hash of the returned blob")
	}

	treasuryID, err := xrpl.DecodeClassicAddress(treasuryAddress)
	if err != nil {
		t.Fatalf("decoding treasury address: %v", err)
	}
	rebuilt := &xrpl.AccountSet{
		Account:            treasuryID,
		SetFlag:            xrpl.AsfDisableMaster,
		Sequence:           req.Sequence,
		LastLedgerSequence: req.LastLedgerSequence,
		FeeDrops:           req.FeeDrops,
		Flags:              xrpl.TfFullyCanonicalSig,
		SigningPubKey:      masterKey,
	}
	digest, err := rebuilt.SigningHash()
	if err != nil {
		t.Fatalf("hashing rebuilt transaction: %v", err)
	}
	verifySignature(t, blob, masterKey, digest)

	unsigned, err := rebuilt.Serialize(false)
	if err != nil {
		t.Fatalf("serialising rebuilt transaction: %v", err)
	}
	// asfDisableMaster, as the serialiser encodes SetFlag. If this is absent the
	// transaction is a no-op that burns a fee and leaves the key live.
	if !bytes.Contains(unsigned, []byte{0x20, 0x21, 0x00, 0x00, 0x00, 0x04}) {
		t.Fatal("the rebuilt transaction does not set asfDisableMaster")
	}
}

// TestSetupRefusalsCoverEveryMalformedInstruction.
func TestSetupRefusalsCoverEveryMalformedInstruction(t *testing.T) {
	_, someone := keygenAddress(t, signerKeygen(t, New(0, 0), 1))

	tests := []struct {
		name   string
		build  func(t *testing.T) types.SetupRequest
		expect string
	}{
		{
			name: "an unknown setup kind",
			build: func(t *testing.T) types.SetupRequest {
				return validSetupRequest(t, 1, 7, 1, [][32]byte{accountWord(t, someone)})
			},
			expect: "unsupported setup kind",
		},
		{
			name: "a signer list attached to the retirement step",
			build: func(t *testing.T) types.SetupRequest {
				return validSetupRequest(t, 1, types.SetupKindDisableMasterKey, 2, [][32]byte{accountWord(t, someone)})
			},
			expect: "takes no signer list",
		},
		{
			name: "an empty signer list",
			build: func(t *testing.T) types.SetupRequest {
				return validSetupRequest(t, 1, types.SetupKindSignerList, 1, nil)
			},
			expect: "at least one entry",
		},
		{
			name: "a quorum the list cannot reach",
			build: func(t *testing.T) types.SetupRequest {
				return validSetupRequest(t, 1, types.SetupKindSignerList, 5, [][32]byte{accountWord(t, someone)})
			},
			expect: "cannot reach the quorum",
		},
		{
			name: "a quorum of zero",
			build: func(t *testing.T) types.SetupRequest {
				return validSetupRequest(t, 1, types.SetupKindSignerList, 0, [][32]byte{accountWord(t, someone)})
			},
			expect: "quorum must be above zero",
		},
		{
			name: "a signer id that is not a left-aligned AccountID",
			build: func(t *testing.T) types.SetupRequest {
				var bad [32]byte
				bad[31] = 1
				return validSetupRequest(t, 1, types.SetupKindSignerList, 1, [][32]byte{bad})
			},
			expect: "left-aligned",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			e := New(0, 0)
			keygen(t, e, 1)

			ar := setup(t, e, tc.build(t))
			if ar.Status != 0 {
				t.Fatalf("accepted: status %d", ar.Status)
			}
			if !strings.Contains(ar.Log, tc.expect) {
				t.Fatalf("log %q does not contain %q", ar.Log, tc.expect)
			}
		})
	}
}

// TestSetupRefusesTheTreasuryAsItsOwnSigner. XRPL rejects such a list, so an
// enclave that signed one would have delegated to a signer that can never count.
func TestSetupRefusesTheTreasuryAsItsOwnSigner(t *testing.T) {
	e := New(0, 0)
	_, treasuryAddress := keygenAddress(t, keygen(t, e, 1))

	req := validSetupRequest(t, 1, types.SetupKindSignerList, 1, [][32]byte{accountWord(t, treasuryAddress)})

	ar := setup(t, e, req)
	if ar.Status != 0 {
		t.Fatalf("the treasury was listed as its own signer: status %d", ar.Status)
	}
	if !strings.Contains(ar.Log, "own signers") {
		t.Fatalf("log %q does not say why", ar.Log)
	}
}

// --- observable state ------------------------------------------------------

// TestStateReportsSignerKeysAndNoKeyMaterial. Two addresses appear because they
// mean different things — the treasury's account and this machine's identity
// within its signer list — and neither is a key.
func TestStateReportsSignerKeysAndNoKeyMaterial(t *testing.T) {
	e := New(0, 0)
	_, treasuryAddress := keygenAddress(t, keygen(t, e, 1))
	_, signerAddress := keygenAddress(t, signerKeygen(t, e, 1))
	signerKeygen(t, e, 2)

	rec := httptest.NewRecorder()
	e.stateHandler(rec, httptest.NewRequest(http.MethodGet, "/state", nil))

	var resp types.StateResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decoding state: %v", err)
	}

	if len(resp.State.Treasuries) != 2 {
		t.Fatalf("expected two treasuries, got %d", len(resp.State.Treasuries))
	}

	first := resp.State.Treasuries[0]
	if !first.HasKey || !first.HasSignerKey {
		t.Fatalf("treasury 1 reports hasKey=%v hasSignerKey=%v", first.HasKey, first.HasSignerKey)
	}
	if first.ClassicAddress != treasuryAddress || first.SignerAddress != signerAddress {
		t.Fatal("the reported addresses are not the ones generated")
	}

	// A treasury this machine only signs for has no account of its own to report.
	second := resp.State.Treasuries[1]
	if second.HasKey || !second.HasSignerKey || second.ClassicAddress != "" {
		t.Fatalf("treasury 2 reports hasKey=%v classicAddress=%q", second.HasKey, second.ClassicAddress)
	}

	if resp.State.SignerKeygenCount != 2 {
		t.Fatalf("signerKeygenCount is %d, want 2", resp.State.SignerKeygenCount)
	}

	// The response cannot be allowed to carry a key under any input, and the
	// keystore exposes no accessor that could return one — so the check here is
	// that nothing key-shaped reached the wire.
	body := rec.Body.String()
	for _, forbidden := range []string{"priv", "secret", "seed"} {
		if strings.Contains(strings.ToLower(body), forbidden) {
			t.Fatalf("state response contains %q", forbidden)
		}
	}
}

// verifySignature checks the signature inside a signed blob against a key and a
// digest.
func verifySignature(t *testing.T, blob, pubKey []byte, digest xrpl.Hash) {
	t.Helper()

	raw := extractTxnSignature(t, blob, pubKey)
	sig, err := ecdsa.ParseDERSignature(raw)
	if err != nil {
		t.Fatalf("parsing signature: %v", err)
	}
	pub, err := btcec.ParsePubKey(pubKey)
	if err != nil {
		t.Fatalf("parsing key: %v", err)
	}
	if !sig.Verify(digest[:], pub) {
		t.Fatal("the blob's signature does not verify against the key that was supposed to sign it")
	}
}
