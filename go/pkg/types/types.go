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
	LastSignedSequence uint32 `json:"lastSignedSequence"`
	ClassicAddress     string `json:"classicAddress"`
}

// State holds the extension's observable state, returned by GET /state.
//
// Booleans, counters, addresses and sequence numbers only. If a field here
// could ever hold key material, the design is wrong.
type State struct {
	Treasuries      []TreasuryState `json:"treasuries"`
	KeygenCount     int             `json:"keygenCount"`
	SignedCount     int             `json:"signedCount"`
	RejectedCount   int             `json:"rejectedCount"`
	LastRejectedLog string          `json:"lastRejectedLog"`
}

// --- DO NOT MODIFY below this line. ---

// StateResponse is the envelope returned by GET /state.
type StateResponse struct {
	StateVersion common.Hash `json:"stateVersion"`
	State        State       `json:"state"`
}
