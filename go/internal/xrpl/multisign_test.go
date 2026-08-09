package xrpl

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/ecdsa"
)

// multisignReference mirrors testdata/multisign_reference.json.
//
// The vectors are validated transactions taken off XRPL. Nothing in this file
// checks the code against output the code produced.
type multisignReference struct {
	Payment struct {
		Hash               string `json:"hash"`
		Account            string `json:"account"`
		Destination        string `json:"destination"`
		AmountDrops        uint64 `json:"amountDrops"`
		FeeDrops           uint64 `json:"feeDrops"`
		Sequence           uint32 `json:"sequence"`
		DestinationTag     uint32 `json:"destinationTag"`
		LastLedgerSequence uint32 `json:"lastLedgerSequence"`
		Flags              uint32 `json:"flags"`
		Signers            []struct {
			Account       string `json:"account"`
			SigningPubKey string `json:"signingPubKey"`
			TxnSignature  string `json:"txnSignature"`
		} `json:"signers"`
		Blob string `json:"blob"`
	} `json:"payment"`

	SignerListSet struct {
		Hash          string `json:"hash"`
		Account       string `json:"account"`
		Quorum        uint32 `json:"quorum"`
		FeeDrops      uint64 `json:"feeDrops"`
		Sequence      uint32 `json:"sequence"`
		Flags         uint32 `json:"flags"`
		SigningPubKey string `json:"signingPubKey"`
		TxnSignature  string `json:"txnSignature"`
		Entries       []struct {
			Account string `json:"account"`
			Weight  uint16 `json:"weight"`
		} `json:"entries"`
		Blob string `json:"blob"`
	} `json:"signerListSet"`

	AccountSet struct {
		Hash          string `json:"hash"`
		Account       string `json:"account"`
		SetFlag       uint32 `json:"setFlag"`
		FeeDrops      uint64 `json:"feeDrops"`
		Sequence      uint32 `json:"sequence"`
		Flags         uint32 `json:"flags"`
		SigningPubKey string `json:"signingPubKey"`
		TxnSignature  string `json:"txnSignature"`
		Blob          string `json:"blob"`
	} `json:"accountSet"`
}

func loadMultisignReference(t *testing.T) multisignReference {
	t.Helper()
	raw, err := os.ReadFile("testdata/multisign_reference.json")
	if err != nil {
		t.Fatalf("reading multisign reference: %v", err)
	}
	var ref multisignReference
	if err := json.Unmarshal(raw, &ref); err != nil {
		t.Fatalf("parsing multisign reference: %v", err)
	}
	return ref
}

func mustAccount(t *testing.T, addr string) AccountID {
	t.Helper()
	id, err := DecodeClassicAddress(addr)
	if err != nil {
		t.Fatalf("decoding %s: %v", addr, err)
	}
	return id
}

// referenceMultisignedPayment rebuilds the reference transaction from its
// decoded fields, with no signatures attached.
func referenceMultisignedPayment(t *testing.T, ref multisignReference) *Payment {
	t.Helper()
	p := ref.Payment
	return &Payment{
		Account:            mustAccount(t, p.Account),
		Destination:        mustAccount(t, p.Destination),
		AmountDrops:        p.AmountDrops,
		FeeDrops:           p.FeeDrops,
		Sequence:           p.Sequence,
		DestinationTag:     p.DestinationTag,
		LastLedgerSequence: p.LastLedgerSequence,
		Flags:              p.Flags,
	}
}

func referenceSigners(t *testing.T, ref multisignReference) []Signer {
	t.Helper()
	out := make([]Signer, 0, len(ref.Payment.Signers))
	for _, s := range ref.Payment.Signers {
		out = append(out, Signer{
			Account:       mustAccount(t, s.Account),
			SigningPubKey: mustHex(t, s.SigningPubKey),
			TxnSignature:  mustHex(t, s.TxnSignature),
		})
	}
	return out
}

