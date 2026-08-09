package xrpl

import (
	"bytes"
	"errors"
	"fmt"
	"sort"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/ecdsa"
)

// AsfDisableMaster is the AccountSet flag that retires an account's master key.
//
// Until it is set, the key that created the account can still sign alone, and a
// SignerList is an additional way to authorise rather than the only one. Setting
// it is what makes k-of-n the sole authority over the account — and XRPL refuses
// it unless an alternative signing method already exists, so the order is
// install the list, then lock the key.
const AsfDisableMaster uint32 = 4

// SignerEntry is one member of an account's SignerList, with the weight its
// signature carries towards the quorum.
type SignerEntry struct {
	Account AccountID
	Weight  uint16
}

var (
	// ErrNoSignerEntries rejects an empty signer list.
	ErrNoSignerEntries = errors.New("xrpl: a signer list needs at least one entry")

	// ErrZeroWeight rejects an entry that could never contribute to a quorum.
	ErrZeroWeight = errors.New("xrpl: a signer entry needs a weight above zero")

	// ErrQuorumUnreachable rejects a list whose weights cannot reach its quorum.
	// XRPL rejects it too; catching it here means the treasury is not left
	// holding an account nothing can ever sign for.
	ErrQuorumUnreachable = errors.New("xrpl: the signer weights cannot reach the quorum")

	// ErrNoQuorum rejects a quorum of zero, which would authorise anything.
	ErrNoQuorum = errors.New("xrpl: quorum must be above zero")
)

// SignerListSet installs, replaces or removes an account's SignerList.
//
// Aegis signs one of these with the treasury's master key, once, to hand
// authority over the account to the n enclave-held signer keys. After that it
// signs an AccountSet that disables the master key, and from then on the only
// way to move the account's funds is a quorum of enclaves each of which checked
// the policy digest for itself.
type SignerListSet struct {
	Account            AccountID
	Quorum             uint32
	Entries            []SignerEntry
	Sequence           uint32
	LastLedgerSequence uint32
	FeeDrops           uint64
	Flags              uint32

	SigningPubKey []byte
	TxnSignature  []byte
}

// Validate checks the invariants that must hold before signing.
func (s *SignerListSet) Validate() error {
	if s.LastLedgerSequence == 0 {
		return ErrNoLastLedgerSequence
	}
	if s.FeeDrops == 0 {
		return ErrNoFee
	}
	if s.Quorum == 0 {
		return ErrNoQuorum
	}
	if len(s.Entries) == 0 {
		return ErrNoSignerEntries
	}
	if len(s.Entries) > MaxSigners {
		return fmt.Errorf("%w: got %d", ErrTooManySigners, len(s.Entries))
	}

	var total uint64
	seen := make(map[AccountID]struct{}, len(s.Entries))
	for i, e := range s.Entries {
		if e.Weight == 0 {
			return fmt.Errorf("%w: entry %d", ErrZeroWeight, i)
		}
		if e.Account == (AccountID{}) {
			return fmt.Errorf("entry %d has a zero AccountID", i)
		}
		if e.Account == s.Account {
			return ErrSignerIsAccount
		}
		if _, dup := seen[e.Account]; dup {
			return fmt.Errorf("%w: %s", ErrDuplicateSigner, EncodeClassicAddress(e.Account))
		}
		seen[e.Account] = struct{}{}
		total += uint64(e.Weight)
	}

	if total < uint64(s.Quorum) {
		return fmt.Errorf("%w: weights total %d, quorum %d", ErrQuorumUnreachable, total, s.Quorum)
	}
	return nil
}

// SortEntries puts the signer entries in ascending account order.
//
// XRPL does not require it — the reference transaction this serialiser is
// validated against carries them unsorted — but two enclaves building the same
// list from the same set must produce the same bytes, and sorting is what makes
// that true regardless of the order the keys were collected in.
func (s *SignerListSet) SortEntries() {
	sort.Slice(s.Entries, func(i, j int) bool {
		return bytes.Compare(s.Entries[i].Account[:], s.Entries[j].Account[:]) < 0
	})
}

