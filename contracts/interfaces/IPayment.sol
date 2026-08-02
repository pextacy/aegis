// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IPayment
/// @notice The FDC `Payment` attestation type.
/// @dev Declared locally for the same reason as IFtsoV2: flare-smart-contracts-v2
/// is not published as a package. The layout mirrors Flare's definition exactly
/// — the Merkle leaf is `keccak256(abi.encode(Response))`, so a reordered or
/// renamed field here would verify against a different hash and every proof
/// would be rejected.
interface IPayment {
    /// @notice What the attestation was asked about.
    struct RequestBody {
        /// @notice The transaction id on the source chain. For XRPL, the 32-byte hash.
        bytes32 transactionId;
        /// @notice Input index for UTXO chains. Zero on XRPL.
        uint256 inUtxo;
        /// @notice Output index for UTXO chains. Zero on XRPL.
        uint256 utxo;
    }

    /// @notice What the attestation found.
    struct ResponseBody {
        /// @notice The ledger index the transaction was included in.
        uint64 blockNumber;
        /// @notice The timestamp of that ledger.
        uint64 blockTimestamp;
        /// @notice `keccak256(abi.encode(sourceAddressString))`.
        bytes32 sourceAddressHash;
        /// @notice Merkle root over the source addresses. Unused on XRPL payments.
        bytes32 sourceAddressesRoot;
        /// @notice `keccak256(abi.encode(receivingAddressString))`.
        bytes32 receivingAddressHash;
        /// @notice The receiving address the sender intended, had the transaction succeeded.
        bytes32 intendedReceivingAddressHash;
        /// @notice Amount debited from the source, in the chain's base unit. Drops on XRPL, fee included.
        int256 spentAmount;
        /// @notice The amount the sender intended to spend.
        int256 intendedSpentAmount;
        /// @notice Amount credited to the receiver, in the chain's base unit.
        int256 receivedAmount;
        /// @notice The amount the receiver would have been credited.
        int256 intendedReceivedAmount;
        /// @notice The 32-byte reference carried by the transaction. Aegis puts
        /// `keccak256(abi.encode(requestId))` in the XRPL memo, and this is where
        /// it comes back.
        bytes32 standardPaymentReference;
        /// @notice True when the payment has exactly one source and one receiver.
        bool oneToOne;
        /// @notice `0` success, `1` failure attributable to the sender, `2` to the receiver.
        uint8 status;
    }

    /// @notice The attested response. This is what the Merkle leaf hashes.
    struct Response {
        bytes32 attestationType;
        bytes32 sourceId;
        uint64 votingRound;
        uint64 lowestUsedTimestamp;
        RequestBody requestBody;
        ResponseBody responseBody;
    }

    /// @notice A response together with its Merkle proof against the round's root.
    struct Proof {
        bytes32[] merkleProof;
        Response data;
    }
}
