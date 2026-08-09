package extension

import (
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"sync"

	"extension-scaffold/internal/xrpl"

	"github.com/btcsuite/btcd/btcec/v2"
)

// treasuryKey is one treasury's XRPL identity inside the enclave.
//
// The private key is unexported and no method returns it. That is the whole
// point of the type: there is no code path from an HTTP response or a log line
// back to this field.
type treasuryKey struct {
	priv *btcec.PrivateKey

	accountID      xrpl.AccountID
	classicAddress string
	pubKey         []byte

	lastSignedSequence uint32
}

var (
	// ErrNoKey is returned for a treasury the enclave has never generated a key
	// for. There is no fallback and no lazy generation — a signing request for
	// an unknown treasury is refused.
	ErrNoKey = errors.New("no key for treasury")

	// ErrKeyExists prevents a second KEYGEN from replacing a live key, which
	// would strand every XRP already sent to the first address.
	ErrKeyExists = errors.New("treasury already has a key")
)

// keystore holds treasury keys in process memory, guarded by a mutex.
//
// Nothing is written to disk. A restart loses this machine's keys — which under
// k-of-n costs a treasury one signature out of n rather than the treasury, and
// under single-signing costs it everything. That difference is the whole reason
// the signer keys exist.
//
// Master keys and signer keys are held in separate maps rather than one map with
// a role field. A machine can legitimately hold both for the same treasury: it
// generated the account and it is also one of the n signers. Keeping them apart
// means a lookup for one can never return the other, so "sign this payment"
// cannot reach the key that was retired precisely so it could not sign payments.
type keystore struct {
	mu      sync.RWMutex
	keys    map[string]*treasuryKey
	signers map[string]*treasuryKey
}

func newKeystore() *keystore {
	return &keystore{
		keys:    make(map[string]*treasuryKey),
		signers: make(map[string]*treasuryKey),
	}
}

// key returns the map key for a treasury id.
func treasuryKeyOf(treasuryID *big.Int) string {
	if treasuryID == nil {
		return ""
	}
	return treasuryID.String()
}

// Generate creates a treasury's key inside the enclave using crypto/rand.
//
// Keys are born here and never imported. The scaffold ships an ECIES decrypt
// endpoint for importing one, but an encrypted key sent through calldata is
// permanent public storage, and encryption breaks given enough time.
func (k *keystore) Generate(treasuryID *big.Int) (pubKey []byte, classicAddress string, err error) {
	return k.generate(treasuryID, false)
}

// GenerateSigner creates this machine's signer key for a treasury.
//
// Separate from the master key and generated the same way, in the enclave, from
// crypto/rand. A machine may hold both: it can be the one that created the
// account and also one of the n signers that will authorise its payments once
// the master key is retired.
func (k *keystore) GenerateSigner(treasuryID *big.Int) (pubKey []byte, classicAddress string, err error) {
	return k.generate(treasuryID, true)
}

func (k *keystore) generate(treasuryID *big.Int, signer bool) (pubKey []byte, classicAddress string, err error) {
	id := treasuryKeyOf(treasuryID)
	if id == "" {
		return nil, "", fmt.Errorf("treasury id is required")
	}

	k.mu.Lock()
	defer k.mu.Unlock()

	store := k.keys
	if signer {
		store = k.signers
	}

	if _, exists := store[id]; exists {
		return nil, "", fmt.Errorf("%w: %s", ErrKeyExists, id)
	}

	priv, err := btcec.NewPrivateKey()
	if err != nil {
		return nil, "", fmt.Errorf("generating key: %w", err)
	}
	// btcec reads from crypto/rand; assert it rather than assume it.
	if _, err := rand.Read(make([]byte, 1)); err != nil {
		return nil, "", fmt.Errorf("entropy source unavailable: %w", err)
	}

	compressed := priv.PubKey().SerializeCompressed()
	accountID, addr, err := xrpl.DeriveAccount(compressed)
	if err != nil {
		return nil, "", fmt.Errorf("deriving account: %w", err)
	}

	store[id] = &treasuryKey{
		priv:           priv,
		accountID:      accountID,
		classicAddress: addr,
		pubKey:         compressed,
	}

	return compressed, addr, nil
}

// Sign builds and signs the payment for a treasury, under the lock.
//
// The caller has already checked the policy digest. This function does not
// re-check it, and must never be called before that check passes.
func (k *keystore) Sign(treasuryID *big.Int, p *xrpl.Payment) (blob []byte, txHash xrpl.Hash, err error) {
	id := treasuryKeyOf(treasuryID)

	k.mu.Lock()
	defer k.mu.Unlock()

	tk, ok := k.keys[id]
	if !ok {
		return nil, xrpl.Hash{}, fmt.Errorf("%w: %s", ErrNoKey, id)
	}

	p.Account = tk.accountID

	blob, txHash, err = p.Sign(tk.priv)
	if err != nil {
		return nil, xrpl.Hash{}, err
	}

	if p.Sequence > tk.lastSignedSequence {
		tk.lastSignedSequence = p.Sequence
	}

	return blob, txHash, nil
}