// TestMultisignedPaymentMatchesReferenceBlob is the byte-for-byte check.
//
// Reassembling XRPL's own transaction from its decoded fields has to reproduce
// XRPL's own bytes: the Signers array, the empty SigningPubKey, the field order
// and the signer order all have to be right at once, and any one of them being
// wrong changes the output.
func TestMultisignedPaymentMatchesReferenceBlob(t *testing.T) {
	ref := loadMultisignReference(t)
	p := referenceMultisignedPayment(t, ref)

	blob, txID, err := p.AssembleMultisigned(referenceSigners(t, ref))
	if err != nil {
		t.Fatalf("assembling: %v", err)
	}

	want := mustHex(t, ref.Payment.Blob)
	if !bytes.Equal(blob, want) {
		t.Fatalf("blob mismatch\n got %s\nwant %s", strings.ToUpper(hex.EncodeToString(blob)), ref.Payment.Blob)
	}

	if got := strings.ToUpper(hex.EncodeToString(txID[:])); got != ref.Payment.Hash {
		t.Fatalf("transaction id mismatch\n got %s\nwant %s", got, ref.Payment.Hash)
	}
}

// TestReferenceMultiSignaturesVerify checks the multi-signing hash against
// signatures this code did not produce.
//
// These two signatures were made by other software over the payload XRPL
// defines, and the network validated the transaction. So if they verify against
// the digest computed here, then the "SMT\0" prefix, the multi-signing
// serialisation and the appended signer AccountID are all exactly XRPL's. A
// self-consistent sign-then-verify test could not show any of that.
func TestReferenceMultiSignaturesVerify(t *testing.T) {
	ref := loadMultisignReference(t)
	p := referenceMultisignedPayment(t, ref)
	p.Signers = referenceSigners(t, ref)

	valid, err := p.VerifyMultiSignature()
	if err != nil {
		t.Fatalf("verifying: %v", err)
	}
	if len(valid) != len(p.Signers) {
		t.Fatalf("verified %d of %d reference signatures", len(valid), len(p.Signers))
	}
}

// TestMultiSigningHashIsPerSigner proves the AccountID suffix is load-bearing.
//
// Without it every signer would sign identical bytes, and a signature collected
// from one signer could be presented as another's — which would turn k-of-n
// into one-of-n at the moment it matters most.
func TestMultiSigningHashIsPerSigner(t *testing.T) {
	ref := loadMultisignReference(t)
	p := referenceMultisignedPayment(t, ref)
	signers := referenceSigners(t, ref)

	first, err := p.MultiSigningHash(signers[0].Account)
	if err != nil {
		t.Fatalf("hashing for first signer: %v", err)
	}
	second, err := p.MultiSigningHash(signers[1].Account)
	if err != nil {
		t.Fatalf("hashing for second signer: %v", err)
	}
	if first == second {
		t.Fatal("two signers produced the same multi-signing hash")
	}

	// And the reference signatures are bound to their own signer: the first
	// signature must not verify under the second signer's digest.
	pub, err := btcec.ParsePubKey(signers[0].SigningPubKey)
	if err != nil {
		t.Fatalf("parsing key: %v", err)
	}
	sig, err := ecdsa.ParseDERSignature(signers[0].TxnSignature)
	if err != nil {
		t.Fatalf("parsing signature: %v", err)
	}
	if !sig.Verify(first[:], pub) {
		t.Fatal("reference signature does not verify under its own signer's digest")
	}
	if sig.Verify(second[:], pub) {
		t.Fatal("reference signature verified under another signer's digest")
	}
}

// TestMultiSigningHashDiffersFromSingleSigningHash guards the prefix.
//
// Same transaction, two authorisation models, and the four-byte prefix plus the
// empty SigningPubKey is what keeps a signature gathered under one from being
// replayed under the other.
func TestMultiSigningHashDiffersFromSingleSigningHash(t *testing.T) {
	ref := loadMultisignReference(t)
	p := referenceMultisignedPayment(t, ref)
	signers := referenceSigners(t, ref)

	p.SigningPubKey = signers[0].SigningPubKey
	single, err := p.SigningHash()
	if err != nil {
		t.Fatalf("single-signing hash: %v", err)
	}
	multi, err := p.MultiSigningHash(signers[0].Account)
	if err != nil {
		t.Fatalf("multi-signing hash: %v", err)
	}
	if single == multi {
		t.Fatal("single- and multi-signing hashes are identical")
	}
}