// Serialize returns the canonical binary form.
//
// The entries are serialised in the order they are held, not sorted here: the
// order is part of what was signed, so re-ordering during serialisation would
// invalidate a signature produced over the same struct.
func (s *SignerListSet) Serialize(includeSignature bool) ([]byte, error) {
	fields := []field{
		uint16Field(fieldTransactionType, txTypeSignerListSet),
		uint32Field(fieldSequence, s.Sequence),
		uint32Field(fieldSignerQuorum, s.Quorum),
	}

	// Omitted when zero, like every other optional field. Validate requires one
	// on anything Aegis signs; the zero case exists because the reference
	// transaction this is checked against does not carry one.
	if s.LastLedgerSequence != 0 {
		fields = append(fields, uint32Field(fieldLastLedgerSequence, s.LastLedgerSequence))
	}
	if s.Flags != 0 {
		fields = append(fields, uint32Field(fieldFlags, s.Flags))
	}

	fee, err := xrpAmountField(fieldFee, s.FeeDrops)
	if err != nil {
		return nil, fmt.Errorf("serialising Fee: %w", err)
	}
	fields = append(fields, fee)

	pubKey, err := blobField(typeBlob, fieldSigningPubKey, s.SigningPubKey)
	if err != nil {
		return nil, err
	}
	fields = append(fields, pubKey)

	if includeSignature {
		sig, err := blobField(typeBlob, fieldTxnSignature, s.TxnSignature)
		if err != nil {
			return nil, err
		}
		fields = append(fields, sig)
	}

	account, err := blobField(typeAccountID, fieldAccount, s.Account[:])
	if err != nil {
		return nil, err
	}
	fields = append(fields, account)

	entries, err := serializeSignerEntries(s.Entries)
	if err != nil {
		return nil, err
	}
	fields = append(fields, entries)

	sortFields(fields)

	var out []byte
	for _, f := range fields {
		out = append(out, f.encode()...)
	}
	return out, nil
}

// SigningHash returns the digest signed for this transaction.
func (s *SignerListSet) SigningHash() (Hash, error) {
	unsigned, err := s.Serialize(false)
	if err != nil {
		return Hash{}, fmt.Errorf("serialising for signing: %w", err)
	}
	return sha512Half(prefixSingleSign, unsigned), nil
}

// Sign produces the signed blob and its transaction id.
//
// Signed with the master key, because installing a signer list is precisely the
// act of delegating away from it — there is nothing else on the account yet that
// could authorise the change.
func (s *SignerListSet) Sign(priv *btcec.PrivateKey) ([]byte, Hash, error) {
	if priv == nil {
		return nil, Hash{}, fmt.Errorf("xrpl: private key is nil")
	}

	s.SigningPubKey = priv.PubKey().SerializeCompressed()
	if err := s.Validate(); err != nil {
		return nil, Hash{}, err
	}
	s.Flags |= TfFullyCanonicalSig

	digest, err := s.SigningHash()
	if err != nil {
		return nil, Hash{}, err
	}

	sig := ecdsa.Sign(priv, digest[:])
	s.TxnSignature = sig.Serialize()

	blob, err := s.Serialize(true)
	if err != nil {
		return nil, Hash{}, fmt.Errorf("serialising signed transaction: %w", err)
	}
	return blob, TransactionID(blob), nil
}

// serializeSignerEntries builds the SignerEntries STArray.
func serializeSignerEntries(entries []SignerEntry) (field, error) {
	var payload []byte

	for i, e := range entries {
		inner := []field{uint16Field(fieldSignerWeight, e.Weight)}

		account, err := blobField(typeAccountID, fieldAccount, e.Account[:])
		if err != nil {
			return field{}, fmt.Errorf("entry %d: %w", i, err)
		}
		inner = append(inner, account)
		sortFields(inner)

		header := field{typeCode: typeSTObject, fieldCode: fieldSignerEntry}
		payload = append(payload, header.header()...)
		for _, f := range inner {
			payload = append(payload, f.encode()...)
		}
		end := field{typeCode: typeSTObject, fieldCode: fieldObjectEndMarker}
		payload = append(payload, end.header()...)
	}

	endArray := field{typeCode: typeSTArray, fieldCode: fieldArrayEndMarker}
	payload = append(payload, endArray.header()...)

	return field{typeCode: typeSTArray, fieldCode: fieldSignerEntries, payload: payload}, nil
}

