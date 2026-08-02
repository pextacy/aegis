// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IAegisInstructionSender} from "../../contracts/interfaces/IAegisInstructionSender.sol";
import {IFtsoV2} from "../../contracts/interfaces/IFtsoV2.sol";

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