// TestAssembleSortsSignersRegardlessOfInputOrder checks the canonical order is
// a property of the format rather than of whoever collected the signatures.
func TestAssembleSortsSignersRegardlessOfInputOrder(t *testing.T) {
	ref := loadMultisignReference(t)
	signers := referenceSigners(t, ref)
	reversed := []Signer{signers[1], signers[0]}

	forward, _, err := referenceMultisignedPayment(t, ref).AssembleMultisigned(signers)
	if err != nil {
		t.Fatalf("assembling forward: %v", err)
	}
	backward, _, err := referenceMultisignedPayment(t, ref).AssembleMultisigned(reversed)
	if err != nil {
		t.Fatalf("assembling reversed: %v", err)
	}

	if !bytes.Equal(forward, backward) {
		t.Fatal("signer order changed the assembled blob")
	}
	if !bytes.Equal(forward, mustHex(t, ref.Payment.Blob)) {
		t.Fatal("assembled blob does not match the reference")
	}
}

// TestMultiSignIsDeterministic confirms RFC 6979 on the multi-signing path.
//
// It is what lets a signature be re-derived rather than stored, and it means a
// machine asked to sign the same request twice contributes one signature rather
// than two different ones that both count.
func TestMultiSignIsDeterministic(t *testing.T) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	p := multisignTestPayment(t)

	first, err := p.MultiSign(priv)
	if err != nil {
		t.Fatalf("first signature: %v", err)
	}
	second, err := p.MultiSign(priv)
	if err != nil {
		t.Fatalf("second signature: %v", err)
	}

	if !bytes.Equal(first.TxnSignature, second.TxnSignature) {
		t.Fatal("signing the same request twice produced different bytes")
	}
	if first.Account != second.Account {
		t.Fatal("the same key derived two different signer accounts")
	}
}

// TestMultiSignDoesNotMutateTheTransaction matters because the same Payment is
// handed to every signer. If signing altered it, the second signer would sign
// different bytes than the first and the quorum would never verify.
func TestMultiSignDoesNotMutateTheTransaction(t *testing.T) {
	p := multisignTestPayment(t)
	before, err := p.serialize(formForMultiSigning)
	if err != nil {
		t.Fatalf("serialising before: %v", err)
	}

	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	if _, err := p.MultiSign(priv); err != nil {
		t.Fatalf("signing: %v", err)
	}

	after, err := p.serialize(formForMultiSigning)
	if err != nil {
		t.Fatalf("serialising after: %v", err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("MultiSign mutated the transaction it signed")
	}
}

// TestQuorumOfIndependentKeysVerifies runs the whole k-of-n signing path with
// keys generated here: three sign, all three verify, and the assembled blob is
// what a submitter would send.
func TestQuorumOfIndependentKeysVerifies(t *testing.T) {
	p := multisignTestPayment(t)

	collected := make([]Signer, 0, 3)
	for i := 0; i < 3; i++ {
		priv, err := btcec.NewPrivateKey()
		if err != nil {
			t.Fatalf("generating key %d: %v", i, err)
		}
		s, err := p.MultiSign(priv)
		if err != nil {
			t.Fatalf("signing with key %d: %v", i, err)
		}
		collected = append(collected, s)
	}

	blob, txID, err := p.AssembleMultisigned(collected)
	if err != nil {
		t.Fatalf("assembling: %v", err)
	}
	if len(blob) == 0 || txID == (Hash{}) {
		t.Fatal("assembly produced nothing")
	}

	valid, err := p.VerifyMultiSignature()
	if err != nil {
		t.Fatalf("verifying: %v", err)
	}
	if len(valid) != 3 {
		t.Fatalf("verified %d of 3 signatures", len(valid))
	}
}

// TestVerifyRejectsATamperedSignature is the failing half of the test above.
// Assembly is done outside the enclave, so a corrupted contribution has to be
// detectable rather than assumed absent.
func TestVerifyRejectsATamperedSignature(t *testing.T) {
	p := multisignTestPayment(t)

	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	good, err := p.MultiSign(priv)
	if err != nil {
		t.Fatalf("signing: %v", err)
	}

	other, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating second key: %v", err)
	}
	stolen, err := p.MultiSign(other)
	if err != nil {
		t.Fatalf("signing with second key: %v", err)
	}

	// The signature of a different key, presented under the first signer's
	// account and key. Nothing about the blob's shape gives this away.
	forged := Signer{Account: good.Account, SigningPubKey: good.SigningPubKey, TxnSignature: stolen.TxnSignature}
	p.Signers = []Signer{forged}

	valid, err := p.VerifyMultiSignature()
	if err != nil {
		t.Fatalf("verifying: %v", err)
	}
	if len(valid) != 0 {
		t.Fatal("a forged signature was reported valid")
	}
}

