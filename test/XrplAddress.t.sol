// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {XrplAddress} from "../contracts/lib/XrplAddress.sol";

/// @notice Address derivation against XRPL's own published vector.
contract XrplAddressTest is Test {
    /// @dev The XRPL genesis account, from the reference documentation. Master
    /// seed snoPBrXtMeMyMHUVTgbuqAfg1SUTb derives this key and this address.
    bytes constant GENESIS_PUBKEY = hex"0330E7FC9D56BB25D6893BA3F317AE5BCF33B3291BD63DB32654A313222F7FD020";
    string constant GENESIS_ADDRESS = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh";

    function test_derivesReferenceAddress() public pure {
        (, string memory addr) = XrplAddress.deriveAccount(GENESIS_PUBKEY);
        assertEq(addr, GENESIS_ADDRESS, "classic address must match the XRPL reference vector");
    }

    function test_accountIdIsRipemd160OfSha256() public pure {
        bytes20 expected = ripemd160(abi.encodePacked(sha256(GENESIS_PUBKEY)));
        assertEq(XrplAddress.accountIdFromPubKey(GENESIS_PUBKEY), expected);
    }

    function test_rejectsWrongLength() public {
        bytes memory short = hex"0330E7FC";
        vm.expectRevert(XrplAddress.InvalidPublicKeyLength.selector);
        this.derive(short);
    }

    function test_rejectsUncompressedPrefix() public {
        bytes memory bad = GENESIS_PUBKEY;
        bad[0] = 0x04; // uncompressed marker
        vm.expectRevert(XrplAddress.InvalidPublicKeyPrefix.selector);
        this.derive(bad);
    }

    function derive(bytes memory key) external pure returns (string memory) {
        (, string memory addr) = XrplAddress.deriveAccount(key);
        return addr;
    }
}
