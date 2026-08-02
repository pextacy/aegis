// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IFtsoV2
/// @notice Minimal view of Flare's FtsoV2 feed reader.
/// @dev Declared locally because flare-smart-contracts-v2 is not published as a
/// package yet. The address is supplied at construction from
/// config/coston2/deployed-addresses.json; when FCC ships and system contracts
/// move to FlareContractRegistry, that becomes a one-line change at the call
/// site rather than a change here.
interface IFtsoV2 {
    /// @notice Reads a feed by its 21-byte id.
    /// @dev Not `view`: FtsoV2 charges a fee for some feeds, so the function is
    /// payable on the real contract. Free feeds accept a zero value.
    /// @param _feedId The 21-byte feed id.
    /// @return _value The feed value, scaled by `_decimals`.
    /// @return _decimals The number of decimals the value carries.
    /// @return _timestamp Unix time the value was finalised.
    function getFeedById(bytes21 _feedId) external payable returns (uint256 _value, int8 _decimals, uint64 _timestamp);
}
