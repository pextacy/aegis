package xrpl

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"math/big"

	"golang.org/x/crypto/ripemd160" //nolint:staticcheck // XRPL AccountIDs are defined in terms of RIPEMD-160; there is no alternative.
)

// alphabet is XRPL's base58 alphabet. It is deliberately not Bitcoin's — the
// same bytes encode to a different string under each.
const alphabet = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz"

// accountPrefix is the version byte for a classic address.
const accountPrefix byte = 0x00

// compressedPubKeyLength is a secp256k1 key as XRPL carries it: a 0x02 or 0x03
// parity prefix followed by the X coordinate.
const compressedPubKeyLength = 33

var (
	// ErrBadPubKeyLength rejects a key that is not 33 bytes.
	ErrBadPubKeyLength = errors.New("xrpl: compressed public key must be 33 bytes")

	// ErrBadChecksum rejects an address whose checksum does not verify.
	ErrBadChecksum = errors.New("xrpl: address checksum mismatch")

	// ErrBadAddress rejects an address that is not valid base58check.
	ErrBadAddress = errors.New("xrpl: malformed classic address")
)

// AccountIDFromPubKey derives the AccountID as RIPEMD-160 of SHA-256 of the key.
func AccountIDFromPubKey(compressedPubKey []byte) (AccountID, error) {
	var id AccountID
	if len(compressedPubKey) != compressedPubKeyLength {
		return id, fmt.Errorf("%w: got %d", ErrBadPubKeyLength, len(compressedPubKey))
	}

	inner := sha256.Sum256(compressedPubKey)
	h := ripemd160.New()
	if _, err := h.Write(inner[:]); err != nil {
		return id, fmt.Errorf("hashing public key: %w", err)
	}
	copy(id[:], h.Sum(nil))
	return id, nil
}

// EncodeClassicAddress renders an AccountID as a base58check classic address.
func EncodeClassicAddress(id AccountID) string {
	payload := append([]byte{accountPrefix}, id[:]...)
	return base58CheckEncode(payload)
}

// DecodeClassicAddress parses a classic address back to an AccountID.
//
// Used to check that an address matches the key it claims to belong to, rather
// than trusting whoever supplied the pair.
func DecodeClassicAddress(addr string) (AccountID, error) {
	var id AccountID

	decoded, err := base58Decode(addr)
	if err != nil {
		return id, err
	}
	if len(decoded) != 1+len(id)+4 {
		return id, fmt.Errorf("%w: %d bytes", ErrBadAddress, len(decoded))
	}
	if decoded[0] != accountPrefix {
		return id, fmt.Errorf("%w: version byte 0x%02x", ErrBadAddress, decoded[0])
	}

	body, want := decoded[:len(decoded)-4], decoded[len(decoded)-4:]
	if !bytes.Equal(checksum(body), want) {
		return id, ErrBadChecksum
	}

	copy(id[:], body[1:])
	return id, nil
}

// DeriveAccount returns both the AccountID and classic address for a key.
func DeriveAccount(compressedPubKey []byte) (AccountID, string, error) {
	id, err := AccountIDFromPubKey(compressedPubKey)
	if err != nil {
		return AccountID{}, "", err
	}
	return id, EncodeClassicAddress(id), nil
}

// checksum is the first four bytes of a double SHA-256.
func checksum(payload []byte) []byte {
	first := sha256.Sum256(payload)
	second := sha256.Sum256(first[:])
	return second[:4]
}

func base58CheckEncode(payload []byte) string {
	full := append(append([]byte{}, payload...), checksum(payload)...)

	// Every leading zero byte encodes to one leading alphabet[0], which the
	// big-integer conversion below cannot represent on its own.
	leading := 0
	for leading < len(full) && full[leading] == 0 {
		leading++
	}

	num := new(big.Int).SetBytes(full)
	base := big.NewInt(58)
	mod := new(big.Int)

	var reversed []byte
	for num.Sign() > 0 {
		num.DivMod(num, base, mod)
		reversed = append(reversed, alphabet[mod.Int64()])
	}

	out := make([]byte, 0, leading+len(reversed))
	for i := 0; i < leading; i++ {
		out = append(out, alphabet[0])
	}
	for i := len(reversed) - 1; i >= 0; i-- {
		out = append(out, reversed[i])
	}
	return string(out)
}

func base58Decode(s string) ([]byte, error) {
	num := big.NewInt(0)
	base := big.NewInt(58)

	for _, r := range s {
		idx := bytes.IndexByte([]byte(alphabet), byte(r))
		if idx < 0 || r > 127 {
			return nil, fmt.Errorf("%w: character %q is not in the XRPL alphabet", ErrBadAddress, r)
		}
		num.Mul(num, base)
		num.Add(num, big.NewInt(int64(idx)))
	}

	leading := 0
	for leading < len(s) && s[leading] == alphabet[0] {
		leading++
	}

	body := num.Bytes()
	out := make([]byte, leading+len(body))
	copy(out[leading:], body)
	return out, nil
}
