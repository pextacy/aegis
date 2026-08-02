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
// Nothing is written to disk. A restart loses the keys, which is the stated v1
// limitation: one machine holds the key, and the k-of-n design that removes it
// is phase 6.
type keystore struct {
	mu   sync.RWMutex
	keys map[string]*treasuryKey
}

func newKeystore() *keystore {
	return &keystore{keys: make(map[string]*treasuryKey)}
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
	id := treasuryKeyOf(treasuryID)
	if id == "" {
		return nil, "", fmt.Errorf("treasury id is required")
	}

	k.mu.Lock()
	defer k.mu.Unlock()

	if _, exists := k.keys[id]; exists {
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

	k.keys[id] = &treasuryKey{
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

	out := make([]treasurySnapshot, 0, len(k.keys))
	for id, tk := range k.keys {
		out = append(out, treasurySnapshot{
			TreasuryID:         id,
			HasKey:             true,
			LastSignedSequence: tk.lastSignedSequence,
			ClassicAddress:     tk.classicAddress,
		})
	}
	return out
}

// treasurySnapshot is the internal shape of one treasury's observable state.
type treasurySnapshot struct {
	TreasuryID         string
	HasKey             bool
	LastSignedSequence uint32
	ClassicAddress     string
}
