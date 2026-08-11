// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PaymentController} from "../contracts/PaymentController.sol";
import {TreasuryRegistry} from "../contracts/TreasuryRegistry.sol";
import {AegisFixture} from "./helpers/AegisFixture.sol";

/// @notice The k-of-n arrangement: collecting signer keys, handing the account
/// over to them, and collecting a quorum of signatures per payment.
/// @dev The three signer keys are real secp256k1 keys with their real XRPL
/// addresses, taken from validated mainnet transactions. Using invented pairs
/// would let a derivation bug agree with itself.
contract SignerSetTest is AegisFixture {
    bytes constant SIGNER_A_KEY = hex"028A4E362A90B01687CF26F2351FDFD1725FE7638F341453A2601DC562CE83F91D";
    string constant SIGNER_A_ADDR = "r4sj7Mq8hWyJdFfGCvXWpJoq7JX872582B";

    bytes constant SIGNER_B_KEY = hex"02C6478EF003B4CF203A1040E6784A5FEE2CF5FEA34EA7420E3AE1538C38BD26BA";
    string constant SIGNER_B_ADDR = "r45fyERJYiFyPFEZSUUbsvVyswiBHkynHm";

    bytes constant SIGNER_C_KEY = hex"03BC08FCDE76B929B00A625B4E83B73E8CA83F72195E0B52BCBDC668CF37C4A92B";
    string constant SIGNER_C_ADDR = "rDseVXFK1SkWhFH65cqAxf3HmvHCF6b94t";

    /// @dev A second real key, so a fresh treasury can be bound without reusing
    /// the fixture's.
    bytes constant OTHER_PUBKEY = hex"02B4632D08485FF1DF2DB55B9DAFD23347D1C47A457072A1E87BE26896549A8737";
    string constant OTHER_CLASSIC = "rN7XSxu7VypPUne8GXRr2syxbNj4WMHuem";

    bytes32 constant INSTALL_TX = keccak256("SignerListSet on XRPL");
    bytes32 constant RETIRE_TX = keccak256("AccountSet asfDisableMaster on XRPL");

    /// @dev A DER-shaped signature. Its contents are never checked on-chain —
    /// there is no SHA-512 precompile — so what matters here is that it is
    /// non-empty and that the accompanying key derives to a bound signer.
    bytes constant SIGNATURE = hex"3044022059080417C896697EE10484BE72C0643C5F1D67426241665D0F5A34312A5A8A63"
        hex"022075AF9844112FA3B83706B46FC3D7543250BB108E94B7C5038878BCD5847ACBEF";

    function accountOf(bytes memory pubKey) internal pure returns (bytes32) {
        return bytes32(ripemd160(abi.encodePacked(sha256(pubKey))));
    }

    // --- configuring ------------------------------------------------------

    function test_configuringCommitsToAQuorum() public {
        vm.prank(admin);
        registry.configureSignerSet(treasuryId, 2, 3);

        TreasuryRegistry.SignerSet memory s = registry.getSignerSet(treasuryId);
        assertEq(s.quorum, 2);
        assertEq(s.signerCount, 3);
        assertTrue(s.state == TreasuryRegistry.SignerSetState.Collecting);
        assertFalse(registry.signingIsQuorum(treasuryId), "collecting is not yet quorum signing");
    }

    function test_onlyPolicyAdminConfigures() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.NotPolicyAdmin.selector, policyId, outsider));
        vm.prank(outsider);
        registry.configureSignerSet(treasuryId, 2, 3);
    }

    function test_configuringTwiceReverts() public {
        vm.startPrank(admin);
        registry.configureSignerSet(treasuryId, 2, 3);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.SignerSetAlreadyConfigured.selector, treasuryId));
        registry.configureSignerSet(treasuryId, 3, 5);
        vm.stopPrank();
    }

    /// @dev A quorum of zero authorises anything and one above the signer count
    /// authorises nothing. Both leave a treasury that cannot be governed.
    function test_quorumBoundsAreEnforced() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.InvalidQuorum.selector, uint8(0), uint8(3)));
        registry.configureSignerSet(treasuryId, 0, 3);

        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.InvalidQuorum.selector, uint8(4), uint8(3)));
        registry.configureSignerSet(treasuryId, 4, 3);
        vm.stopPrank();
    }

    function test_aQuorumOfEveryonePasses() public {
        vm.prank(admin);
        registry.configureSignerSet(treasuryId, 3, 3);
        assertEq(registry.getSignerSet(treasuryId).quorum, 3);
    }

    function test_moreSignersThanXrplHoldsIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.TooManySigners.selector, uint8(33), uint8(32)));
        vm.prank(admin);
        registry.configureSignerSet(treasuryId, 2, 33);
    }

    function test_configuringNeedsABoundAccount() public {
        vm.startPrank(admin);
        uint256 fresh = registry.createTreasury(policyId);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.AccountNotBound.selector, fresh));
        registry.configureSignerSet(fresh, 1, 1);
        vm.stopPrank();
    }

    function test_frozenTreasuryCannotBeReconfigured() public {
        vm.prank(guardian);
        registry.freeze(treasuryId);

        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.TreasuryFrozenError.selector, treasuryId));
        vm.prank(admin);
        registry.configureSignerSet(treasuryId, 2, 3);
    }

    // --- collecting keys --------------------------------------------------

    function test_bindingSignerKeysFillsTheSet() public {
        _configure(2, 3);

        registry.bindSignerKey(treasuryId, SIGNER_A_KEY, SIGNER_A_ADDR);
        assertTrue(
            registry.getSignerSet(treasuryId).state == TreasuryRegistry.SignerSetState.Collecting,
            "still collecting after one"
        );

        registry.bindSignerKey(treasuryId, SIGNER_B_KEY, SIGNER_B_ADDR);
        registry.bindSignerKey(treasuryId, SIGNER_C_KEY, SIGNER_C_ADDR);

        TreasuryRegistry.SignerSet memory s = registry.getSignerSet(treasuryId);
        assertTrue(s.state == TreasuryRegistry.SignerSetState.Ready, "ready once full");

        bytes32[] memory signers = registry.signersOf(treasuryId);
        assertEq(signers.length, 3);
        assertTrue(registry.isSigner(treasuryId, accountOf(SIGNER_A_KEY)));
        assertTrue(registry.isSigner(treasuryId, accountOf(SIGNER_C_KEY)));
        assertFalse(registry.isSigner(treasuryId, DEST), "an unrelated account is not a signer");
    }

    function test_onlyInstructionSenderBindsSignerKeys() public {
        _configure(2, 3);
        vm.expectRevert(TreasuryRegistry.NotInstructionSender.selector);
        vm.prank(outsider);
        registry.bindSignerKey(treasuryId, SIGNER_A_KEY, SIGNER_A_ADDR);
    }

    function test_bindingRejectsAnAddressThatDoesNotMatchTheKey() public {
        _configure(2, 3);
        vm.expectRevert();
        registry.bindSignerKey(treasuryId, SIGNER_A_KEY, SIGNER_B_ADDR);
    }

    /// @dev The same enclave in two slots would inflate an apparent quorum XRPL
    /// will not honour, because it counts a signer list entry once.
    function test_duplicateSignerKeyIsRefused() public {
        _configure(2, 3);
        registry.bindSignerKey(treasuryId, SIGNER_A_KEY, SIGNER_A_ADDR);

        vm.expectRevert(
            abi.encodeWithSelector(TreasuryRegistry.DuplicateSignerKey.selector, treasuryId, accountOf(SIGNER_A_KEY))
        );
        registry.bindSignerKey(treasuryId, SIGNER_A_KEY, SIGNER_A_ADDR);
    }

    /// @dev XRPL refuses a signer list containing the account itself, so a key
    /// bound here would be one that could never count towards a quorum.
    function test_theTreasuryCannotBeItsOwnSigner() public {
        _configure(1, 1);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.SignerIsTreasuryAccount.selector, treasuryId));
        registry.bindSignerKey(treasuryId, PUBKEY, CLASSIC);
    }

    function test_bindingBeyondTheSetIsRefused() public {
        _configure(1, 2);
        registry.bindSignerKey(treasuryId, SIGNER_A_KEY, SIGNER_A_ADDR);
        registry.bindSignerKey(treasuryId, SIGNER_B_KEY, SIGNER_B_ADDR);

        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryRegistry.WrongSignerSetState.selector,
                TreasuryRegistry.SignerSetState.Ready,
                TreasuryRegistry.SignerSetState.Collecting
            )
        );
        registry.bindSignerKey(treasuryId, SIGNER_C_KEY, SIGNER_C_ADDR);
    }

    function test_bindingWithoutAConfiguredSetIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.SignerSetNotConfigured.selector, treasuryId));
        registry.bindSignerKey(treasuryId, SIGNER_A_KEY, SIGNER_A_ADDR);
    }

    // --- handing over the account -----------------------------------------

    function test_installingTheListSwitchesSigningToQuorum() public {
        _readySet(2, 3);
        assertFalse(registry.signingIsQuorum(treasuryId), "ready is not installed");

        vm.prank(admin);
        registry.confirmSignerListInstalled(treasuryId, INSTALL_TX);

        assertTrue(registry.signingIsQuorum(treasuryId));
        assertEq(registry.getSignerSet(treasuryId).installTxHash, INSTALL_TX);
        assertEq(registry.quorumOf(treasuryId), 2);
    }

    function test_installingBeforeTheSetIsFullIsRefused() public {
        _configure(2, 3);
        registry.bindSignerKey(treasuryId, SIGNER_A_KEY, SIGNER_A_ADDR);

        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryRegistry.WrongSignerSetState.selector,
                TreasuryRegistry.SignerSetState.Collecting,
                TreasuryRegistry.SignerSetState.Ready
            )
        );
        vm.prank(admin);
        registry.confirmSignerListInstalled(treasuryId, INSTALL_TX);
    }

    /// @dev A step that happened on XRPL is recorded with the transaction that
    /// did it, so the claim can be checked against the ledger rather than taken.
    function test_installationMustNameItsXrplTransaction() public {
        _readySet(2, 3);
        vm.expectRevert(TreasuryRegistry.XrplTxHashRequired.selector);
        vm.prank(admin);
        registry.confirmSignerListInstalled(treasuryId, bytes32(0));
    }

    function test_onlyPolicyAdminConfirmsInstallation() public {
        _readySet(2, 3);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.NotPolicyAdmin.selector, policyId, outsider));
        vm.prank(outsider);
        registry.confirmSignerListInstalled(treasuryId, INSTALL_TX);
    }

    /// @dev Retiring the master key before the list is live would leave an
    /// account nothing can sign for. XRPL refuses it and so does this.
    function test_masterKeyCannotBeRetiredBeforeTheListIsLive() public {
        _readySet(2, 3);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryRegistry.WrongSignerSetState.selector,
                TreasuryRegistry.SignerSetState.Ready,
                TreasuryRegistry.SignerSetState.Installed
            )
        );
        vm.prank(admin);
        registry.confirmMasterKeyRetired(treasuryId, RETIRE_TX);
    }

    function test_retiringTheMasterKeyCompletesTheArrangement() public {
        _installed(2, 3);

        vm.prank(admin);
        registry.confirmMasterKeyRetired(treasuryId, RETIRE_TX);

        TreasuryRegistry.SignerSet memory s = registry.getSignerSet(treasuryId);
        assertTrue(s.state == TreasuryRegistry.SignerSetState.Locked);
        assertEq(s.retireTxHash, RETIRE_TX);
        // The quorum was already in force before this step; what changes is that
        // it is no longer one machine's good behaviour keeping it that way.
        assertTrue(registry.signingIsQuorum(treasuryId));
    }

    // --- the sequences the handover consumes -------------------------------

    /// @dev The defect this section exists for. Both handover transactions
    /// consume an XRPL sequence exactly as a payment does. A registry that did
    /// not know about them would sign the treasury's first quorum payment
    /// against a number the ledger had already passed, and `tefPAST_SEQ` never
    /// reaches a ledger — so no proof exists that could move the treasury on.
    function test_installingTheListConsumesASequence() public {
        _readySet(2, 3);
        uint32 before = registry.nextSequenceOf(treasuryId);

        vm.prank(admin);
        registry.confirmSignerListInstalled(treasuryId, INSTALL_TX);

        assertEq(registry.nextSequenceOf(treasuryId), before + 1, "the list consumed one");
        assertEq(registry.getSignerSet(treasuryId).installSequence, before, "and the set records which");
    }

    function test_retiringTheMasterKeyConsumesTheNextSequence() public {
        _installed(2, 3);
        uint32 before = registry.nextSequenceOf(treasuryId);

        vm.prank(admin);
        registry.confirmMasterKeyRetired(treasuryId, RETIRE_TX);

        assertEq(registry.nextSequenceOf(treasuryId), before + 1);
        assertEq(registry.getSignerSet(treasuryId).retireSequence, before);
    }

    /// @dev The regression, stated end to end: after a full handover the first
    /// quorum payment must be dispatched two past where the treasury started.
    function test_theFirstQuorumPaymentSkipsBothHandoverSequences() public {
        uint32 start = registry.nextSequenceOf(treasuryId);
        _installed(2, 3);
        vm.prank(admin);
        registry.confirmMasterKeyRetired(treasuryId, RETIRE_TX);

        uint256 requestId = proposeAndApprove(dropsForUsd(500e18), 1);
        vm.prank(proposer);
        controller.dispatch(requestId, 100, 200, 12);

        assertEq(
            controller.getRequest(requestId).sequence,
            start + 2,
            "the payment must not reuse a sequence the handover already spent"
        );
    }

    /// @dev A handover is confirmed by an admin supplying a transaction hash,
    /// which is an assertion rather than a proof. So the advance it causes has
    /// to stay correctable — only an FDC proof may close that door.
    function test_aHandoverAdvanceStaysCorrectable() public {
        _installed(2, 3);
        vm.prank(admin);
        registry.confirmMasterKeyRetired(treasuryId, RETIRE_TX);

        assertFalse(
            registry.getTreasury(treasuryId).sequenceConfirmed,
            "an asserted advance must not claim XRPL proved anything"
        );

        // So an admin who finds the ledger disagrees can put it right.
        vm.prank(admin);
        registry.setInitialSequence(treasuryId, START_SEQUENCE + 9);
        assertEq(registry.nextSequenceOf(treasuryId), START_SEQUENCE + 9);
    }

    /// @dev And a settled payment still closes it, exactly as before.
    function test_aProvenOutcomeStillFixesTheStartingPoint() public {
        uint256 requestId = _dispatchedToQuorum(2, 3);
        _recordShare(requestId, SIGNER_A_KEY);
        _recordShare(requestId, SIGNER_B_KEY);

        registry.advanceSequence(treasuryId, controller.getRequest(requestId).sequence);

        assertTrue(registry.getTreasury(treasuryId).sequenceConfirmed);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.SequenceAlreadyConfirmed.selector, treasuryId));
        vm.prank(admin);
        registry.setInitialSequence(treasuryId, START_SEQUENCE);
    }

    /// @dev A treasury whose account sequence is unknown cannot hand over
    /// either, for the same reason it cannot pay.
    function test_theHandoverIsRefusedBeforeTheSequenceIsKnown() public {
        vm.startPrank(admin);
        uint256 fresh = registry.createTreasury(policyId);
        vm.stopPrank();
        registry.bindXrplAccount(fresh, OTHER_PUBKEY, OTHER_CLASSIC);

        vm.prank(admin);
        registry.configureSignerSet(fresh, 1, 1);
        registry.bindSignerKey(fresh, SIGNER_A_KEY, SIGNER_A_ADDR);

        vm.expectRevert(abi.encodeWithSelector(TreasuryRegistry.SequenceNotInitialised.selector, fresh));
        vm.prank(admin);
        registry.confirmSignerListInstalled(fresh, INSTALL_TX);
    }

    // --- dispatching to a quorum ------------------------------------------

    /// @dev The signer is chosen at dispatch, not at proposal — a treasury that
    /// moved to k-of-n while a request was waiting out its timelock must pay by
    /// quorum, which is the same rule every other check in dispatch follows.
    function test_dispatchRoutesToTheQuorumOnce_theListIsLive() public {
        uint256 requestId = proposeAndApprove(dropsForUsd(500e18), 1);
        _installed(2, 3);

        vm.prank(proposer);
        controller.dispatch(requestId, 100, 200, 12);

        assertEq(sender.multiCalls(), 1, "went to the quorum");
        assertEq(sender.calls(), 0, "and not to a single signer");

        PaymentController.PaymentRequest memory r = controller.getRequest(requestId);
        assertEq(r.quorumRequired, 2);
        assertEq(
            r.multiSignDigest,
            controller.multiSignDigest(r.policyDigest, registry.getTreasury(treasuryId).xrplAccountId),
            "the digest binds the policy digest to the account the payment leaves"
        );
    }

    function test_dispatchStillUsesOneSignerWithoutASignerSet() public {
        uint256 requestId = proposeAndApprove(dropsForUsd(500e18), 1);

        vm.prank(proposer);
        controller.dispatch(requestId, 100, 200, 12);

        assertEq(sender.calls(), 1);
        assertEq(sender.multiCalls(), 0);
        assertEq(controller.getRequest(requestId).quorumRequired, 0);
    }

    /// @dev A set that is collecting or merely ready is not a set XRPL will
    /// authorise against, so dispatch must not route to it.
    function test_dispatchDoesNotRouteToAnUninstalledSet() public {
        uint256 requestId = proposeAndApprove(dropsForUsd(500e18), 1);
        _readySet(2, 3);

        vm.prank(proposer);
        controller.dispatch(requestId, 100, 200, 12);

        assertEq(sender.calls(), 1, "still the single-key path");
        assertEq(sender.multiCalls(), 0);
    }

    // --- collecting a quorum of signatures --------------------------------

    function test_quorumOfSharesMovesTheRequestToSigned() public {
        uint256 requestId = _dispatchedToQuorum(2, 3);

        _recordShare(requestId, SIGNER_A_KEY);
        assertTrue(
            controller.getRequest(requestId).state == PaymentController.RequestState.Dispatched,
            "one share is not a quorum"
        );
        assertEq(controller.partialSignatureCount(requestId), 1);

        _recordShare(requestId, SIGNER_B_KEY);
        assertTrue(controller.getRequest(requestId).state == PaymentController.RequestState.Signed);

        PaymentController.PartialSignature[] memory shares = controller.partialSignaturesOf(requestId);
        assertEq(shares.length, 2);
        assertEq(shares[0].signerAccountId, accountOf(SIGNER_A_KEY));
        assertEq(shares[1].signature, SIGNATURE);
    }

    /// @dev A signature from a key outside the list is one XRPL would not count
    /// either, so accepting it would build a transaction that cannot succeed.
    function test_aShareFromOutsideTheListIsRefused() public {
        uint256 requestId = _dispatchedToQuorum(2, 2);

        bytes memory stranger = hex"02B4632D08485FF1DF2DB55B9DAFD23347D1C47A457072A1E87BE26896549A8737";
        vm.expectRevert(
            abi.encodeWithSelector(PaymentController.NotATreasurySigner.selector, treasuryId, accountOf(stranger))
        );
        vm.prank(address(sender));
        controller.recordPartialSignature(requestId, stranger, SIGNATURE);
    }

    function test_theSameSignerCannotContributeTwice() public {
        uint256 requestId = _dispatchedToQuorum(2, 3);
        _recordShare(requestId, SIGNER_A_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(
                PaymentController.AlreadyPartiallySigned.selector, requestId, accountOf(SIGNER_A_KEY)
            )
        );
        vm.prank(address(sender));
        controller.recordPartialSignature(requestId, SIGNER_A_KEY, SIGNATURE);
    }

    /// @dev A machine whose result arrives after the quorum closed is late, not
    /// wrong. Reverting would fail the relayer's transaction for doing its job.
    function test_aLateShareIsIgnoredRatherThanReverting() public {
        uint256 requestId = _dispatchedToQuorum(2, 3);
        _recordShare(requestId, SIGNER_A_KEY);
        _recordShare(requestId, SIGNER_B_KEY);

        vm.expectEmit(true, true, false, false);
        emit PaymentController.PartialSignatureIgnored(requestId, accountOf(SIGNER_C_KEY));
        vm.prank(address(sender));
        controller.recordPartialSignature(requestId, SIGNER_C_KEY, SIGNATURE);

        assertEq(controller.partialSignatureCount(requestId), 2, "the late share is not stored");
        assertTrue(controller.getRequest(requestId).state == PaymentController.RequestState.Signed);
    }

    function test_onlyTheInstructionSenderRecordsShares() public {
        uint256 requestId = _dispatchedToQuorum(2, 3);
        vm.expectRevert(PaymentController.NotInstructionSender.selector);
        vm.prank(outsider);
        controller.recordPartialSignature(requestId, SIGNER_A_KEY, SIGNATURE);
    }

    function test_anEmptyShareIsNotAContribution() public {
        uint256 requestId = _dispatchedToQuorum(2, 3);
        vm.expectRevert(abi.encodeWithSelector(PaymentController.EmptySignature.selector, requestId));
        vm.prank(address(sender));
        controller.recordPartialSignature(requestId, SIGNER_A_KEY, "");
    }

    function test_sharesAreRefusedForAPaymentThatWasNeverDispatchedToAQuorum() public {
        uint256 requestId = proposeAndApprove(dropsForUsd(500e18), 1);
        vm.prank(proposer);
        controller.dispatch(requestId, 100, 200, 12);

        vm.expectRevert(abi.encodeWithSelector(PaymentController.NotAQuorumPayment.selector, requestId));
        vm.prank(address(sender));
        controller.recordPartialSignature(requestId, SIGNER_A_KEY, SIGNATURE);
    }

    /// @dev The quorum is snapshotted at dispatch. A treasury cannot be
    /// re-quorummed, but the snapshot is what makes that guarantee structural
    /// rather than a consequence of the registry refusing.
    function test_aThreeOfThreeSetNeedsAllThree() public {
        uint256 requestId = _dispatchedToQuorum(3, 3);

        _recordShare(requestId, SIGNER_A_KEY);
        _recordShare(requestId, SIGNER_B_KEY);
        assertTrue(controller.getRequest(requestId).state == PaymentController.RequestState.Dispatched);

        _recordShare(requestId, SIGNER_C_KEY);
        assertTrue(controller.getRequest(requestId).state == PaymentController.RequestState.Signed);
    }

    /// @dev A quorum payment that never assembles is a payment that never lands,
    /// and the failure path has to release its window spend exactly as the
    /// single-key path does — otherwise a treasury's budget is consumed by
    /// payments that did not happen.
    function test_anUnassembledQuorumPaymentReleasesItsWindowSpend() public {
        uint256 requestId = _dispatchedToQuorum(2, 3);
        uint256 committed = controller.committedUsd(treasuryId);
        assertGt(committed, 0);

        controller.markFailed(requestId, "expired");

        assertEq(controller.committedUsd(treasuryId), 0, "the spend came back");
        assertTrue(controller.getRequest(requestId).state == PaymentController.RequestState.Failed);
    }

    // --- helpers ----------------------------------------------------------

    function _configure(uint8 quorum, uint8 signerCount) internal {
        vm.prank(admin);
        registry.configureSignerSet(treasuryId, quorum, signerCount);
    }

    function _readySet(uint8 quorum, uint8 signerCount) internal {
        _configure(quorum, signerCount);
        bytes[3] memory keys = [SIGNER_A_KEY, SIGNER_B_KEY, SIGNER_C_KEY];
        string[3] memory addrs = [SIGNER_A_ADDR, SIGNER_B_ADDR, SIGNER_C_ADDR];
        for (uint8 i = 0; i < signerCount; ++i) {
            registry.bindSignerKey(treasuryId, keys[i], addrs[i]);
        }
    }

    function _installed(uint8 quorum, uint8 signerCount) internal {
        _readySet(quorum, signerCount);
        vm.prank(admin);
        registry.confirmSignerListInstalled(treasuryId, INSTALL_TX);
    }

    function _dispatchedToQuorum(uint8 quorum, uint8 signerCount) internal returns (uint256 requestId) {
        _installed(quorum, signerCount);
        requestId = proposeAndApprove(dropsForUsd(500e18), 1);
        vm.prank(proposer);
        controller.dispatch(requestId, 100, 200, 12);
    }

    function _recordShare(uint256 requestId, bytes memory signerKey) internal {
        vm.prank(address(sender));
        controller.recordPartialSignature(requestId, signerKey, SIGNATURE);
    }
}
