// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAegisInstructionSender} from "../../contracts/interfaces/IAegisInstructionSender.sol";
import {IFdcVerification} from "../../contracts/interfaces/IFdcVerification.sol";
import {IFtsoV2} from "../../contracts/interfaces/IFtsoV2.sol";
import {IPayment} from "../../contracts/interfaces/IPayment.sol";
import {IReferencedPaymentNonexistence} from "../../contracts/interfaces/IReferencedPaymentNonexistence.sol";

/// @notice Test-only FtsoV2 whose price and timestamp the test controls.
/// @dev Lives in test/ and is never imported by contracts/. Staleness and
/// conversion arithmetic cannot be exercised against a live feed.
contract FtsoStub is IFtsoV2 {
    uint256 private _value;
    int8 private _decimals;
    uint64 private _timestamp;

    function set(uint256 value_, int8 decimals_, uint64 timestamp_) external {
        _value = value_;
        _decimals = decimals_;
        _timestamp = timestamp_;
    }

    function getFeedById(bytes21) external payable returns (uint256, int8, uint64) {
        return (_value, _decimals, _timestamp);
    }
}

/// @notice Test-only instruction sender that records what it was asked to sign.
contract SenderRecorder is IAegisInstructionSender {
    SignRequest public last;
    uint256 public calls;
    uint256 public valueReceived;
    uint8 public lastThreshold;

    function requestSignature(SignRequest calldata request, address[] calldata, uint8 threshold) external payable {
        last = request;
        lastThreshold = threshold;
        valueReceived += msg.value;
        unchecked {
            ++calls;
        }
    }
}

/// @notice Test-only FDC verification that attests exact responses.
/// @dev Models what the real contract does without a Merkle tree: FdcVerification
/// re-derives the leaf `keccak256(abi.encode(response))` and checks it against
/// the round's finalised root, so any field altered after attestation produces a
/// different leaf and fails. `attest` records a leaf; everything else returns
/// false, which is what makes "a fabricated proof is rejected" a real test
/// rather than a flag being flipped.
contract FdcVerificationStub is IFdcVerification {
    mapping(bytes32 leaf => bool) private _attested;

    function attestPayment(IPayment.Response calldata response) external {
        _attested[keccak256(abi.encode(response))] = true;
    }

    function attestNonexistence(IReferencedPaymentNonexistence.Response calldata response) external {
        _attested[keccak256(abi.encode(response))] = true;
    }

    function verifyPayment(IPayment.Proof calldata _proof) external view returns (bool) {
        return _attested[keccak256(abi.encode(_proof.data))];
    }

    function verifyReferencedPaymentNonexistence(IReferencedPaymentNonexistence.Proof calldata _proof)
        external
        view
        returns (bool)
    {
        return _attested[keccak256(abi.encode(_proof.data))];
    }
}
