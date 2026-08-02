// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ExecutionVerifier} from "../contracts/ExecutionVerifier.sol";
import {PaymentController} from "../contracts/PaymentController.sol";
import {IPayment} from "../contracts/interfaces/IPayment.sol";
import {IReferencedPaymentNonexistence} from "../contracts/interfaces/IReferencedPaymentNonexistence.sol";
import {AegisFixture} from "./helpers/AegisFixture.sol";
import {FdcVerificationStub} from "./helpers/Doubles.sol";

/// @notice Settlement and proof: every way a request can leave `Signed`, and
/// every proof that must not be enough to take it there.
/// @dev The FDC double attests exact responses rather than accepting a flag, so
/// "a fabricated proof is rejected" and "a tampered proof is rejected" are real
/// assertions about the leaf hash, not about a boolean the test set.
contract ExecutionVerifierTest is AegisFixture {
    ExecutionVerifier internal verifier;
    FdcVerificationStub internal fdc;

    uint32 constant FLS = 899_990;
    uint32 constant LLS = 900_000;
    uint64 constant FEE = 12;
    uint64 constant BLOCK_NUMBER = 899_995;
    bytes32 constant TX_HASH = bytes32(uint256(0xA11CE));

    function _executionVerifier() internal override returns (address) {
        fdc = new FdcVerificationStub();
        verifier = new ExecutionVerifier(controller, registry, fdc);
        return address(verifier);
    }

    // --- settlement -------------------------------------------------------

    function test_settlementMovesStateAndAdvancesSequence() public {
        uint256 id = _signed(dropsForUsd(100e18));
        uint32 sequenceUsed = controller.getRequest(id).sequence;

        _settle(id, _payment(id, dropsForUsd(100e18)));

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Settled));
        assertEq(registry.nextSequenceOf(treasuryId), sequenceUsed + 1, "XRPL consumed the sequence");
    }

    function test_settlementKeepsTheWindowSpend() public {
        uint64 drops = dropsForUsd(20_000e18);
        uint256 id = _signed(drops);
        _settle(id, _payment(id, drops));

        assertEq(controller.committedUsd(treasuryId), 20_000e18, "money moved, so the budget stays consumed");
    }

    function test_settlementRejectsAFabricatedProof() public {
        uint256 id = _signed(dropsForUsd(100e18));
        // Never attested: the leaf is not in any round.
        IPayment.Proof memory proof =
            IPayment.Proof({merkleProof: new bytes32[](0), data: _payment(id, dropsForUsd(100e18))});

        vm.expectRevert(ExecutionVerifier.ProofNotVerified.selector);
        vm.prank(outsider);
        verifier.confirmSettlement(id, proof);
    }

    function test_settlementRejectsAProofTamperedAfterAttestation() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _payment(id, drops);
        fdc.attestPayment(response);

        // One drop more than what was attested. Same shape, different leaf.
        response.responseBody.spentAmount += 1;

        vm.expectRevert(ExecutionVerifier.ProofNotVerified.selector);
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_settlementRejectsAProofForAnotherRequest() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 first = _signed(drops);
        uint256 second = _signed(drops);

        // A genuine, attested proof — of the other request's payment.
        IPayment.Response memory response = _payment(second, drops);
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.ReferenceMismatch.selector,
                verifier.requestReference(second),
                verifier.requestReference(first)
            )
        );
        verifier.confirmSettlement(first, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_settlementRejectsTheWrongAttestationType() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _payment(id, drops);
        response.attestationType = verifier.ATTESTATION_TYPE_NONEXISTENCE();
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.WrongAttestationType.selector,
                verifier.ATTESTATION_TYPE_NONEXISTENCE(),
                verifier.ATTESTATION_TYPE_PAYMENT()
            )
        );
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_settlementRejectsAnotherChain() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _payment(id, drops);
        response.sourceId = bytes32("testBTC");
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.WrongSource.selector, bytes32("testBTC"), verifier.SOURCE_ID_TEST_XRP()
            )
        );
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_settlementRejectsAPaymentFromAnotherAccount() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _payment(id, drops);
        response.responseBody.sourceAddressHash = keccak256(abi.encode("rDifferentAccountEntirely"));
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.SourceMismatch.selector,
                keccak256(abi.encode("rDifferentAccountEntirely")),
                keccak256(abi.encode(CLASSIC))
            )
        );
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_settlementRejectsAPaymentToAnotherDestination() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _payment(id, drops);
        response.responseBody.receivingAddressHash = verifier.addressHashOf(DEST_OTHER);
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.DestinationMismatch.selector,
                verifier.addressHashOf(DEST_OTHER),
                verifier.addressHashOf(DEST)
            )
        );
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_settlementRejectsADifferentAmount() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _payment(id, drops);
        response.responseBody.spentAmount = int256(uint256(drops)); // fee left out
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.SpentAmountMismatch.selector,
                int256(uint256(drops)),
                int256(uint256(drops) + uint256(FEE))
            )
        );
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_settlementRejectsAFailedPayment() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _payment(id, drops);
        response.responseBody.status = 1;
        fdc.attestPayment(response);

        vm.expectRevert(abi.encodeWithSelector(ExecutionVerifier.PaymentDidNotSucceed.selector, uint8(1)));
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_settlementRequiresASignature() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _dispatched(drops);

        IPayment.Response memory response = _payment(id, drops);
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.NotAwaitingSettlement.selector, PaymentController.RequestState.Dispatched
            )
        );
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    // --- failure on ledger ------------------------------------------------

    function test_failedExecutionReleasesTheWindowAndAdvancesTheSequence() public {
        uint64 drops = dropsForUsd(20_000e18);
        uint256 id = _signed(drops);
        uint32 sequenceUsed = controller.getRequest(id).sequence;

        IPayment.Response memory response = _failedPayment(id, drops);
        fdc.attestPayment(response);
        verifier.confirmFailedExecution(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Failed));
        assertEq(controller.committedUsd(treasuryId), 0, "no money moved, so the budget comes back");
        assertEq(registry.nextSequenceOf(treasuryId), sequenceUsed + 1, "a ledgered failure still burns the sequence");
    }

    function test_failedExecutionRejectsASuccessfulPayment() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _payment(id, drops);
        fdc.attestPayment(response);

        vm.expectRevert(ExecutionVerifier.PaymentSucceeded.selector);
        verifier.confirmFailedExecution(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_failedExecutionChecksTheIntendedDestination() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _failedPayment(id, drops);
        response.responseBody.intendedReceivingAddressHash = verifier.addressHashOf(DEST_OTHER);
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.DestinationMismatch.selector,
                verifier.addressHashOf(DEST_OTHER),
                verifier.addressHashOf(DEST)
            )
        );
        verifier.confirmFailedExecution(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_failedExecutionChecksTheIntendedAmount() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IPayment.Response memory response = _failedPayment(id, drops);
        response.responseBody.intendedSpentAmount = int256(uint256(drops));
        fdc.attestPayment(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.SpentAmountMismatch.selector,
                int256(uint256(drops)),
                int256(uint256(drops) + uint256(FEE))
            )
        );
        verifier.confirmFailedExecution(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function test_failedExecutionRejectsAFabricatedProof() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);
        IPayment.Proof memory proof = IPayment.Proof({merkleProof: new bytes32[](0), data: _failedPayment(id, drops)});

        vm.expectRevert(ExecutionVerifier.ProofNotVerified.selector);
        vm.prank(outsider);
        verifier.confirmFailedExecution(id, proof);
    }

    // --- non-execution ----------------------------------------------------

    function test_nonExecutionReleasesTheWindowAndHoldsTheSequence() public {
        uint64 drops = dropsForUsd(20_000e18);
        uint256 id = _signed(drops);
        uint32 sequenceUsed = controller.getRequest(id).sequence;

        _proveAbsent(id, _nonexistence(id, drops));

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Failed));
        assertEq(controller.committedUsd(treasuryId), 0, "the payment never happened");
        assertEq(
            registry.nextSequenceOf(treasuryId), sequenceUsed, "nothing was included, so XRPL still expects this one"
        );
    }

    function test_nonExecutionLeavesTheTreasuryUsable() public {
        uint64 drops = dropsForUsd(20_000e18);
        uint256 first = _signed(drops);
        uint32 sequenceUsed = controller.getRequest(first).sequence;

        _proveAbsent(first, _nonexistence(first, drops));

        // The next payment reuses the sequence the expired one never consumed.
        uint256 second = _dispatched(drops);
        assertEq(controller.getRequest(second).sequence, sequenceUsed);
    }

    function test_nonExecutionWorksBeforeASignatureWasRecorded() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _dispatched(drops);

        _proveAbsent(id, _nonexistence(id, drops));

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Failed));
    }

    function test_nonExecutionRejectsASearchStartingAfterDispatch() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IReferencedPaymentNonexistence.Response memory response = _nonexistence(id, drops);
        response.requestBody.minimalBlockNumber = uint64(FLS) + 1;
        fdc.attestNonexistence(response);

        vm.expectRevert(
            abi.encodeWithSelector(ExecutionVerifier.SearchStartsTooLate.selector, uint64(FLS) + 1, uint64(FLS))
        );
        verifier.confirmNonExecution(
            id, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );
    }

    function test_nonExecutionRejectsASearchEndingBeforeExpiry() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IReferencedPaymentNonexistence.Response memory response = _nonexistence(id, drops);
        response.requestBody.deadlineBlockNumber = uint64(LLS) - 1;
        fdc.attestNonexistence(response);

        vm.expectRevert(abi.encodeWithSelector(ExecutionVerifier.SearchEndsTooEarly.selector, uint64(LLS) - 1, LLS));
        verifier.confirmNonExecution(
            id, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );
    }

    function test_nonExecutionAcceptsAWiderSearch() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IReferencedPaymentNonexistence.Response memory response = _nonexistence(id, drops);
        response.requestBody.minimalBlockNumber = uint64(FLS) - 500;
        response.requestBody.deadlineBlockNumber = uint64(LLS) + 500;
        response.requestBody.amount = 0;
        fdc.attestNonexistence(response);

        verifier.confirmNonExecution(
            id, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Failed));
    }

    function test_nonExecutionRejectsAThresholdAboveTheAmount() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IReferencedPaymentNonexistence.Response memory response = _nonexistence(id, drops);
        response.requestBody.amount = uint256(drops) + 1;
        fdc.attestNonexistence(response);

        vm.expectRevert(
            abi.encodeWithSelector(ExecutionVerifier.SearchAmountTooHigh.selector, uint256(drops) + 1, drops)
        );
        verifier.confirmNonExecution(
            id, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );
    }

    function test_nonExecutionRejectsASourceConstrainedSearch() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IReferencedPaymentNonexistence.Response memory response = _nonexistence(id, drops);
        response.requestBody.checkSourceAddresses = true;
        response.requestBody.sourceAddressesRoot = keccak256("some other account");
        fdc.attestNonexistence(response);

        vm.expectRevert(ExecutionVerifier.SourceConstrained.selector);
        verifier.confirmNonExecution(
            id, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );
    }

    function test_nonExecutionRejectsAnotherRequestsReference() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 first = _signed(drops);
        uint256 second = _signed(drops);

        IReferencedPaymentNonexistence.Response memory response = _nonexistence(second, drops);
        fdc.attestNonexistence(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.ReferenceMismatch.selector,
                verifier.requestReference(second),
                verifier.requestReference(first)
            )
        );
        verifier.confirmNonExecution(
            first, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );
    }

    function test_nonExecutionRejectsAnotherDestination() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IReferencedPaymentNonexistence.Response memory response = _nonexistence(id, drops);
        response.requestBody.destinationAddressHash = verifier.addressHashOf(DEST_OTHER);
        fdc.attestNonexistence(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.DestinationMismatch.selector,
                verifier.addressHashOf(DEST_OTHER),
                verifier.addressHashOf(DEST)
            )
        );
        verifier.confirmNonExecution(
            id, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );
    }

    function test_nonExecutionRejectsAFabricatedProof() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);
        IReferencedPaymentNonexistence.Proof memory proof =
            IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: _nonexistence(id, drops)});

        vm.expectRevert(ExecutionVerifier.ProofNotVerified.selector);
        vm.prank(outsider);
        verifier.confirmNonExecution(id, proof);
    }

    function test_nonExecutionRejectsTheWrongAttestationType() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);

        IReferencedPaymentNonexistence.Response memory response = _nonexistence(id, drops);
        response.attestationType = verifier.ATTESTATION_TYPE_PAYMENT();
        fdc.attestNonexistence(response);

        vm.expectRevert(
            abi.encodeWithSelector(
                ExecutionVerifier.WrongAttestationType.selector,
                verifier.ATTESTATION_TYPE_PAYMENT(),
                verifier.ATTESTATION_TYPE_NONEXISTENCE()
            )
        );
        verifier.confirmNonExecution(
            id, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );
    }

    // --- window accounting ------------------------------------------------

    function test_releasedWindowFreesCapacityForTheNextPayment() public {
        uint64 drops = dropsForUsd(30_000e18);
        uint256 first = _signed(drops);

        // 30,000 + 30,000 is over the 50,000 window cap.
        vm.expectRevert(
            abi.encodeWithSelector(PaymentController.RollingWindowExceeded.selector, 30_000e18, 30_000e18, WINDOW_CAP)
        );
        vm.prank(proposer);
        controller.propose(treasuryId, DEST, 0, drops);

        _proveAbsent(first, _nonexistence(first, drops));

        vm.prank(proposer);
        uint256 second = controller.propose(treasuryId, DEST, 0, drops);
        assertEq(uint8(controller.getRequest(second).state), uint8(PaymentController.RequestState.Proposed));
    }

    // --- concurrency ------------------------------------------------------

    function test_twoSubmittersSettlingTheSameRequestIsANoOp() public {
        uint64 drops = dropsForUsd(100e18);
        uint256 id = _signed(drops);
        uint32 sequenceUsed = controller.getRequest(id).sequence;

        IPayment.Response memory response = _payment(id, drops);
        fdc.attestPayment(response);
        IPayment.Proof memory proof = IPayment.Proof({merkleProof: new bytes32[](0), data: response});

        vm.prank(outsider);
        verifier.confirmSettlement(id, proof);

        // The second submitter arrives with the same valid proof and is ignored.
        vm.expectEmit(true, false, false, true, address(verifier));
        emit ExecutionVerifier.ProofAlreadyConsumed(id, PaymentController.RequestState.Settled);
        vm.prank(proposer);
        verifier.confirmSettlement(id, proof);

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Settled));
        assertEq(registry.nextSequenceOf(treasuryId), sequenceUsed + 1, "the sequence advanced exactly once");
    }

    function test_nonExecutionCannotOverturnASettlement() public {
        uint64 drops = dropsForUsd(20_000e18);
        uint256 id = _signed(drops);
        _settle(id, _payment(id, drops));

        // A racing submitter that saw the expiry and not the validation.
        IReferencedPaymentNonexistence.Response memory response = _nonexistence(id, drops);
        fdc.attestNonexistence(response);
        verifier.confirmNonExecution(
            id, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Settled));
        assertEq(controller.committedUsd(treasuryId), 20_000e18, "the released budget would have been the damage");
    }

    function test_settlementCannotOverturnAProvenFailure() public {
        uint64 drops = dropsForUsd(20_000e18);
        uint256 id = _signed(drops);
        _proveAbsent(id, _nonexistence(id, drops));

        IPayment.Response memory response = _payment(id, drops);
        fdc.attestPayment(response);
        verifier.confirmSettlement(id, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));

        assertEq(uint8(controller.getRequest(id).state), uint8(PaymentController.RequestState.Failed));
    }

    // --- helpers ----------------------------------------------------------

    /// @dev Proposes, approves to the tier threshold, waits out the timelock and
    /// dispatches. Amounts here are chosen to land in tier 0 or tier 2.
    function _dispatched(uint64 amountDrops) private returns (uint256 requestId) {
        vm.prank(proposer);
        requestId = controller.propose(treasuryId, DEST, 0, amountDrops);

        PaymentController.PaymentRequest memory r = controller.getRequest(requestId);
        address[3] memory pool = [approverA, approverB, approverC];
        for (uint8 i = 0; i < r.requiredApprovals; ++i) {
            vm.prank(pool[i]);
            controller.approve(requestId);
        }

        vm.warp(controller.getRequest(requestId).eligibleAt);
        setPrice(XRP_PRICE, uint64(block.timestamp));

        vm.prank(proposer);
        controller.dispatch(requestId, FLS, LLS, FEE);
    }

    function _signed(uint64 amountDrops) private returns (uint256 requestId) {
        requestId = _dispatched(amountDrops);
        vm.prank(address(sender));
        controller.recordSignature(requestId, hex"120000", TX_HASH);
    }

    function _settle(uint256 requestId, IPayment.Response memory response) private {
        fdc.attestPayment(response);
        verifier.confirmSettlement(requestId, IPayment.Proof({merkleProof: new bytes32[](0), data: response}));
    }

    function _proveAbsent(uint256 requestId, IReferencedPaymentNonexistence.Response memory response) private {
        fdc.attestNonexistence(response);
        verifier.confirmNonExecution(
            requestId, IReferencedPaymentNonexistence.Proof({merkleProof: new bytes32[](0), data: response})
        );
    }

    /// @dev A successful XRP payment as the FDC would attest it.
    function _payment(uint256 requestId, uint64 amountDrops) private view returns (IPayment.Response memory) {
        int256 spent = int256(uint256(amountDrops) + uint256(FEE));
        return IPayment.Response({
            attestationType: verifier.ATTESTATION_TYPE_PAYMENT(),
            sourceId: verifier.SOURCE_ID_TEST_XRP(),
            votingRound: 1_000,
            lowestUsedTimestamp: uint64(block.timestamp),
            requestBody: IPayment.RequestBody({transactionId: TX_HASH, inUtxo: 0, utxo: 0}),
            responseBody: IPayment.ResponseBody({
                blockNumber: BLOCK_NUMBER,
                blockTimestamp: uint64(block.timestamp),
                sourceAddressHash: keccak256(abi.encode(CLASSIC)),
                sourceAddressesRoot: bytes32(0),
                receivingAddressHash: verifier.addressHashOf(DEST),
                intendedReceivingAddressHash: verifier.addressHashOf(DEST),
                spentAmount: spent,
                intendedSpentAmount: spent,
                receivedAmount: int256(uint256(amountDrops)),
                intendedReceivedAmount: int256(uint256(amountDrops)),
                standardPaymentReference: verifier.requestReference(requestId),
                oneToOne: true,
                status: 0
            })
        });
    }

    /// @dev The same transaction, included in a ledger but failing there: the
    /// fee is spent, nothing is delivered, and the intent is reported instead.
    function _failedPayment(uint256 requestId, uint64 amountDrops) private view returns (IPayment.Response memory) {
        IPayment.Response memory response = _payment(requestId, amountDrops);
        response.responseBody.status = 1;
        response.responseBody.receivingAddressHash = bytes32(0);
        response.responseBody.spentAmount = int256(uint256(FEE));
        response.responseBody.receivedAmount = 0;
        return response;
    }

    /// @dev A non-existence attestation covering the whole life of the payment.
    function _nonexistence(uint256 requestId, uint64 amountDrops)
        private
        view
        returns (IReferencedPaymentNonexistence.Response memory)
    {
        return IReferencedPaymentNonexistence.Response({
            attestationType: verifier.ATTESTATION_TYPE_NONEXISTENCE(),
            sourceId: verifier.SOURCE_ID_TEST_XRP(),
            votingRound: 1_000,
            lowestUsedTimestamp: uint64(block.timestamp),
            requestBody: IReferencedPaymentNonexistence.RequestBody({
                minimalBlockNumber: FLS,
                deadlineBlockNumber: LLS,
                deadlineTimestamp: uint64(block.timestamp),
                destinationAddressHash: verifier.addressHashOf(DEST),
                amount: uint256(amountDrops),
                standardPaymentReference: verifier.requestReference(requestId),
                checkSourceAddresses: false,
                sourceAddressesRoot: bytes32(0)
            }),
            responseBody: IReferencedPaymentNonexistence.ResponseBody({
                minimalBlockTimestamp: uint64(block.timestamp),
                firstOverflowBlockNumber: uint64(LLS) + 1,
                firstOverflowBlockTimestamp: uint64(block.timestamp) + 4
            })
        });
    }
}
