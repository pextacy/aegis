package xrpl

import (
	"bytes"
	"errors"
	"fmt"
	"sort"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/ecdsa"
)

// Signer is one signature on a multi-signed transaction.
//
// Account is the signer's own XRPL account, derived from SigningPubKey. XRPL
// looks that account up in the sending account's SignerList to decide whether
// the signature counts and what it weighs, so a signature is only ever as
// authoritative as the list says it is.
type Signer struct {
	Account       AccountID
	SigningPubKey []byte
	TxnSignature  []byte
}

var (
	// ErrNoSigners rejects assembling a multi-signed transaction with nothing to
	// assemble. XRPL would reject it too; refusing here means the caller finds
	// out before a fee is burned.
	ErrNoSigners = errors.New("xrpl: a multi-signed transaction needs at least one signer")

	// ErrDuplicateSigner rejects the same account signing twice. XRPL counts a
	// SignerList entry once, so a duplicate can only ever inflate an apparent
	// quorum that the ledger will not honour.
	ErrDuplicateSigner = errors.New("xrpl: the same account signed twice")

	// ErrSignerIsAccount rejects the sending account signing as one of its own
	// signers. SignerListSet refuses an entry equal to the account itself, so
	// such a signature can never be in the list it would have to be counted from.
	ErrSignerIsAccount = errors.New("xrpl: the sending account cannot be one of its own signers")

	// ErrTooManySigners rejects more signatures than XRPL will accept.
	ErrTooManySigners = errors.New("xrpl: a transaction accepts at most 32 signers")
)

// MaxSigners is the largest signer list, and largest set of signatures, XRPL
// accepts on one account.
const MaxSigners = 32

// MultiSigningHash returns the digest one signer signs.
//
// The payload is the transaction in multi-signing form with that signer's
// AccountID appended, under the "SMT\0" prefix. The suffix is what stops a
// signature collected for one signer being replayed as another's: every signer
// hashes the same transaction bytes and a different 20-byte tail.
func (p *Payment) MultiSigningHash(signer AccountID) (Hash, error) {
	if signer == (AccountID{}) {
		return Hash{}, fmt.Errorf("xrpl: signer AccountID is zero")
	}
	unsigned, err := p.serialize(formForMultiSigning)
	if err != nil {
		return Hash{}, fmt.Errorf("serialising for multi-signing: %w", err)
	}
	return sha512Half(prefixMultiSign, append(unsigned, signer[:]...)), nil
}

// MultiSign produces this key's contribution to a multi-signed transaction.
//
// It returns a Signer rather than a blob, because one key holds no authority on
// its own: the transaction is not valid until enough of them are assembled to
// reach the account's quorum. That is the whole property k-of-n buys, and
// returning a complete-looking artefact from one enclave would obscure it.
//
// The transaction is not mutated, so the same Payment can be handed to every
// signer and each produces a signature over identical bytes.
func (p *Payment) MultiSign(priv *btcec.PrivateKey) (Signer, error) {
	if priv == nil {
		return Signer{}, fmt.Errorf("xrpl: private key is nil")
	}

	if err := p.validate(true); err != nil {
		return Signer{}, err
	}
	if p.Flags&TfFullyCanonicalSig == 0 {
		return Signer{}, fmt.Errorf("xrpl: tfFullyCanonicalSig must be set before signing")
	}

	pubKey := priv.PubKey().SerializeCompressed()
	account, err := AccountIDFromPubKey(pubKey)
	if err != nil {
		return Signer{}, fmt.Errorf("deriving signer account: %w", err)
	}
	if account == p.Account {
		return Signer{}, ErrSignerIsAccount
	}

	digest, err := p.MultiSigningHash(account)
	if err != nil {
		return Signer{}, err
	}

	sig := ecdsa.Sign(priv, digest[:])
	return Signer{Account: account, SigningPubKey: pubKey, TxnSignature: sig.Serialize()}, nil
}

// AssembleMultisigned combines collected signatures into a submittable blob.
//
// Assembly needs no secret and grants no authority: every signature already
// covers the whole transaction, so an assembler that reorders, drops or forges
// one produces a blob XRPL rejects rather than a payment nobody authorised.
// That is why this can run outside the enclave.
//
// The signers are sorted by AccountID because XRPL requires that order and
// rejects any other, and sorting here rather than trusting the caller means the
// order is a property of the format instead of of whoever collected them.
func (p *Payment) AssembleMultisigned(signers []Signer) ([]byte, Hash, error) {
	if err := p.validate(true); err != nil {
		return nil, Hash{}, err
	}

	ordered, err := canonicalSigners(signers, p.Account)
	if err != nil {
		return nil, Hash{}, err
	}

	p.SigningPubKey = nil
	p.TxnSignature = nil
	p.Signers = ordered

	blob, err := p.serialize(formMultiSigned)
	if err != nil {
		return nil, Hash{}, fmt.Errorf("serialising multi-signed transaction: %w", err)
	}
	return blob, TransactionID(blob), nil
}

