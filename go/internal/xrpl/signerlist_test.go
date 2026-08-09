package xrpl

import (
	"bytes"
	"encoding/hex"
	"errors"
	"strings"
	"testing"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/ecdsa"
)

func referenceSignerListSet(t *testing.T, ref multisignReference) *SignerListSet {
	t.Helper()
	s := ref.SignerListSet

	entries := make([]SignerEntry, 0, len(s.Entries))
	for _, e := range s.Entries {
		entries = append(entries, SignerEntry{Account: mustAccount(t, e.Account), Weight: e.Weight})
	}

	return &SignerListSet{
		Account:       mustAccount(t, s.Account),
		Quorum:        s.Quorum,
		Entries:       entries,
		Sequence:      s.Sequence,
		FeeDrops:      s.FeeDrops,
		Flags:         s.Flags,
		SigningPubKey: mustHex(t, s.SigningPubKey),
		TxnSignature:  mustHex(t, s.TxnSignature),
	}
}

// TestSignerListSetMatchesReferenceBlob is the byte-for-byte check against
// XRPL's own serialisation of a SignerListSet.
func TestSignerListSetMatchesReferenceBlob(t *testing.T) {
	ref := loadMultisignReference(t)
	s := referenceSignerListSet(t, ref)

	blob, err := s.Serialize(true)
	if err != nil {
		t.Fatalf("serialising: %v", err)
	}
	if !bytes.Equal(blob, mustHex(t, ref.SignerListSet.Blob)) {
		t.Fatalf("blob mismatch\n got %s\nwant %s",
			strings.ToUpper(hex.EncodeToString(blob)), ref.SignerListSet.Blob)
	}

	txID := TransactionID(blob)
	if got := strings.ToUpper(hex.EncodeToString(txID[:])); got != ref.SignerListSet.Hash {
		t.Fatalf("transaction id mismatch\n got %s\nwant %s", got, ref.SignerListSet.Hash)
	}
}

// TestReferenceSignerListSetSignatureVerifies checks the signing hash against a
// signature this code did not produce and the network accepted.
func TestReferenceSignerListSetSignatureVerifies(t *testing.T) {
	ref := loadMultisignReference(t)
	s := referenceSignerListSet(t, ref)

	digest, err := s.SigningHash()
	if err != nil {
		t.Fatalf("hashing: %v", err)
	}
	pub, err := btcec.ParsePubKey(s.SigningPubKey)
	if err != nil {
		t.Fatalf("parsing key: %v", err)
	}
	sig, err := ecdsa.ParseDERSignature(s.TxnSignature)
	if err != nil {
		t.Fatalf("parsing signature: %v", err)
	}
	if !sig.Verify(digest[:], pub) {
		t.Fatal("the reference SignerListSet signature does not verify against our signing hash")
	}
}

// TestSignerListSetPreservesEntryOrder proves the serialiser does not sort an
// array XRPL does not require sorted. The reference entries are deliberately
// out of ascending order, so a serialiser that sorted them would produce a
// different blob and a different hash than the one the network validated.
func TestSignerListSetPreservesEntryOrder(t *testing.T) {
	ref := loadMultisignReference(t)
	s := referenceSignerListSet(t, ref)

	ascending := true
	for i := 1; i < len(s.Entries); i++ {
		if bytes.Compare(s.Entries[i-1].Account[:], s.Entries[i].Account[:]) > 0 {
			ascending = false
			break
		}
	}
	if ascending {
		t.Skip("the reference entries are in ascending order, so this proves nothing")
	}

	asGiven, err := s.Serialize(true)
	if err != nil {
		t.Fatalf("serialising as given: %v", err)
	}
	s.SortEntries()
	sorted, err := s.Serialize(true)
	if err != nil {
		t.Fatalf("serialising sorted: %v", err)
	}

	if bytes.Equal(asGiven, sorted) {
		t.Fatal("sorting the entries did not change the blob, so order is not being preserved")
	}
	if !bytes.Equal(asGiven, mustHex(t, ref.SignerListSet.Blob)) {
		t.Fatal("the as-given serialisation is not the reference blob")
	}
}

