package xrpl

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/btcsuite/btcd/btcec/v2"
)

// reference mirrors testdata/payment_reference.json.
type reference struct {
	Hash               string `json:"hash"`
	Account            string `json:"account"`
	Destination        string `json:"destination"`
	AmountDrops        uint64 `json:"amountDrops"`
	FeeDrops           uint64 `json:"feeDrops"`
	Sequence           uint32 `json:"sequence"`
	LastLedgerSequence uint32 `json:"lastLedgerSequence"`
	SigningPubKey      string `json:"signingPubKey"`
	TxnSignature       string `json:"txnSignature"`
	MemoType           string `json:"memoType"`
	MemoData           string `json:"memoData"`
	Blob               string `json:"blob"`
}

func loadReference(t *testing.T) reference {
	t.Helper()
	raw, err := os.ReadFile("testdata/payment_reference.json")
	if err != nil {
		t.Fatalf("reading reference: %v", err)
	}
	var ref reference
	if err := json.Unmarshal(raw, &ref); err != nil {
		t.Fatalf("parsing reference: %v", err)
	}
	return ref
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("decoding hex %q: %v", s, err)
	}
	return b
}

func referencePayment(t *testing.T, ref reference) *Payment {
	t.Helper()

	account, err := DecodeClassicAddress(ref.Account)
	if err != nil {
		t.Fatalf("decoding account: %v", err)
	}
	destination, err := DecodeClassicAddress(ref.Destination)
	if err != nil {
		t.Fatalf("decoding destination: %v", err)
	}

	return &Payment{
		Account:            account,
		Destination:        destination,
		AmountDrops:        ref.AmountDrops,
		FeeDrops:           ref.FeeDrops,
		Sequence:           ref.Sequence,
		LastLedgerSequence: ref.LastLedgerSequence,
		SigningPubKey:      mustHex(t, ref.SigningPubKey),
		TxnSignature:       mustHex(t, ref.TxnSignature),
		Memos: []Memo{{
			Type: mustHex(t, ref.MemoType),
			Data: mustHex(t, ref.MemoData),
		}},
	}
}

// TestSerializeMatchesXrplBlob is the test that matters: our serialisation of a
// real transaction's fields must be byte-identical to the blob XRPL itself
// produced for it.
func TestSerializeMatchesXrplBlob(t *testing.T) {
	ref := loadReference(t)
	p := referencePayment(t, ref)

	got, err := p.Serialize(true)
	if err != nil {
		t.Fatalf("Serialize: %v", err)
	}

	want := mustHex(t, ref.Blob)
	if !bytes.Equal(got, want) {
		t.Fatalf("serialisation differs from XRPL's own blob\n got: %X\nwant: %X", got, want)
	}
}

// TestTransactionIDMatchesXrpl checks the TXN\0 prefix and SHA-512Half against
// the hash XRPL assigned to the same transaction.
func TestTransactionIDMatchesXrpl(t *testing.T) {
	ref := loadReference(t)
	id := TransactionID(mustHex(t, ref.Blob))

	got := strings.ToUpper(hex.EncodeToString(id[:]))
	if got != ref.Hash {
		t.Fatalf("transaction id\n got: %s\nwant: %s", got, ref.Hash)
	}
}

func TestAddressRoundTripAgainstReference(t *testing.T) {
	ref := loadReference(t)

	account, err := DecodeClassicAddress(ref.Account)
	if err != nil {
		t.Fatalf("decoding: %v", err)
	}
	if got := EncodeClassicAddress(account); got != ref.Account {
		t.Fatalf("round trip: got %s want %s", got, ref.Account)
	}
}

// TestDeriveAccountFromReferenceKey uses XRPL's published genesis vector, so
// the derivation is checked against XRPL's documentation rather than itself.
func TestDeriveAccountFromReferenceKey(t *testing.T) {
	const (
		pubKey = "0330E7FC9D56BB25D6893BA3F317AE5BCF33B3291BD63DB32654A313222F7FD020"
		want   = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
	)

	_, addr, err := DeriveAccount(mustHex(t, pubKey))
	if err != nil {
		t.Fatalf("DeriveAccount: %v", err)
	}
	if addr != want {
		t.Fatalf("classic address: got %s want %s", addr, want)
	}
}

