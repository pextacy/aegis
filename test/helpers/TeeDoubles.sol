// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ITeeExtensionRegistry} from "../../contracts/interfaces/ITeeExtensionRegistry.sol";
import {ITeeMachineRegistry} from "../../contracts/interfaces/ITeeMachineRegistry.sol";

/// @notice Test-only TEE extension registry that records what it was asked to send.
/// @dev Lives in test/ and is never imported by contracts/. The real registry is
/// a Flare system contract; the instruction payload it receives is the thing
/// worth asserting on, and only a double lets a test read it back.
contract TeeExtensionRegistryStub is ITeeExtensionRegistry {
    struct Sent {
        bytes32 opType;
        bytes32 opCommand;
        bytes message;
        address[] cosigners;
        uint64 cosignersThreshold;
        address claimBackAddress;
        uint256 value;
        address[] teeIds;
    }

    Sent[] private _sent;
    uint256 public nextPublicExtensionId = 0x10002;
    mapping(uint256 extensionId => address sender) private _senders;
    uint256 private _nonce;

    /// @notice Registers a sender at an extension id, as the real registry would.
    function register(uint256 extensionId, address sender) external {
        _senders[extensionId] = sender;
        if (extensionId >= nextPublicExtensionId) {
            nextPublicExtensionId = extensionId + 1;
        }
    }

    function sendInstructions(address[] calldata _teeIds, TeeInstructionParams calldata _instructionParams)
        external
        payable
        returns (bytes32)
    {
        _sent.push(
            Sent({
                opType: _instructionParams.opType,
                opCommand: _instructionParams.opCommand,
                message: _instructionParams.message,
                cosigners: _instructionParams.cosigners,
                cosignersThreshold: _instructionParams.cosignersThreshold,
                claimBackAddress: _instructionParams.claimBackAddress,
                value: msg.value,
                teeIds: _teeIds
            })
        );
        _nonce++;
        return keccak256(abi.encode(_nonce, _instructionParams.opCommand));
    }

    function getTeeExtensionInstructionsSender(uint256 _extensionId) external view returns (address) {
        return _senders[_extensionId];
    }

    function sentCount() external view returns (uint256) {
        return _sent.length;
    }

    function lastSent() external view returns (Sent memory) {
        return _sent[_sent.length - 1];
    }

    function sentAt(uint256 index) external view returns (Sent memory) {
        return _sent[index];
    }
}

/// @notice Test-only TEE machine registry returning a fixed machine set.
contract TeeMachineRegistryStub is ITeeMachineRegistry {
    address[] private _machines;

    constructor() {
        _machines.push(address(uint160(uint256(keccak256("aegis.test.tee.machine")))));
    }

    function getRandomTeeIds(uint256, uint256 _count) external view returns (address[] memory) {
        address[] memory out = new address[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            out[i] = _machines[i % _machines.length];
        }
        return out;
    }
}
