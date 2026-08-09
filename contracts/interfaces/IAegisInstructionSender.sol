// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IAegisInstructionSender
/// @notice The single point in Aegis that touches signing.
/// @dev Everything in PolicyEngine, TreasuryRegistry and PaymentController is
/// signing-agnostic. `SignRequest` carries structured fields rather than a
/// serialised blob precisely so a different signer consuming the same fields is
/// a drop-in replacement — which is what makes the PMW migration a module swap.
interface IAegisInstructionSender {
    /// @notice Fields the TEE receives and independently re-hashes.
    /// @dev The field order here is part of the policy digest. Changing it means
    /// changing PaymentController._policyDigest and the Go decoder registration
    /// in the same commit, or every payment fails with `policy digest mismatch`.
    struct SignRequest {
        uint256 requestId;
        uint256 treasuryId;
        bytes32 destinationAccountId;
        uint32 destinationTag;
        uint64 amountDrops;
        uint32 sequence;
        uint32 lastLedgerSequence;
        uint64 feeDrops;
        bytes32 policyDigest;
    }

    /// @notice Fields each of n enclaves receives and independently re-hashes.
    /// @dev The first eight are SignRequest's, unchanged, carrying the same
    /// `policyDigest` — so k-of-n inherits the single-key guarantee rather than
    /// restating it in a second shape that could drift.
    ///
    /// `sourceAccountId` is the addition. An enclave holding only a signer key
    /// does not know which treasury account it is signing for, so the account
    /// has to travel with the instruction; and anything that travels with an
    /// instruction is something the relay could alter. `multiSignDigest` is
    /// keccak256(abi.encode(policyDigest, sourceAccountId)), which binds the two
    /// without touching the digest every existing payment is validated against.
    struct MultiSignRequest {
        uint256 requestId;
        uint256 treasuryId;
        bytes32 sourceAccountId;
        bytes32 destinationAccountId;
        uint32 destinationTag;
        uint64 amountDrops;
        uint32 sequence;
        uint32 lastLedgerSequence;
        uint64 feeDrops;
        bytes32 policyDigest;
        bytes32 multiSignDigest;
    }

    /// @notice Sends a signing instruction to the TEE extension.
    /// @param request The structured payment fields plus the on-chain digest.
    /// @param cosigners Addresses the FCC layer requires signatures from.
    /// @param cosignersThreshold How many of `cosigners` must sign.
    function requestSignature(SignRequest calldata request, address[] calldata cosigners, uint8 cosignersThreshold)
        external
        payable;

    /// @notice Sends a k-of-n signing instruction to every machine in the set.
    /// @dev Each machine returns its own signature and none returns a
    /// transaction, because one enclave under k-of-n has authorised nothing.
    /// @param request The structured payment fields plus both digests.
    /// @param cosigners Addresses the FCC layer requires signatures from.
    /// @param cosignersThreshold How many of `cosigners` must sign.
    function requestMultiSignature(
        MultiSignRequest calldata request,
        address[] calldata cosigners,
        uint8 cosignersThreshold
    ) external payable;
}