func TestDecodeRejectsCorruptedAddress(t *testing.T) {
	// Flip one character of a valid address; the checksum must catch it.
	const valid = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
	corrupted := "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTf"

	if _, err := DecodeClassicAddress(valid); err != nil {
		t.Fatalf("the valid address should decode: %v", err)
	}
	if _, err := DecodeClassicAddress(corrupted); err == nil {
		t.Fatal("a corrupted address decoded without error")
	}
}

func TestDecodeRejectsNonAlphabetCharacter(t *testing.T) {
	// '0' is absent from XRPL's alphabet precisely because it looks like 'O'.
	if _, err := DecodeClassicAddress("rHb9CJAWyB4rj91VRWn96DkukG4bwdty0h"); err == nil {
		t.Fatal("an address containing '0' decoded without error")
	}
}

// TestZeroDestinationTagIsOmitted is the subtle one. A zero tag serialised as a
// field produces a different transaction than one left out, and XRPL leaves it
// out. Getting this wrong yields a valid-looking transaction with the wrong hash.
func TestZeroDestinationTagIsOmitted(t *testing.T) {
	ref := loadReference(t)

	omitted := referencePayment(t, ref)
	omitted.DestinationTag = 0
	withoutTag, err := omitted.Serialize(true)
	if err != nil {
		t.Fatalf("Serialize: %v", err)
	}

	tagged := referencePayment(t, ref)
	tagged.DestinationTag = 1
	withTag, err := tagged.Serialize(true)
	if err != nil {
		t.Fatalf("Serialize: %v", err)
	}

	if bytes.Equal(withoutTag, withTag) {
		t.Fatal("a zero tag and a set tag produced identical bytes")
	}
	if !bytes.Equal(withoutTag, mustHex(t, ref.Blob)) {
		t.Fatal("the omitting path is not the one XRPL's blob took")
	}
	if TransactionID(withoutTag) == TransactionID(withTag) {
		t.Fatal("omitting and including a tag produced the same transaction id")
	}
}

func TestFieldsSortByCode(t *testing.T) {
	ref := loadReference(t)
	p := referencePayment(t, ref)
	p.DestinationTag = 42
	p.Flags = TfFullyCanonicalSig

	blob, err := p.Serialize(true)
	if err != nil {
		t.Fatalf("Serialize: %v", err)
	}

	// Flags (2,2) must precede Sequence (2,4), which precedes DestinationTag
	// (2,14), which precedes LastLedgerSequence (2,27) — regardless of the order
	// Serialize appends them in.
	order := []struct {
		name   string
		header []byte
	}{
		{"Flags", []byte{0x22}},
		{"Sequence", []byte{0x24}},
		{"DestinationTag", []byte{0x2E}},
		{"LastLedgerSequence", []byte{0x20, 0x1B}},
	}

	prev := -1
	for _, f := range order {
		idx := bytes.Index(blob, f.header)
		if idx < 0 {
			t.Fatalf("%s not present in the serialisation", f.name)
		}
		if idx <= prev {
			t.Fatalf("%s appears at %d, out of canonical order", f.name, idx)
		}
		prev = idx
	}
}

func TestSigningIsDeterministic(t *testing.T) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("key: %v", err)
	}

	build := func() *Payment {
		return &Payment{
			Account:            AccountID{1, 2, 3},
			Destination:        AccountID{4, 5, 6},
			AmountDrops:        1_000_000,
			FeeDrops:           12,
			Sequence:           7,
			LastLedgerSequence: 100,
			Memos:              []Memo{{Data: []byte("aegis-request-1")}},
		}
	}

	first, firstID, err := build().Sign(priv)
	if err != nil {
		t.Fatalf("first sign: %v", err)
	}
	second, secondID, err := build().Sign(priv)
	if err != nil {
		t.Fatalf("second sign: %v", err)
	}

	if !bytes.Equal(first, second) {
		t.Fatal("signing the same request twice produced different bytes — RFC 6979 is not in effect")
	}
	if firstID != secondID {
		t.Fatal("the same request produced two transaction ids")
	}
}

func TestSignedPaymentVerifies(t *testing.T) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("key: %v", err)
	}

	p := &Payment{
		Account:            AccountID{9},
		Destination:        AccountID{8},
		AmountDrops:        250_000,
		FeeDrops:           15,
		Sequence:           3,
		LastLedgerSequence: 500,
		DestinationTag:     77,
	}

	if _, _, err := p.Sign(priv); err != nil {
		t.Fatalf("Sign: %v", err)
	}

	ok, err := p.VerifySignature()
	if err != nil {
		t.Fatalf("VerifySignature: %v", err)
	}
	if !ok {
		t.Fatal("the signature does not verify against its own signing key")
	}
}