// VerifyMultiSignature checks every collected signature against its own key.
//
// It reports which signers verified, so a caller assembling a quorum can drop a
// bad contribution rather than discovering it as a rejected submission. It does
// not know the account's SignerList and so says nothing about quorum — only
// that each signature is what the key it names actually produced.
func (p *Payment) VerifyMultiSignature() ([]Signer, error) {
	valid := make([]Signer, 0, len(p.Signers))

	for i, s := range p.Signers {
		account, err := AccountIDFromPubKey(s.SigningPubKey)
		if err != nil {
			return nil, fmt.Errorf("signer %d: %w", i, err)
		}
		if account != s.Account {
			return nil, fmt.Errorf("signer %d: key does not derive its stated account", i)
		}

		digest, err := p.MultiSigningHash(account)
		if err != nil {
			return nil, err
		}

		pub, err := btcec.ParsePubKey(s.SigningPubKey)
		if err != nil {
			return nil, fmt.Errorf("signer %d: parsing public key: %w", i, err)
		}
		sig, err := ecdsa.ParseDERSignature(s.TxnSignature)
		if err != nil {
			return nil, fmt.Errorf("signer %d: parsing signature: %w", i, err)
		}

		if sig.Verify(digest[:], pub) {
			valid = append(valid, s)
		}
	}

	return valid, nil
}

// canonicalSigners validates a signature set and returns it in XRPL's order.
func canonicalSigners(signers []Signer, account AccountID) ([]Signer, error) {
	if len(signers) == 0 {
		return nil, ErrNoSigners
	}
	if len(signers) > MaxSigners {
		return nil, fmt.Errorf("%w: got %d", ErrTooManySigners, len(signers))
	}

	ordered := make([]Signer, len(signers))
	copy(ordered, signers)

	for i, s := range ordered {
		if len(s.SigningPubKey) == 0 {
			return nil, fmt.Errorf("signer %d has no public key", i)
		}
		if len(s.TxnSignature) == 0 {
			return nil, fmt.Errorf("signer %d has no signature", i)
		}
		if s.Account == (AccountID{}) {
			return nil, fmt.Errorf("signer %d has a zero AccountID", i)
		}
		if s.Account == account {
			return nil, ErrSignerIsAccount
		}
	}

	sort.Slice(ordered, func(i, j int) bool {
		return bytes.Compare(ordered[i].Account[:], ordered[j].Account[:]) < 0
	})

	for i := 1; i < len(ordered); i++ {
		if ordered[i].Account == ordered[i-1].Account {
			return nil, fmt.Errorf("%w: %s", ErrDuplicateSigner, EncodeClassicAddress(ordered[i].Account))
		}
	}

	return ordered, nil
}

// serializeSigners builds the Signers STArray.
//
// Each entry is a Signer STObject holding the key, the signature and the
// signing account, in the canonical field order the sort establishes.
func serializeSigners(signers []Signer) (field, error) {
	var payload []byte

	for i, s := range signers {
		inner := make([]field, 0, 3)

		pubKey, err := blobField(typeBlob, fieldSigningPubKey, s.SigningPubKey)
		if err != nil {
			return field{}, fmt.Errorf("signer %d: %w", i, err)
		}
		sig, err := blobField(typeBlob, fieldTxnSignature, s.TxnSignature)
		if err != nil {
			return field{}, fmt.Errorf("signer %d: %w", i, err)
		}
		account, err := blobField(typeAccountID, fieldAccount, s.Account[:])
		if err != nil {
			return field{}, fmt.Errorf("signer %d: %w", i, err)
		}
		inner = append(inner, pubKey, sig, account)
		sortFields(inner)

		header := field{typeCode: typeSTObject, fieldCode: fieldSigner}
		payload = append(payload, header.header()...)
		for _, f := range inner {
			payload = append(payload, f.encode()...)
		}
		end := field{typeCode: typeSTObject, fieldCode: fieldObjectEndMarker}
		payload = append(payload, end.header()...)
	}

	endArray := field{typeCode: typeSTArray, fieldCode: fieldArrayEndMarker}
	payload = append(payload, endArray.header()...)

	return field{typeCode: typeSTArray, fieldCode: fieldSigners, payload: payload}, nil
}