// AccountSet changes one account setting. Aegis uses exactly one of them:
// AsfDisableMaster, which retires the key that created the treasury account so
// that the enclave quorum is the only remaining authority over it.
type AccountSet struct {
	Account            AccountID
	SetFlag            uint32
	Sequence           uint32
	LastLedgerSequence uint32
	FeeDrops           uint64
	Flags              uint32

	SigningPubKey []byte
	TxnSignature  []byte
}

// ErrNoSetFlag rejects an AccountSet that changes nothing. Aegis has one reason
// to send this transaction, and a no-op that burns a fee and consumes a
// sequence is not it.
var ErrNoSetFlag = errors.New("xrpl: AccountSet requires a SetFlag")

// Validate checks the invariants that must hold before signing.
func (a *AccountSet) Validate() error {
	if a.LastLedgerSequence == 0 {
		return ErrNoLastLedgerSequence
	}
	if a.FeeDrops == 0 {
		return ErrNoFee
	}
	if a.SetFlag == 0 {
		return ErrNoSetFlag
	}
	return nil
}

// Serialize returns the canonical binary form.
func (a *AccountSet) Serialize(includeSignature bool) ([]byte, error) {
	fields := []field{
		uint16Field(fieldTransactionType, txTypeAccountSet),
		uint32Field(fieldSequence, a.Sequence),
		uint32Field(fieldSetFlag, a.SetFlag),
	}

	if a.LastLedgerSequence != 0 {
		fields = append(fields, uint32Field(fieldLastLedgerSequence, a.LastLedgerSequence))
	}
	if a.Flags != 0 {
		fields = append(fields, uint32Field(fieldFlags, a.Flags))
	}

	fee, err := xrpAmountField(fieldFee, a.FeeDrops)
	if err != nil {
		return nil, fmt.Errorf("serialising Fee: %w", err)
	}
	fields = append(fields, fee)

	pubKey, err := blobField(typeBlob, fieldSigningPubKey, a.SigningPubKey)
	if err != nil {
		return nil, err
	}
	fields = append(fields, pubKey)

	if includeSignature {
		sig, err := blobField(typeBlob, fieldTxnSignature, a.TxnSignature)
		if err != nil {
			return nil, err
		}
		fields = append(fields, sig)
	}

	account, err := blobField(typeAccountID, fieldAccount, a.Account[:])
	if err != nil {
		return nil, err
	}
	fields = append(fields, account)

	sortFields(fields)

	var out []byte
	for _, f := range fields {
		out = append(out, f.encode()...)
	}
	return out, nil
}

// SigningHash returns the digest signed for this transaction.
func (a *AccountSet) SigningHash() (Hash, error) {
	unsigned, err := a.Serialize(false)
	if err != nil {
		return Hash{}, fmt.Errorf("serialising for signing: %w", err)
	}
	return sha512Half(prefixSingleSign, unsigned), nil
}

// Sign produces the signed blob and its transaction id.
func (a *AccountSet) Sign(priv *btcec.PrivateKey) ([]byte, Hash, error) {
	if priv == nil {
		return nil, Hash{}, fmt.Errorf("xrpl: private key is nil")
	}

	a.SigningPubKey = priv.PubKey().SerializeCompressed()
	if err := a.Validate(); err != nil {
		return nil, Hash{}, err
	}
	a.Flags |= TfFullyCanonicalSig

	digest, err := a.SigningHash()
	if err != nil {
		return nil, Hash{}, err
	}

	sig := ecdsa.Sign(priv, digest[:])
	a.TxnSignature = sig.Serialize()

	blob, err := a.Serialize(true)
	if err != nil {
		return nil, Hash{}, fmt.Errorf("serialising signed transaction: %w", err)
	}
	return blob, TransactionID(blob), nil
}
