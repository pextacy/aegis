// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title XrplAddress
/// @notice Derives an XRPL AccountID and classic address from a compressed
/// secp256k1 public key, on-chain.
/// @dev Uses the SHA-256 (0x02) and RIPEMD-160 (0x03) precompiles, so no
/// library dependency is needed. This is what lets TreasuryRegistry verify that
/// the address the enclave reported really belongs to the key it returned,
/// rather than taking the enclave's word for it.
library XrplAddress {
    /// @notice The XRPL base58 alphabet — deliberately not the Bitcoin one.
    string internal constant ALPHABET = "rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz";

    /// @notice A compressed secp256k1 key is 33 bytes: a 0x02/0x03 prefix and X.
    uint256 internal constant COMPRESSED_PUBKEY_LENGTH = 33;

    /// @notice Version byte prefixed to an AccountID before base58check encoding.
    bytes1 internal constant ACCOUNT_PREFIX = 0x00;

    error InvalidPublicKeyLength();
    error InvalidPublicKeyPrefix();

    /// @notice Derives the 20-byte AccountID from a compressed public key.
    /// @param compressedPubKey The 33-byte compressed secp256k1 public key.
    /// @return The AccountID, `ripemd160(sha256(pubkey))`.
    function accountIdFromPubKey(bytes memory compressedPubKey) internal pure returns (bytes20) {
        if (compressedPubKey.length != COMPRESSED_PUBKEY_LENGTH) revert InvalidPublicKeyLength();
        bytes1 prefix = compressedPubKey[0];
        if (prefix != 0x02 && prefix != 0x03) revert InvalidPublicKeyPrefix();
        return ripemd160(abi.encodePacked(sha256(compressedPubKey)));
    }

    /// @notice Encodes an AccountID as a base58check classic address.
    /// @dev Payload is `0x00 || accountId` plus the first four bytes of a double
    /// SHA-256 over it — 25 bytes total, which fits in a uint256, so the base58
    /// conversion is plain arithmetic rather than big-number code.
    /// @param accountId The 20-byte AccountID.
    /// @return The classic address, beginning with `r`.
    function encodeClassicAddress(bytes20 accountId) internal pure returns (string memory) {
        bytes memory payload = abi.encodePacked(ACCOUNT_PREFIX, accountId);
        bytes32 checksum = sha256(abi.encodePacked(sha256(payload)));
        bytes memory full = abi.encodePacked(payload, bytes4(checksum));

        uint256 leadingZeros = 0;
        while (leadingZeros < full.length && full[leadingZeros] == 0) {
            unchecked {
                ++leadingZeros;
            }
        }

        uint256 num = 0;
        for (uint256 i = 0; i < full.length; ++i) {
            num = (num << 8) | uint8(full[i]);
        }

        bytes memory alphabet = bytes(ALPHABET);
        // 25 bytes never encodes to more than 35 base58 characters.
        bytes memory buffer = new bytes(40);
        uint256 cursor = 40;
        while (num > 0) {
            unchecked {
                --cursor;
            }
            buffer[cursor] = alphabet[num % 58];
            num /= 58;
        }
        for (uint256 i = 0; i < leadingZeros; ++i) {
            unchecked {
                --cursor;
            }
            buffer[cursor] = alphabet[0];
        }

        bytes memory out = new bytes(40 - cursor);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = buffer[cursor + i];
        }
        return string(out);
    }

    /// @notice Derives the classic address for a compressed public key.
    /// @param compressedPubKey The 33-byte compressed secp256k1 public key.
    /// @return accountId The derived AccountID.
    /// @return classicAddress The derived classic address.
    function deriveAccount(bytes memory compressedPubKey)
        internal
        pure
        returns (bytes20 accountId, string memory classicAddress)
    {
        accountId = accountIdFromPubKey(compressedPubKey);
        classicAddress = encodeClassicAddress(accountId);
    }
}
