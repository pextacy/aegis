package xrpl

import (
	"crypto/sha512"
	"fmt"

	"github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/ecdsa"
)

// Hash prefixes. XRPL domain-separates its hashes by prepending four bytes, so
// a signing hash can never collide with a transaction id.
var (
	// prefixSingleSign is "STX\0" — the hash that gets signed.
	prefixSingleSign = [4]byte{0x53, 0x54, 0x58, 0x00}

	// prefixTransactionID is "TXN\0" — the hash of a completed transaction.
	prefixTransactionID = [4]byte{0x54, 0x58, 0x4E, 0x00}

	// prefixMultiSign is "SMT\0". Multi-signing appends the signer's AccountID
	// to the payload; it belongs to the k-of-n work in phase 6 and is defined
	// here so the constant lives with the others rather than being rediscovered.
	prefixMultiSign = [4]byte{0x53, 0x4D, 0x54, 0x00} //nolint:unused // phase 6
)

// Hash is a 32-byte SHA-512Half digest.
type Hash [32]byte

// sha512Half hashes with SHA-512 and keeps the first half. Not SHA-256 — a
// common and silent mistake, because both produce something that looks right.
func sha512Half(prefix [4]byte, data []byte) Hash {
	h := sha512.New()
	h.Write(prefix[:])
	h.Write(data)
	sum := h.Sum(nil)

	var out Hash
	copy(out[:], sum[:32])
	return out
}

// SigningHash returns the digest that is signed for a single-signed transaction.
func (p *Payment) SigningHash() (Hash, error) {
	unsigned, err := p.Serialize(false)
	if err != nil {
		return Hash{}, fmt.Errorf("serialising for signing: %w", err)
	}
	return sha512Half(prefixSingleSign, unsigned), nil
}

// TransactionID returns the XRPL transaction id of a signed blob.
func TransactionID(signedBlob []byte) Hash {
	return sha512Half(prefixTransactionID, signedBlob)
}

// Sign produces the signed blob and its transaction id.
//
// The nonce is derived per RFC 6979 and the signature is DER-encoded with a low
// S value, both by btcec. Determinism is not a stylistic preference: it is what
// lets two TEE machines signing the same request produce identical bytes, which
// the k-of-n roadmap depends on.
//
// Sign sets SigningPubKey and TxnSignature on p, so the caller holds the same
// transaction that was signed rather than a reconstruction of it.
func (p *Payment) Sign(priv *btcec.PrivateKey) ([]byte, Hash, error) {
	if priv == nil {
		return nil, Hash{}, fmt.Errorf("xrpl: private key is nil")
	}

	p.SigningPubKey = priv.PubKey().SerializeCompressed()

	if err := p.Validate(); err != nil {
		return nil, Hash{}, err
	}

	// Every transaction this package signs forbids the malleable signature form.
	p.Flags |= TfFullyCanonicalSig

	digest, err := p.SigningHash()
	if err != nil {
		return nil, Hash{}, err
	}

	sig := ecdsa.Sign(priv, digest[:])
	p.TxnSignature = sig.Serialize()

	blob, err := p.Serialize(true)
	if err != nil {
		return nil, Hash{}, fmt.Errorf("serialising signed transaction: %w", err)
	}

	return blob, TransactionID(blob), nil
}

// VerifySignature checks a signed payment against its own SigningPubKey.
//
// Used to confirm that what the enclave produced is what the treasury key
// actually signed, rather than assuming the signing path was correct.
func (p *Payment) VerifySignature() (bool, error) {
	pub, err := btcec.ParsePubKey(p.SigningPubKey)
	if err != nil {
		return false, fmt.Errorf("parsing signing public key: %w", err)
	}

	sig, err := ecdsa.ParseDERSignature(p.TxnSignature)
	if err != nil {
		return false, fmt.Errorf("parsing signature: %w", err)
	}

	digest, err := p.SigningHash()
	if err != nil {
		return false, err
	}

	return sig.Verify(digest[:], pub), nil
}
