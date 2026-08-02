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

    /// @notice Sends a signing instruction to the TEE extension.
    /// @param request The structured payment fields plus the on-chain digest.
    /// @param cosigners Addresses the FCC layer requires signatures from.
    /// @param cosignersThreshold How many of `cosigners` must sign.
    function requestSignature(SignRequest calldata request, address[] calldata cosigners, uint8 cosignersThreshold)
        external
        payable;
}