func TestSignSetsFullyCanonicalFlag(t *testing.T) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("key: %v", err)
	}

	p := &Payment{
		Account:            AccountID{1},
		Destination:        AccountID{2},
		AmountDrops:        1,
		FeeDrops:           1,
		Sequence:           1,
		LastLedgerSequence: 2,
	}
	if _, _, err := p.Sign(priv); err != nil {
		t.Fatalf("Sign: %v", err)
	}

	if p.Flags&TfFullyCanonicalSig == 0 {
		t.Fatal("tfFullyCanonicalSig was not set")
	}
}

func TestSignatureIsLowS(t *testing.T) {
	priv, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("key: %v", err)
	}

	// Half the curve order. XRPL rejects a signature whose S exceeds it, because
	// the high form is malleable.
	halfOrder := new(btcec.ModNScalar)
	halfOrder.SetByteSlice(mustHex(t, "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0"))

	for i := 0; i < 24; i++ {
		p := &Payment{
			Account:            AccountID{1},
			Destination:        AccountID{2},
			AmountDrops:        uint64(i + 1),
			FeeDrops:           12,
			Sequence:           uint32(i + 1),
			LastLedgerSequence: 1000,
		}
		if _, _, err := p.Sign(priv); err != nil {
			t.Fatalf("Sign: %v", err)
		}

		// DER: 0x30 len 0x02 rlen R 0x02 slen S
		sig := p.TxnSignature
		rLen := int(sig[3])
		sStart := 4 + rLen + 2
		sLen := int(sig[4+rLen+1])
		s := sig[sStart : sStart+sLen]

		var scalar btcec.ModNScalar
		var buf [32]byte
		copy(buf[32-len(s):], s)
		scalar.SetBytes(&buf)

		if scalar.IsOverHalfOrder() {
			t.Fatalf("iteration %d produced a high-S signature", i)
		}
	}
}

func TestValidateRejectsMissingLastLedgerSequence(t *testing.T) {
	p := &Payment{
		AmountDrops:   1,
		FeeDrops:      1,
		SigningPubKey: []byte{0x02},
	}
	if err := p.Validate(); err != ErrNoLastLedgerSequence {
		t.Fatalf("got %v, want ErrNoLastLedgerSequence", err)
	}
}

func TestValidateRejectsZeroAmountAndFee(t *testing.T) {
	base := func() *Payment {
		return &Payment{
			AmountDrops:        1,
			FeeDrops:           1,
			LastLedgerSequence: 10,
			SigningPubKey:      []byte{0x02},
		}
	}

	noAmount := base()
	noAmount.AmountDrops = 0
	if err := noAmount.Validate(); err != ErrNoAmount {
		t.Fatalf("got %v, want ErrNoAmount", err)
	}

	noFee := base()
	noFee.FeeDrops = 0
	if err := noFee.Validate(); err != ErrNoFee {
		t.Fatalf("got %v, want ErrNoFee", err)
	}
}

func TestAccountIDRejectsWrongKeyLength(t *testing.T) {
	if _, err := AccountIDFromPubKey([]byte{0x02, 0x03}); err == nil {
		t.Fatal("a two-byte key was accepted")
	}
}

func TestVariableLengthPrefixBoundaries(t *testing.T) {
	cases := []struct {
		n    int
		want []byte
	}{
		{0, []byte{0x00}},
		{1, []byte{0x01}},
		{192, []byte{0xC0}},
		{193, []byte{0xC1, 0x00}},
		{12480, []byte{0xF0, 0xFF}},
		{12481, []byte{0xF1, 0x00, 0x00}},
	}

	for _, c := range cases {
		got, err := vlPrefix(c.n)
		if err != nil {
			t.Fatalf("vlPrefix(%d): %v", c.n, err)
		}
		if !bytes.Equal(got, c.want) {
			t.Fatalf("vlPrefix(%d) = %X, want %X", c.n, got, c.want)
		}
	}

	if _, err := vlPrefix(maxVLLength + 1); err == nil {
		t.Fatal("an oversized blob was accepted")
	}
}

func TestAmountRejectsMoreThanTotalSupply(t *testing.T) {
	if _, err := xrpAmountField(fieldAmount, maxDrops+1); err == nil {
		t.Fatal("an amount above the total XRP supply was accepted")
	}
}