// TestAssemblyRefusals covers every way a signature set is not usable. Each of
// these is a transaction XRPL would reject after burning a fee.
func TestAssemblyRefusals(t *testing.T) {
	p := multisignTestPayment(t)

	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	one, err := p.MultiSign(priv)
	if err != nil {
		t.Fatalf("signing: %v", err)
	}

	tests := []struct {
		name    string
		signers []Signer
		want    error
	}{
		{"no signatures at all", nil, ErrNoSigners},
		{"the same account twice", []Signer{one, one}, ErrDuplicateSigner},
		{
			"the sending account as its own signer",
			[]Signer{{Account: p.Account, SigningPubKey: one.SigningPubKey, TxnSignature: one.TxnSignature}},
			ErrSignerIsAccount,
		},
		{"more signers than XRPL accepts", repeatDistinctSigners(t, p, MaxSigners+1), ErrTooManySigners},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fresh := multisignTestPayment(t)
			if _, _, err := fresh.AssembleMultisigned(tc.signers); !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

// TestMultiSignRefusesTheSendingAccount is the signing-side half of the rule
// SignerListSet enforces on the list side.
func TestMultiSignRefusesTheSendingAccount(t *testing.T) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	account, err := AccountIDFromPubKey(priv.PubKey().SerializeCompressed())
	if err != nil {
		t.Fatalf("deriving account: %v", err)
	}

	p := multisignTestPayment(t)
	p.Account = account

	if _, err := p.MultiSign(priv); !errors.Is(err, ErrSignerIsAccount) {
		t.Fatalf("got %v, want ErrSignerIsAccount", err)
	}
}

// TestMultiSignRequiresLastLedgerSequence keeps the failure path provable. A
// transaction without an expiry can never be shown not to have settled, which
// is the one thing that wedges a treasury permanently.
func TestMultiSignRequiresLastLedgerSequence(t *testing.T) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	p := multisignTestPayment(t)
	p.LastLedgerSequence = 0

	if _, err := p.MultiSign(priv); !errors.Is(err, ErrNoLastLedgerSequence) {
		t.Fatalf("got %v, want ErrNoLastLedgerSequence", err)
	}
}

// TestMultiSignRequiresFullyCanonicalSig refuses to sign a transaction whose
// flags still allow the malleable signature form.
func TestMultiSignRequiresFullyCanonicalSig(t *testing.T) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	p := multisignTestPayment(t)
	p.Flags = 0

	if _, err := p.MultiSign(priv); err == nil {
		t.Fatal("signed a transaction without tfFullyCanonicalSig")
	}
}

// multisignTestPayment builds a payment with the shape Aegis produces: a memo
// carrying the request reference, a destination tag, an expiry and the
// canonical-signature flag.
func multisignTestPayment(t *testing.T) *Payment {
	t.Helper()
	ref := loadMultisignReference(t)
	p := referenceMultisignedPayment(t, ref)
	p.Memos = []Memo{{Data: bytes.Repeat([]byte{0xAB}, 32)}}
	p.Flags = TfFullyCanonicalSig
	return p
}

// repeatDistinctSigners produces n signatures from n freshly generated keys.
func repeatDistinctSigners(t *testing.T, p *Payment, n int) []Signer {
	t.Helper()
	out := make([]Signer, 0, n)
	for i := 0; i < n; i++ {
		priv, err := btcec.NewPrivateKey()
		if err != nil {
			t.Fatalf("generating key %d: %v", i, err)
		}
		s, err := p.MultiSign(priv)
		if err != nil {
			t.Fatalf("signing %d: %v", i, err)
		}
		out = append(out, s)
	}
	return out
}
