// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IReferencedPaymentNonexistence
/// @notice The FDC `ReferencedPaymentNonexistence` attestation type.
/// @dev Proves that no successful payment carrying `standardPaymentReference`,
/// paying at least `amount` to `destinationAddressHash`, appeared in the block
/// range the request names. The interesting fields are in the *request* body:
/// what was asked is what was proven absent, so a caller that accepts a proof
/// without checking the request body has proven nothing about its own payment.
interface IReferencedPaymentNonexistence {
    /// @notice The payment whose absence is asserted, and the range searched.
    struct RequestBody {
        /// @notice First block of the searched range, inclusive.
        uint64 minimalBlockNumber;
        /// @notice Last block of the searched range, inclusive.
        uint64 deadlineBlockNumber;
        /// @notice Last timestamp of the searched range, inclusive.
        uint64 deadlineTimestamp;
        /// @notice `keccak256(abi.encode(destinationAddressString))`.
        bytes32 destinationAddressHash;
        /// @notice The minimum amount a matching payment would have delivered.
        uint256 amount;
        /// @notice The reference a matching payment would have carried.
        bytes32 standardPaymentReference;
        /// @notice Whether source addresses are constrained as well.
        bool checkSourceAddresses;
        /// @notice Merkle root over the permitted source addresses, when constrained.
        bytes32 sourceAddressesRoot;
    }

    /// @notice Evidence that the searched range was fully covered.
    struct ResponseBody {
        /// @notice Timestamp of `minimalBlockNumber`.
        uint64 minimalBlockTimestamp;
        /// @notice First block after the range, proving the range was complete.
        uint64 firstOverflowBlockNumber;
        /// @notice Timestamp of that block.
        uint64 firstOverflowBlockTimestamp;
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
