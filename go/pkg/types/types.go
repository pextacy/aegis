// Package types contains types that could be useful to other apps when interacting with this extension.
package types

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
)

// SignRequest is the ABI-decoded payload of a SIGNTX instruction.
//
// It carries structured fields rather than a pre-serialised XRPL blob. That is
// deliberate: the enclave rebuilds the transaction itself and recomputes the
// policy digest over these exact fields, so a relayer that alters one of them
// produces a mismatch instead of a signature. It is also what makes a different
// signer — PMW, when its interface is public — a drop-in replacement.
//
// The field order is part of the digest. Changing it means changing
// PaymentController._policyDigest and the decoder registration in the same
// commit, or every payment fails with "policy digest mismatch".
type SignRequest struct {
	RequestId            *big.Int `json:"requestId"`
	TreasuryId           *big.Int `json:"treasuryId"`
	DestinationAccountId [32]byte `json:"destinationAccountId"`
	DestinationTag       uint32   `json:"destinationTag"`
	AmountDrops          uint64   `json:"amountDrops"`
	Sequence             uint32   `json:"sequence"`
	LastLedgerSequence   uint32   `json:"lastLedgerSequence"`
	FeeDrops             uint64   `json:"feeDrops"`
	PolicyDigest         [32]byte `json:"policyDigest"`
}

// SignResponse is the ABI-encoded result of a successful SIGNTX.
type SignResponse struct {
	SignedBlob []byte   `json:"signedBlob"`
	TxHash     [32]byte `json:"txHash"`
}

// MultiSignRequest is the ABI-decoded payload of an MSIGN instruction.
//
// The first eight fields are exactly SignRequest's, and PolicyDigest is exactly
// the value PaymentController already computes over them, so the k-of-n path
// inherits the single-signature path's guarantee unchanged rather than
// introducing a second, differently-shaped one.
//
// SourceAccountId is the addition, and it needs its own digest rather than a
// place in the policy digest. A machine holding only a signer key does not know
// which account it is signing for, so the sending account has to arrive with the
// instruction — and anything that arrives with an instruction is something a
// relayer could alter. MultiSignDigest is keccak256(abi.encode(policyDigest,
// sourceAccountId)), which binds the two together without changing the digest
// every existing payment is already validated against.
type MultiSignRequest struct {
	RequestId            *big.Int `json:"requestId"`
	TreasuryId           *big.Int `json:"treasuryId"`
	SourceAccountId      [32]byte `json:"sourceAccountId"`
	DestinationAccountId [32]byte `json:"destinationAccountId"`
	DestinationTag       uint32   `json:"destinationTag"`
	AmountDrops          uint64   `json:"amountDrops"`
	Sequence             uint32   `json:"sequence"`
	LastLedgerSequence   uint32   `json:"lastLedgerSequence"`
	FeeDrops             uint64   `json:"feeDrops"`
	PolicyDigest         [32]byte `json:"policyDigest"`
	MultiSignDigest      [32]byte `json:"multiSignDigest"`
}

// PartialSignatureResponse is the ABI-encoded result of a successful MSIGN.
//
// One enclave's contribution and nothing more. It is deliberately not a
// submittable transaction: a single machine authorises nothing under k-of-n, and
// returning something that looked complete would misrepresent that.
//
// The signer's account is not returned, because PaymentController derives it
// from the key with the same precompiles it uses for KEYGEN. One source of
// truth means there is no pair of fields that could disagree.
type PartialSignatureResponse struct {
	SignerPubKey []byte `json:"signerPubKey"`
	Signature    []byte `json:"signature"`
}

// Setup transaction kinds. A treasury moves to k-of-n in two steps, in this
// order, and the order is not a preference: XRPL refuses to disable a master key
// unless another way to authorise already exists.
const (
	// SetupKindSignerList installs the SignerList that delegates authority over
	// the treasury account to the n enclave-held signer keys.
	SetupKindSignerList uint8 = 0

	// SetupKindDisableMasterKey retires the key that created the account. Until
	// it is set, the signer list is an additional authority rather than the only
	// one, and the machine holding the master key could still pay alone.
	SetupKindDisableMasterKey uint8 = 1
)

// SetupRequest is the ABI-decoded payload of a SETUP instruction.
//
// Both setup transactions are signed with the treasury's master key, because
// delegating away from that key is the one thing only that key can authorise.
// Only the machine that ran KEYGEN holds it, so the instruction is fanned out to
// every machine and the rest refuse for want of a key — which is the same
// refusal an unknown treasury gets, not a special case.
type SetupRequest struct {
	TreasuryId         *big.Int   `json:"treasuryId"`
	Kind               uint8      `json:"kind"`
	Quorum             uint32     `json:"quorum"`
	SignerAccountIds   [][32]byte `json:"signerAccountIds"`
	Sequence           uint32     `json:"sequence"`
	LastLedgerSequence uint32     `json:"lastLedgerSequence"`
	FeeDrops           uint64     `json:"feeDrops"`
	SetupDigest        [32]byte   `json:"setupDigest"`
}

// KeygenRequest is the ABI-decoded payload of a KEYGEN instruction.
type KeygenRequest struct {
	TreasuryId *big.Int `json:"treasuryId"`
}

// KeygenResponse is the ABI-encoded result of a successful KEYGEN.
//
// It carries the public key and the address derived from it, and nothing else.
// The private key never leaves the enclave — not here, not in a log, not in
// /state.
type KeygenResponse struct {
	CompressedPubKey []byte `json:"compressedPubKey"`
	ClassicAddress   string `json:"classicAddress"`
}

// StatusRequest is the ABI-decoded payload of a STATUS instruction.
type StatusRequest struct {
	TreasuryId *big.Int `json:"treasuryId"`
}

// StatusResponse is the ABI-encoded result of STATUS.
type StatusResponse struct {
	HasKey             bool   `json:"hasKey"`
	LastSignedSequence uint32 `json:"lastSignedSequence"`
}

// TreasuryState is what GET /state reveals about one treasury: whether a key
// exists and how far its sequence has advanced. Never the key.
type TreasuryState struct {
	TreasuryId         string `json:"treasuryId"`
	HasKey             bool   `json:"hasKey"`
	HasSignerKey       bool   `json:"hasSignerKey"`
	LastSignedSequence uint32 `json:"lastSignedSequence"`
	ClassicAddress     string `json:"classicAddress"`
	SignerAddress      string `json:"signerAddress"`
}

// State holds the extension's observable state, returned by GET /state.
//
// Booleans, counters, addresses and sequence numbers only. If a field here
// could ever hold key material, the design is wrong.
type State struct {
	Treasuries        []TreasuryState `json:"treasuries"`
	KeygenCount       int             `json:"keygenCount"`
	SignerKeygenCount int             `json:"signerKeygenCount"`
	SignedCount       int             `json:"signedCount"`
	MultiSignedCount  int             `json:"multiSignedCount"`
	SetupCount        int             `json:"setupCount"`
	RejectedCount     int             `json:"rejectedCount"`
	LastRejectedLog   string          `json:"lastRejectedLog"`
}

// --- DO NOT MODIFY below this line. ---

// StateResponse is the envelope returned by GET /state.
type StateResponse struct {
	StateVersion common.Hash `json:"stateVersion"`
	State        State       `json:"state"`
}
