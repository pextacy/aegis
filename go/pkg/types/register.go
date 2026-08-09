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

	// MultiSignRequestArg mirrors the MultiSignRequest struct the contract
	// encodes for MSIGN.
	MultiSignRequestArg abi.Argument

	// PartialSignatureResponseArgs is (bytes signerPubKey, bytes signature).
	PartialSignatureResponseArgs abi.Arguments

	// SetupRequestArg mirrors the SetupRequest struct the contract encodes for
	// SETUP.
	SetupRequestArg abi.Argument

	// multiSignDigestArgs is the tuple binding a policy digest to the account it
	// authorises a payment from.
	multiSignDigestArgs abi.Arguments

	// setupDigestArgs is the tuple AegisInstructionSender hashes for a SETUP
	// instruction. Field order is load-bearing in the same way the policy
	// digest's is.
	setupDigestArgs abi.Arguments

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

	uint8Ty := mustType("uint8", nil)
	bytes32ArrayTy := mustType("bytes32[]", nil)

	multiSignRequestTy := mustType("tuple", []abi.ArgumentMarshaling{
		{Name: "requestId", Type: "uint256"},
		{Name: "treasuryId", Type: "uint256"},
		{Name: "sourceAccountId", Type: "bytes32"},
		{Name: "destinationAccountId", Type: "bytes32"},
		{Name: "destinationTag", Type: "uint32"},
		{Name: "amountDrops", Type: "uint64"},
		{Name: "sequence", Type: "uint32"},
		{Name: "lastLedgerSequence", Type: "uint32"},
		{Name: "feeDrops", Type: "uint64"},
		{Name: "policyDigest", Type: "bytes32"},
		{Name: "multiSignDigest", Type: "bytes32"},
	})
	MultiSignRequestArg = abi.Argument{Type: multiSignRequestTy}

	PartialSignatureResponseArgs = abi.Arguments{
		{Type: bytesTy, Name: "signerPubKey"},
		{Type: bytesTy, Name: "signature"},
	}

	setupRequestTy := mustType("tuple", []abi.ArgumentMarshaling{
		{Name: "treasuryId", Type: "uint256"},
		{Name: "kind", Type: "uint8"},
		{Name: "quorum", Type: "uint32"},
		{Name: "signerAccountIds", Type: "bytes32[]"},
		{Name: "sequence", Type: "uint32"},
		{Name: "lastLedgerSequence", Type: "uint32"},
		{Name: "feeDrops", Type: "uint64"},
		{Name: "setupDigest", Type: "bytes32"},
	})
	SetupRequestArg = abi.Argument{Type: setupRequestTy}

	multiSignDigestArgs = abi.Arguments{
		{Type: bytes32Ty}, // policyDigest
		{Type: bytes32Ty}, // sourceAccountId
	}

	setupDigestArgs = abi.Arguments{
		{Type: uint256Ty},      // treasuryId
		{Type: uint8Ty},        // kind
		{Type: uint32Ty},       // quorum
		{Type: bytes32ArrayTy}, // signerAccountIds
		{Type: uint32Ty},       // sequence
		{Type: uint32Ty},       // lastLedgerSequence
		{Type: uint64Ty},       // feeDrops
	}
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

// SignRequest converts a multi-signing request to the single-signing shape.
//
// The eight policy-bearing fields are identical in both, so the k-of-n path
// reuses ComputePolicyDigest rather than restating it. A second implementation
// of that hash is a second thing that can drift from the contract.
func (r *MultiSignRequest) SignRequest() SignRequest {
	return SignRequest{
		RequestId:            r.RequestId,
		TreasuryId:           r.TreasuryId,
		DestinationAccountId: r.DestinationAccountId,
		DestinationTag:       r.DestinationTag,
		AmountDrops:          r.AmountDrops,
		Sequence:             r.Sequence,
		LastLedgerSequence:   r.LastLedgerSequence,
		FeeDrops:             r.FeeDrops,
		PolicyDigest:         r.PolicyDigest,
	}
}

// ComputeMultiSignDigest recomputes the digest binding the policy digest to the
// account the payment is authorised to leave.
//
// It must stay byte-identical to:
//
//	keccak256(abi.encode(policyDigest, sourceAccountId))
func (r *MultiSignRequest) ComputeMultiSignDigest() ([32]byte, error) {
	packed, err := multiSignDigestArgs.Pack(r.PolicyDigest, r.SourceAccountId)
	if err != nil {
		return [32]byte{}, fmt.Errorf("packing multi-sign digest fields: %w", err)
	}

	var out [32]byte
	copy(out[:], crypto.Keccak256(packed))
	return out, nil
}

// MultiSignDigestMatches reports whether the account the payment would leave is
// the account the contract authorised it to leave.
//
// Checked separately from the policy digest, and both must pass. The policy
// digest says the payment is the one the contract approved; this one says it
// comes out of the right treasury. A machine holding only a signer key cannot
// know the second from its own state, which is exactly why it has to be proven
// rather than assumed.
func (r *MultiSignRequest) MultiSignDigestMatches() (bool, error) {
	computed, err := r.ComputeMultiSignDigest()
	if err != nil {
		return false, err
	}
	return computed == r.MultiSignDigest, nil
}

// ComputeSetupDigest recomputes the digest a SETUP instruction carries.
//
// It must stay byte-identical to:
//
//	keccak256(abi.encode(
//	    treasuryId, kind, quorum, signerAccountIds,
//	    sequence, lastLedgerSequence, feeDrops
//	))
//
// Installing a signer list is the act that decides who can ever spend from the
// treasury again, so it is checked in the enclave exactly as a payment is. A
// relayer that added one account to the list would otherwise have added itself
// to every future quorum.
func (s *SetupRequest) ComputeSetupDigest() ([32]byte, error) {
	treasuryID := s.TreasuryId
	if treasuryID == nil {
		treasuryID = new(big.Int)
	}
	signers := s.SignerAccountIds
	if signers == nil {
		signers = [][32]byte{}
	}

	packed, err := setupDigestArgs.Pack(
		treasuryID,
		s.Kind,
		s.Quorum,
		signers,
		s.Sequence,
		s.LastLedgerSequence,
		s.FeeDrops,
	)
	if err != nil {
		return [32]byte{}, fmt.Errorf("packing setup digest fields: %w", err)
	}

	var out [32]byte
	copy(out[:], crypto.Keccak256(packed))
	return out, nil
}

// DigestMatches reports whether the setup digest agrees with the fields that
// arrived.
func (s *SetupRequest) DigestMatches() (bool, error) {
	computed, err := s.ComputeSetupDigest()
	if err != nil {
		return false, err
	}
	return computed == s.SetupDigest, nil
}
