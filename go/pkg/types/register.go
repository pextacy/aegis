package types

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/crypto"
)

// ABI argument definitions for every message and result pair the extension
// handles. These are the Go half of the wire contract with
// AegisInstructionSender.sol; the two must be changed together.
var (
	// SignRequestArg mirrors the SignRequest struct the contract encodes.
	SignRequestArg abi.Argument

	// TreasuryIdArgs is the message shape for KEYGEN and STATUS, both of which
	// carry a bare uint256.
	TreasuryIdArgs abi.Arguments

	// SignResponseArgs is (bytes signedBlob, bytes32 txHash).
	SignResponseArgs abi.Arguments

	// KeygenResponseArgs is (bytes compressedPubKey, string classicAddress).
	KeygenResponseArgs abi.Arguments

	// StatusResponseArgs is (bool hasKey, uint32 lastSignedSequence).
	StatusResponseArgs abi.Arguments

	// policyDigestArgs is the exact tuple PaymentController hashes. The order is
	// load-bearing — see ComputePolicyDigest.
	policyDigestArgs abi.Arguments

	// requestReferenceArgs is abi.encode(requestId), hashed into the XRPL memo.
	requestReferenceArgs abi.Arguments
)

func init() {
	mustType := func(t string, components []abi.ArgumentMarshaling) abi.Type {
		ty, err := abi.NewType(t, "", components)
		if err != nil {
			panic(fmt.Sprintf("registering ABI type %q: %v", t, err))
		}
		return ty
	}

	uint256Ty := mustType("uint256", nil)
	uint64Ty := mustType("uint64", nil)
	uint32Ty := mustType("uint32", nil)
	bytes32Ty := mustType("bytes32", nil)
	bytesTy := mustType("bytes", nil)
	stringTy := mustType("string", nil)
	boolTy := mustType("bool", nil)

	// Component names must match the Solidity struct field names: go-ethereum
	// maps a tuple onto a Go struct by capitalising them.
	signRequestTy := mustType("tuple", []abi.ArgumentMarshaling{
		{Name: "requestId", Type: "uint256"},
		{Name: "treasuryId", Type: "uint256"},
		{Name: "destinationAccountId", Type: "bytes32"},
		{Name: "destinationTag", Type: "uint32"},
		{Name: "amountDrops", Type: "uint64"},
		{Name: "sequence", Type: "uint32"},
		{Name: "lastLedgerSequence", Type: "uint32"},
		{Name: "feeDrops", Type: "uint64"},
		{Name: "policyDigest", Type: "bytes32"},
	})
	SignRequestArg = abi.Argument{Type: signRequestTy}

	TreasuryIdArgs = abi.Arguments{{Type: uint256Ty, Name: "treasuryId"}}

	SignResponseArgs = abi.Arguments{
		{Type: bytesTy, Name: "signedBlob"},
		{Type: bytes32Ty, Name: "txHash"},
	}

	KeygenResponseArgs = abi.Arguments{
		{Type: bytesTy, Name: "compressedPubKey"},
		{Type: stringTy, Name: "classicAddress"},
	}

	StatusResponseArgs = abi.Arguments{
		{Type: boolTy, Name: "hasKey"},
		{Type: uint32Ty, Name: "lastSignedSequence"},
	}

	policyDigestArgs = abi.Arguments{
		{Type: uint256Ty}, // requestId
		{Type: uint256Ty}, // treasuryId
		{Type: bytes32Ty}, // destinationAccountId
		{Type: uint32Ty},  // destinationTag
		{Type: uint64Ty},  // amountDrops
		{Type: uint32Ty},  // sequence
		{Type: uint32Ty},  // lastLedgerSequence
		{Type: uint64Ty},  // feeDrops
	}

	requestReferenceArgs = abi.Arguments{{Type: uint256Ty}}
}

// ComputePolicyDigest recomputes the digest PaymentController produced on-chain.
//
// This is the single most important function in the extension. The relay path
// from the contract to here is trusted only to the signature threshold, not to
// preserve payload integrity, so the enclave rebuilds the digest from the fields
// it actually decoded and refuses to sign unless it matches. A relayer that
// swaps the destination address gets a mismatch rather than a signature.
//
// It must stay byte-identical to:
//
//	keccak256(abi.encode(
//	    requestId, treasuryId, destinationAccountId, destinationTag,
//	    amountDrops, sequence, lastLedgerSequence, feeDrops
//	))
func (r *SignRequest) ComputePolicyDigest() ([32]byte, error) {
	requestId := r.RequestId
	if requestId == nil {
		requestId = new(big.Int)
	}
	treasuryId := r.TreasuryId
	if treasuryId == nil {
		treasuryId = new(big.Int)
	}

	packed, err := policyDigestArgs.Pack(
		requestId,
		treasuryId,
		r.DestinationAccountId,
		r.DestinationTag,
		r.AmountDrops,
		r.Sequence,
		r.LastLedgerSequence,
		r.FeeDrops,
	)
	if err != nil {
		return [32]byte{}, fmt.Errorf("packing policy digest fields: %w", err)
	}

	var out [32]byte
	copy(out[:], crypto.Keccak256(packed))
	return out, nil
}

// RequestReference is the 32-byte value carried in the XRPL memo, linking a
// settled transaction back to the on-chain request that authorised it.
//
// ExecutionVerifier matches the FDC payment reference against
// keccak256(abi.encode(requestId)). This function and that check must change
// together, or a settlement can never be proven.
func RequestReference(requestID *big.Int) ([32]byte, error) {
	if requestID == nil {
		return [32]byte{}, fmt.Errorf("request id is required")
	}

	packed, err := requestReferenceArgs.Pack(requestID)
	if err != nil {
		return [32]byte{}, fmt.Errorf("packing request reference: %w", err)
	}

	var out [32]byte
	copy(out[:], crypto.Keccak256(packed))
	return out, nil
}

// DigestMatches reports whether the digest the contract sent agrees with the one
// derived from the fields that actually arrived.
func (r *SignRequest) DigestMatches() (bool, error) {
	computed, err := r.ComputePolicyDigest()
	if err != nil {
		return false, err
	}
	return computed == r.PolicyDigest, nil
}