// MultiSign produces this machine's contribution to a k-of-n signature.
//
// It uses the signer key, never the master key. The sending account arrives with
// the request rather than coming from this machine's own state, because a signer
// key belongs to the signer and not to the treasury — the caller has already
// proven that account against the multi-sign digest, and this function must not
// be called before that check passes.
//
// The returned Signer authorises nothing on its own. That is the point.
func (k *keystore) MultiSign(treasuryID *big.Int, p *xrpl.Payment) (xrpl.Signer, error) {
	id := treasuryKeyOf(treasuryID)

	k.mu.Lock()
	defer k.mu.Unlock()

	tk, ok := k.signers[id]
	if !ok {
		return xrpl.Signer{}, fmt.Errorf("%w: no signer key for treasury %s", ErrNoKey, id)
	}

	signature, err := p.MultiSign(tk.priv)
	if err != nil {
		return xrpl.Signer{}, err
	}

	if p.Sequence > tk.lastSignedSequence {
		tk.lastSignedSequence = p.Sequence
	}

	return signature, nil
}

// SignSignerList signs the transaction that hands authority over a treasury's
// XRPL account to its signer set.
//
// The account is taken from this machine's own master key rather than from the
// instruction. A relayer that could choose the account could install a signer
// list on one it controls and have the enclave vouch for it.
func (k *keystore) SignSignerList(treasuryID *big.Int, tx *xrpl.SignerListSet) ([]byte, xrpl.Hash, error) {
	id := treasuryKeyOf(treasuryID)

	k.mu.Lock()
	defer k.mu.Unlock()

	tk, ok := k.keys[id]
	if !ok {
		return nil, xrpl.Hash{}, fmt.Errorf("%w: no master key for treasury %s", ErrNoKey, id)
	}

	tx.Account = tk.accountID
	return tx.Sign(tk.priv)
}

// SignAccountSet signs the transaction that retires a treasury's master key.
//
// The last thing this key is asked to do is make itself unusable, which is what
// turns the signer list from an additional authority into the only one.
func (k *keystore) SignAccountSet(treasuryID *big.Int, tx *xrpl.AccountSet) ([]byte, xrpl.Hash, error) {
	id := treasuryKeyOf(treasuryID)

	k.mu.Lock()
	defer k.mu.Unlock()

	tk, ok := k.keys[id]
	if !ok {
		return nil, xrpl.Hash{}, fmt.Errorf("%w: no master key for treasury %s", ErrNoKey, id)
	}

	tx.Account = tk.accountID
	return tx.Sign(tk.priv)
}

// Status reports whether a treasury has a key and how far its sequence has gone.
func (k *keystore) Status(treasuryID *big.Int) (hasKey bool, lastSignedSequence uint32) {
	id := treasuryKeyOf(treasuryID)

	k.mu.RLock()
	defer k.mu.RUnlock()

	tk, ok := k.keys[id]
	if !ok {
		return false, 0
	}
	return true, tk.lastSignedSequence
}

// AccountID returns a treasury's XRPL AccountID, which is public information.
func (k *keystore) AccountID(treasuryID *big.Int) (xrpl.AccountID, bool) {
	k.mu.RLock()
	defer k.mu.RUnlock()

	tk, ok := k.keys[treasuryKeyOf(treasuryID)]
	if !ok {
		return xrpl.AccountID{}, false
	}
	return tk.accountID, true
}

// snapshot returns the public view of every treasury, for GET /state.
//
// Booleans, addresses and sequence numbers. Never a key.
func (k *keystore) snapshot() []treasurySnapshot {
	k.mu.RLock()
	defer k.mu.RUnlock()

	byTreasury := make(map[string]*treasurySnapshot, len(k.keys)+len(k.signers))
	at := func(id string) *treasurySnapshot {
		s, ok := byTreasury[id]
		if !ok {
			s = &treasurySnapshot{TreasuryID: id}
			byTreasury[id] = s
		}
		return s
	}

	for id, tk := range k.keys {
		s := at(id)
		s.HasKey = true
		s.ClassicAddress = tk.classicAddress
		if tk.lastSignedSequence > s.LastSignedSequence {
			s.LastSignedSequence = tk.lastSignedSequence
		}
	}
	for id, tk := range k.signers {
		s := at(id)
		s.HasSignerKey = true
		s.SignerAddress = tk.classicAddress
		if tk.lastSignedSequence > s.LastSignedSequence {
			s.LastSignedSequence = tk.lastSignedSequence
		}
	}

	out := make([]treasurySnapshot, 0, len(byTreasury))
	for _, s := range byTreasury {
		out = append(out, *s)
	}
	return out
}

// treasurySnapshot is the internal shape of one treasury's observable state.
//
// Two addresses, because they mean different things: ClassicAddress is the
// treasury's own XRPL account, and SignerAddress is this machine's identity
// within that account's signer list. Both are public information derived from
// public keys. Neither is a key.
type treasurySnapshot struct {
	TreasuryID         string
	HasKey             bool
	HasSignerKey       bool
	LastSignedSequence uint32
	ClassicAddress     string
	SignerAddress      string
}