// TestSortEntriesIsDeterministic: two enclaves handed the same key set in
// different orders must build the same transaction, or their signatures cover
// different bytes and no quorum ever forms.
func TestSortEntriesIsDeterministic(t *testing.T) {
	ref := loadMultisignReference(t)

	forward := referenceSignerListSet(t, ref)
	backward := referenceSignerListSet(t, ref)
	for i, j := 0, len(backward.Entries)-1; i < j; i, j = i+1, j-1 {
		backward.Entries[i], backward.Entries[j] = backward.Entries[j], backward.Entries[i]
	}

	forward.SortEntries()
	backward.SortEntries()

	a, err := forward.Serialize(true)
	if err != nil {
		t.Fatalf("serialising forward: %v", err)
	}
	b, err := backward.Serialize(true)
	if err != nil {
		t.Fatalf("serialising backward: %v", err)
	}
	if !bytes.Equal(a, b) {
		t.Fatal("the same entry set in a different order produced a different transaction")
	}
}

// TestSignerListSetSignsAndVerifies runs the master-key path end to end.
func TestSignerListSetSignsAndVerifies(t *testing.T) {
	master, err := btcec.NewPrivateKey()
	if err != nil {
		t.Fatalf("generating master key: %v", err)
	}
	account, err := AccountIDFromPubKey(master.PubKey().SerializeCompressed())
	if err != nil {
		t.Fatalf("deriving account: %v", err)
	}

	s := newSignerListSet(t, account, 2, 3)
	blob, txID, err := s.Sign(master)
	if err != nil {
		t.Fatalf("signing: %v", err)
	}
	if len(blob) == 0 || txID == (Hash{}) {
		t.Fatal("signing produced nothing")
	}
	if s.Flags&TfFullyCanonicalSig == 0 {
		t.Fatal("tfFullyCanonicalSig was not set")
	}

	digest, err := s.SigningHash()
	if err != nil {
		t.Fatalf("hashing: %v", err)
	}
	sig, err := ecdsa.ParseDERSignature(s.TxnSignature)
	if err != nil {
		t.Fatalf("parsing signature: %v", err)
	}
	if !sig.Verify(digest[:], master.PubKey()) {
		t.Fatal("the signature does not verify against the master key")
	}
}

