// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IPayment} from "./IPayment.sol";
import {IReferencedPaymentNonexistence} from "./IReferencedPaymentNonexistence.sol";

/// @title IFdcVerification
/// @notice The two FDC verifications Aegis consumes.
/// @dev Declared locally because flare-smart-contracts-v2 is not published as a
/// package. Only the two attestation types this system uses are declared; the
/// real contract carries more. Each function re-derives the Merkle leaf from the
/// supplied response and checks it against the round's finalised root, so a
/// fabricated proof returns false and the caller refuses the settlement.
interface IFdcVerification {
    /// @notice Verifies a `Payment` attestation against its round's Merkle root.
    /// @param _proof The response and its Merkle proof.
    /// @return _proved True when the response was attested in its voting round.
    function verifyPayment(IPayment.Proof calldata _proof) external view returns (bool _proved);

    /// @notice Verifies a `ReferencedPaymentNonexistence` attestation.
    /// @param _proof The response and its Merkle proof.
    /// @return _proved True when the response was attested in its voting round.
    function verifyReferencedPaymentNonexistence(IReferencedPaymentNonexistence.Proof calldata _proof)
        external
        view
        returns (bool _proved);
}