// TestSignerListSetRefusals covers every list that would leave a treasury
// holding an account nothing can sign for, or one a single key still controls.
func TestSignerListSetRefusals(t *testing.T) {
	account := mustAccount(t, "rDseVXFK1SkWhFH65cqAxf3HmvHCF6b94t")

	tests := []struct {
		name   string
		mutate func(*SignerListSet)
		want   error
	}{
		{"quorum of zero authorises anything", func(s *SignerListSet) { s.Quorum = 0 }, ErrNoQuorum},
		{"no entries at all", func(s *SignerListSet) { s.Entries = nil }, ErrNoSignerEntries},
		{"an entry that can never count", func(s *SignerListSet) { s.Entries[0].Weight = 0 }, ErrZeroWeight},
		{
			"a quorum the weights cannot reach",
			func(s *SignerListSet) { s.Quorum = uint32(len(s.Entries)) + 1 },
			ErrQuorumUnreachable,
		},
		{
			"the account listing itself as a signer",
			func(s *SignerListSet) { s.Entries[0].Account = s.Account },
			ErrSignerIsAccount,
		},
		{
			"the same signer twice",
			func(s *SignerListSet) { s.Entries[1].Account = s.Entries[0].Account },
			ErrDuplicateSigner,
		},
		{"no expiry, so failure could never be proven", func(s *SignerListSet) { s.LastLedgerSequence = 0 }, ErrNoLastLedgerSequence},
		{"no fee", func(s *SignerListSet) { s.FeeDrops = 0 }, ErrNoFee},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := newSignerListSet(t, account, 2, 3)
			tc.mutate(s)
			if err := s.Validate(); !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

// TestSignerListSetAcceptsAQuorumOfExactlyTheTotalWeight is the boundary the
// refusal test above sits one past: a list where every signer must sign.
func TestSignerListSetAcceptsAQuorumOfExactlyTheTotalWeight(t *testing.T) {
	account := mustAccount(t, "rDseVXFK1SkWhFH65cqAxf3HmvHCF6b94t")
	s := newSignerListSet(t, account, 3, 3)
	if err := s.Validate(); err != nil {
		t.Fatalf("a three-of-three list was refused: %v", err)
	}
}

func referenceAccountSet(t *testing.T, ref multisignReference) *AccountSet {
	t.Helper()
	a := ref.AccountSet
	return &AccountSet{
		Account:       mustAccount(t, a.Account),
		SetFlag:       a.SetFlag,
		Sequence:      a.Sequence,
		FeeDrops:      a.FeeDrops,
		Flags:         a.Flags,
		SigningPubKey: mustHex(t, a.SigningPubKey),
		TxnSignature:  mustHex(t, a.TxnSignature),
	}
}

// TestAccountSetMatchesReferenceBlob checks the master-key-disabling
// transaction against XRPL's own bytes. The vector is the AccountSet that
// retired the master key of the same account the multi-signed payment is sent
// from, so the three vectors together are one complete arrangement.
func TestAccountSetMatchesReferenceBlob(t *testing.T) {
	ref := loadMultisignReference(t)
	if ref.AccountSet.SetFlag != AsfDisableMaster {
		t.Fatalf("the reference AccountSet sets flag %d, not asfDisableMaster", ref.AccountSet.SetFlag)
	}

	a := referenceAccountSet(t, ref)
	blob, err := a.Serialize(true)
	if err != nil {
		t.Fatalf("serialising: %v", err)
	}
	if !bytes.Equal(blob, mustHex(t, ref.AccountSet.Blob)) {
		t.Fatalf("blob mismatch\n got %s\nwant %s",
			strings.ToUpper(hex.EncodeToString(blob)), ref.AccountSet.Blob)
	}
	txID := TransactionID(blob)
	if got := strings.ToUpper(hex.EncodeToString(txID[:])); got != ref.AccountSet.Hash {
		t.Fatalf("transaction id mismatch\n got %s\nwant %s", got, ref.AccountSet.Hash)
	}
}

// TestReferenceAccountSetSignatureVerifies checks the signing hash against the
// real signature.
func TestReferenceAccountSetSignatureVerifies(t *testing.T) {
	ref := loadMultisignReference(t)
	a := referenceAccountSet(t, ref)

	digest, err := a.SigningHash()
	if err != nil {
		t.Fatalf("hashing: %v", err)
	}
	pub, err := btcec.ParsePubKey(a.SigningPubKey)
	if err != nil {
		t.Fatalf("parsing key: %v", err)
	}
	sig, err := ecdsa.ParseDERSignature(a.TxnSignature)
	if err != nil {
		t.Fatalf("parsing signature: %v", err)
	}
	if !sig.Verify(digest[:], pub) {
		t.Fatal("the reference AccountSet signature does not verify against our signing hash")
	}
}

// TestAccountSetRefusals: a transaction that changes nothing still burns a fee
// and consumes a sequence, and a treasury has one reason to send this.
func TestAccountSetRefusals(t *testing.T) {
	account := mustAccount(t, "rDseVXFK1SkWhFH65cqAxf3HmvHCF6b94t")

	tests := []struct {
		name   string
		mutate func(*AccountSet)
		want   error
	}{
		{"no flag to set", func(a *AccountSet) { a.SetFlag = 0 }, ErrNoSetFlag},
		{"no expiry", func(a *AccountSet) { a.LastLedgerSequence = 0 }, ErrNoLastLedgerSequence},
		{"no fee", func(a *AccountSet) { a.FeeDrops = 0 }, ErrNoFee},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			a := &AccountSet{
				Account:            account,
				SetFlag:            AsfDisableMaster,
				Sequence:           7,
				LastLedgerSequence: 99,
				FeeDrops:           12,
			}
			tc.mutate(a)
			if err := a.Validate(); !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

// newSignerListSet builds a list of n signers at weight 1 with the given quorum.
func newSignerListSet(t *testing.T, account AccountID, quorum uint32, n int) *SignerListSet {
	t.Helper()

	entries := make([]SignerEntry, 0, n)
	for i := 0; i < n; i++ {
		priv, err := btcec.NewPrivateKey()
		if err != nil {
			t.Fatalf("generating signer key %d: %v", i, err)
		}
		id, err := AccountIDFromPubKey(priv.PubKey().SerializeCompressed())
		if err != nil {
			t.Fatalf("deriving signer account %d: %v", i, err)
		}
		entries = append(entries, SignerEntry{Account: id, Weight: 1})
	}

	return &SignerListSet{
		Account:            account,
		Quorum:             quorum,
		Entries:            entries,
		Sequence:           11,
		LastLedgerSequence: 4242,
		FeeDrops:           12,
	}
}
