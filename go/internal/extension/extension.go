package extension

import (
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"sort"
	"sync"

	"extension-scaffold/internal/config"
	"extension-scaffold/internal/xrpl"
	"extension-scaffold/pkg/types"

	"github.com/flare-foundation/go-flare-common/pkg/tee/instruction"
	"github.com/flare-foundation/go-flare-common/pkg/tee/structs"
	teetypes "github.com/flare-foundation/tee-node/pkg/types"
	teeutils "github.com/flare-foundation/tee-node/pkg/utils"

	"github.com/flare-foundation/tee-node/pkg/processorutils"
)

// logDigestMismatch is the exact string the digest check emits. Tests and the
// troubleshooting table both match on it, so it is a constant rather than a
// literal typed twice.
const logDigestMismatch = "policy digest mismatch"

// logSourceMismatch is emitted when a multi-signing request names an account the
// contract did not authorise the payment to leave. Distinct from the policy
// digest's refusal because it points at a different tampered field.
const logSourceMismatch = "source account digest mismatch"

// logSetupDigestMismatch is emitted when a setup instruction's fields do not
// hash to the digest the contract computed for them.
const logSetupDigestMismatch = "setup digest mismatch"

type Extension struct {
	mu     sync.RWMutex
	Server *http.Server

	keys *keystore

	keygenCount       int
	signerKeygenCount int
	signedCount       int
	multiSignedCount  int
	setupCount        int
	rejectedCount     int
	lastRejectedLog   string
}

// --- DO NOT MODIFY: New(), actionHandler() are boilerplate.
func New(extensionPort, signPort int) *Extension {
	e := &Extension{keys: newKeystore()}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /state", e.stateHandler)
	mux.HandleFunc("POST /action", e.actionHandler)

	e.Server = &http.Server{Addr: fmt.Sprintf(":%d", extensionPort), Handler: mux}
	return e
}

// stateHandler reports observable state: booleans, counters, addresses and
// sequence numbers.
//
// No key material is reachable from here under any input. The keystore exposes
// no accessor that could return one, which is enforced by the type rather than
// by remembering not to add one.
func (e *Extension) stateHandler(w http.ResponseWriter, r *http.Request) {
	snaps := e.keys.snapshot()
	sort.Slice(snaps, func(i, j int) bool { return snaps[i].TreasuryID < snaps[j].TreasuryID })

	treasuries := make([]types.TreasuryState, 0, len(snaps))
	for _, s := range snaps {
		treasuries = append(treasuries, types.TreasuryState{
			TreasuryId:         s.TreasuryID,
			HasKey:             s.HasKey,
			HasSignerKey:       s.HasSignerKey,
			LastSignedSequence: s.LastSignedSequence,
			ClassicAddress:     s.ClassicAddress,
			SignerAddress:      s.SignerAddress,
		})
	}

	e.mu.RLock()
	stateResponse := types.StateResponse{
		StateVersion: teeutils.ToHash(config.Version),
		State: types.State{
			Treasuries:        treasuries,
			KeygenCount:       e.keygenCount,
			SignerKeygenCount: e.signerKeygenCount,
			SignedCount:       e.signedCount,
			MultiSignedCount:  e.multiSignedCount,
			SetupCount:        e.setupCount,
			RejectedCount:     e.rejectedCount,
			LastRejectedLog:   e.lastRejectedLog,
		},
	}
	e.mu.RUnlock()

	err := json.NewEncoder(w).Encode(stateResponse)
	if err != nil {
		http.Error(w, fmt.Sprintf("sending response: %v", err), http.StatusInternalServerError)
		return
	}
}

func (e *Extension) processAction(action teetypes.Action) (int, []byte) {
	dataFixed, err := processorutils.Parse[instruction.DataFixed](action.Data.Message)
	if err != nil {
		return http.StatusBadRequest, []byte(fmt.Sprintf("decoding fixed data: %v", err))
	}

	switch {
	case dataFixed.OPType == teeutils.ToHash(config.OPTypeXRPL):
		return e.processXRPL(action, dataFixed)

	default:
		return http.StatusNotImplemented, []byte(fmt.Sprintf(
			"unsupported op type: received %s, expected %s (%s)",
			dataFixed.OPType.Hex(), teeutils.ToHash(config.OPTypeXRPL).Hex(), config.OPTypeXRPL,
		))
	}
}

// processXRPL routes XRPLW instructions by OPCommand.
func (e *Extension) processXRPL(action teetypes.Action, df *instruction.DataFixed) (int, []byte) {
	switch {
	case df.OPCommand == teeutils.ToHash(config.OPCommandKeygen):
		ar := e.processKeygen(action, df)
		b, _ := json.Marshal(ar)
		return http.StatusOK, b

	case df.OPCommand == teeutils.ToHash(config.OPCommandSignTx):
		ar := e.processSignTx(action, df)
		b, _ := json.Marshal(ar)
		return http.StatusOK, b

	case df.OPCommand == teeutils.ToHash(config.OPCommandStatus):
		ar := e.processStatus(action, df)
		b, _ := json.Marshal(ar)
		return http.StatusOK, b

	case df.OPCommand == teeutils.ToHash(config.OPCommandSignerKeygen):
		ar := e.processSignerKeygen(action, df)
		b, _ := json.Marshal(ar)
		return http.StatusOK, b

	case df.OPCommand == teeutils.ToHash(config.OPCommandMultiSign):
		ar := e.processMultiSign(action, df)
		b, _ := json.Marshal(ar)
		return http.StatusOK, b

	case df.OPCommand == teeutils.ToHash(config.OPCommandSetup):
		ar := e.processSetup(action, df)
		b, _ := json.Marshal(ar)
		return http.StatusOK, b

	default:
		return http.StatusNotImplemented, []byte(fmt.Sprintf(
			"unsupported op command: received %s, expected one of [%s (%s), %s (%s), %s (%s), %s (%s), %s (%s), %s (%s)]",
			df.OPCommand.Hex(),
			teeutils.ToHash(config.OPCommandKeygen).Hex(), config.OPCommandKeygen,
			teeutils.ToHash(config.OPCommandSignTx).Hex(), config.OPCommandSignTx,
			teeutils.ToHash(config.OPCommandStatus).Hex(), config.OPCommandStatus,
			teeutils.ToHash(config.OPCommandSignerKeygen).Hex(), config.OPCommandSignerKeygen,
			teeutils.ToHash(config.OPCommandMultiSign).Hex(), config.OPCommandMultiSign,
			teeutils.ToHash(config.OPCommandSetup).Hex(), config.OPCommandSetup,
		))
	}
}

// processKeygen generates a treasury's XRPL key inside the enclave and returns
// only the public half.
func (e *Extension) processKeygen(action teetypes.Action, df *instruction.DataFixed) teetypes.ActionResult {
	treasuryID, err := decodeTreasuryID(df.OriginalMessage)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("decoding keygen request: %w", err))
	}

	pubKey, classicAddress, err := e.keys.Generate(treasuryID)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("generating key: %w", err))
	}

	data, err := types.KeygenResponseArgs.Pack(pubKey, classicAddress)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("encoding keygen result: %w", err))
	}

	e.mu.Lock()
	e.keygenCount++
	e.mu.Unlock()

	return buildResult(action, df, data, 1, nil)
}

// processSignTx signs a payment, but only after independently confirming that
// the fields it received hash to the digest the contract computed.
//
// This is the property that separates Aegis from an oracle that signs whatever
// it is told. The relay path is trusted to a signature threshold, not to
// preserve payload integrity, so the check happens here and before the key is
// touched.
func (e *Extension) processSignTx(action teetypes.Action, df *instruction.DataFixed) teetypes.ActionResult {
	var req types.SignRequest
	if err := structs.DecodeTo(types.SignRequestArg, df.OriginalMessage, &req); err != nil {
		return e.reject(action, df, fmt.Errorf("decoding sign request: %w", err))
	}

	matches, err := req.DigestMatches()
	if err != nil {
		return e.reject(action, df, fmt.Errorf("computing policy digest: %w", err))
	}
	if !matches {
		// Deliberately terse: the mismatch itself is the finding, and echoing
		// the fields back would put a tampered payload into a public log.
		return e.reject(action, df, fmt.Errorf("%s", logDigestMismatch))
	}

	payment, err := paymentFromRequest(&req)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("building payment: %w", err))
	}

	blob, txHash, err := e.keys.Sign(req.TreasuryId, payment)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("signing: %w", err))
	}

	data, err := types.SignResponseArgs.Pack(blob, [32]byte(txHash))
	if err != nil {
		return e.reject(action, df, fmt.Errorf("encoding sign result: %w", err))
	}

	e.mu.Lock()
	e.signedCount++
	e.mu.Unlock()

	return buildResult(action, df, data, 1, nil)
}

// processSignerKeygen generates this machine's signer key for a treasury.
//
// Held apart from any master key this machine may also hold for the same
// treasury, and returned as a public key and an address — the same two things
// KEYGEN returns, for the same reason.
func (e *Extension) processSignerKeygen(action teetypes.Action, df *instruction.DataFixed) teetypes.ActionResult {
	treasuryID, err := decodeTreasuryID(df.OriginalMessage)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("decoding signer keygen request: %w", err))
	}

	pubKey, classicAddress, err := e.keys.GenerateSigner(treasuryID)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("generating signer key: %w", err))
	}

	data, err := types.KeygenResponseArgs.Pack(pubKey, classicAddress)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("encoding signer keygen result: %w", err))
	}

	e.mu.Lock()
	e.signerKeygenCount++
	e.mu.Unlock()

	return buildResult(action, df, data, 1, nil)
}

// processMultiSign produces this machine's contribution to a k-of-n signature.
//
// Two digest checks, both before the key is touched. The policy digest is the
// same one SIGNTX enforces, over the same eight fields, so nothing about the
// guarantee changes when a treasury moves to k-of-n. The multi-sign digest is
// the addition: a signer key does not know which treasury account it is signing
// for, so the sending account arrives with the instruction, and anything that
// arrives with an instruction has to be proven rather than believed.
//
// What comes back is one signature, not a transaction. A single enclave under
// k-of-n has authorised nothing, and the result says so.
func (e *Extension) processMultiSign(action teetypes.Action, df *instruction.DataFixed) teetypes.ActionResult {
	var req types.MultiSignRequest
	if err := structs.DecodeTo(types.MultiSignRequestArg, df.OriginalMessage, &req); err != nil {
		return e.reject(action, df, fmt.Errorf("decoding multi-sign request: %w", err))
	}

	signRequest := req.SignRequest()
	matches, err := signRequest.DigestMatches()
	if err != nil {
		return e.reject(action, df, fmt.Errorf("computing policy digest: %w", err))
	}
	if !matches {
		// Deliberately terse, as in processSignTx: the mismatch is the finding,
		// and echoing the fields would put a tampered payload into a public log.
		return e.reject(action, df, fmt.Errorf("%s", logDigestMismatch))
	}

	sourceOK, err := req.MultiSignDigestMatches()
	if err != nil {
		return e.reject(action, df, fmt.Errorf("computing multi-sign digest: %w", err))
	}
	if !sourceOK {
		return e.reject(action, df, fmt.Errorf("%s", logSourceMismatch))
	}

	payment, err := multiSignPaymentFromRequest(&req)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("building payment: %w", err))
	}

	signature, err := e.keys.MultiSign(req.TreasuryId, payment)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("multi-signing: %w", err))
	}

	data, err := types.PartialSignatureResponseArgs.Pack(signature.SigningPubKey, signature.TxnSignature)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("encoding partial signature: %w", err))
	}

	e.mu.Lock()
	e.multiSignedCount++
	e.mu.Unlock()

	return buildResult(action, df, data, 1, nil)
}

// processSetup signs one of the two transactions that move a treasury to k-of-n.
//
// Both are signed with the master key, so only the machine that ran KEYGEN can
// answer and the others refuse for want of a key. The digest check is not a
// formality here: installing a signer list decides who can ever spend from this
// treasury again, so a relayer that added one account to the list would have
// added itself to every future quorum.
func (e *Extension) processSetup(action teetypes.Action, df *instruction.DataFixed) teetypes.ActionResult {
	var req types.SetupRequest
	if err := structs.DecodeTo(types.SetupRequestArg, df.OriginalMessage, &req); err != nil {
		return e.reject(action, df, fmt.Errorf("decoding setup request: %w", err))
	}

	matches, err := req.DigestMatches()
	if err != nil {
		return e.reject(action, df, fmt.Errorf("computing setup digest: %w", err))
	}
	if !matches {
		return e.reject(action, df, fmt.Errorf("%s", logSetupDigestMismatch))
	}

	var (
		blob   []byte
		txHash xrpl.Hash
	)

	switch req.Kind {
	case types.SetupKindSignerList:
		entries, err := signerEntries(req.SignerAccountIds)
		if err != nil {
			return e.reject(action, df, fmt.Errorf("building signer list: %w", err))
		}
		tx := &xrpl.SignerListSet{
			Quorum:             req.Quorum,
			Entries:            entries,
			Sequence:           req.Sequence,
			LastLedgerSequence: req.LastLedgerSequence,
			FeeDrops:           req.FeeDrops,
		}
		// Sorted so that the bytes depend on the set of signers and not on the
		// order the results happened to arrive in.
		tx.SortEntries()

		blob, txHash, err = e.keys.SignSignerList(req.TreasuryId, tx)
		if err != nil {
			return e.reject(action, df, fmt.Errorf("signing signer list: %w", err))
		}

	case types.SetupKindDisableMasterKey:
		// Nothing about a signer list belongs in this transaction, and accepting
		// fields it does not use would mean a digest covering values that had no
		// effect — which is how a check becomes decorative.
		if req.Quorum != 0 || len(req.SignerAccountIds) != 0 {
			return e.reject(action, df, fmt.Errorf("disabling the master key takes no signer list"))
		}
		tx := &xrpl.AccountSet{
			SetFlag:            xrpl.AsfDisableMaster,
			Sequence:           req.Sequence,
			LastLedgerSequence: req.LastLedgerSequence,
			FeeDrops:           req.FeeDrops,
		}

		blob, txHash, err = e.keys.SignAccountSet(req.TreasuryId, tx)
		if err != nil {
			return e.reject(action, df, fmt.Errorf("signing master key retirement: %w", err))
		}

	default:
		return e.reject(action, df, fmt.Errorf("unsupported setup kind %d", req.Kind))
	}

	data, err := types.SignResponseArgs.Pack(blob, [32]byte(txHash))
	if err != nil {
		return e.reject(action, df, fmt.Errorf("encoding setup result: %w", err))
	}

	e.mu.Lock()
	e.setupCount++
	e.mu.Unlock()

	return buildResult(action, df, data, 1, nil)
}

// processStatus reports whether a treasury has a key, and its last sequence.
func (e *Extension) processStatus(action teetypes.Action, df *instruction.DataFixed) teetypes.ActionResult {
	treasuryID, err := decodeTreasuryID(df.OriginalMessage)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("decoding status request: %w", err))
	}

	hasKey, lastSequence := e.keys.Status(treasuryID)

	data, err := types.StatusResponseArgs.Pack(hasKey, lastSequence)
	if err != nil {
		return e.reject(action, df, fmt.Errorf("encoding status result: %w", err))
	}

	return buildResult(action, df, data, 1, nil)
}

// reject records the refusal and returns a status-0 result.
//
// Every ambiguous condition lands here. There is no permissive path.
func (e *Extension) reject(action teetypes.Action, df *instruction.DataFixed, err error) teetypes.ActionResult {
	e.mu.Lock()
	e.rejectedCount++
	e.lastRejectedLog = err.Error()
	e.mu.Unlock()

	return buildResult(action, df, nil, 0, err)
}

// decodeTreasuryID unpacks the bare uint256 that KEYGEN and STATUS carry.
func decodeTreasuryID(message []byte) (*big.Int, error) {
	values, err := types.TreasuryIdArgs.Unpack(message)
	if err != nil {
		return nil, err
	}
	if len(values) != 1 {
		return nil, fmt.Errorf("expected one argument, got %d", len(values))
	}
	id, ok := values[0].(*big.Int)
	if !ok || id == nil {
		return nil, fmt.Errorf("treasury id is not a uint256")
	}
	if id.Sign() <= 0 {
		return nil, fmt.Errorf("treasury id must be positive")
	}
	return id, nil
}

// paymentFromRequest turns the decoded fields into an XRPL payment.
//
// The destination arrives as a bytes32 with the 20-byte AccountID left-aligned,
// which is how Solidity carries it. The trailing twelve bytes must be zero: a
// non-zero tail means the caller packed something other than an AccountID, and
// silently truncating it would send money to an address nobody chose.
func paymentFromRequest(req *types.SignRequest) (*xrpl.Payment, error) {
	dest, err := accountIDFromWord(req.DestinationAccountId)
	if err != nil {
		return nil, fmt.Errorf("destination: %w", err)
	}

	memo, err := requestMemo(req)
	if err != nil {
		return nil, err
	}

	p := &xrpl.Payment{
		Destination:        dest,
		AmountDrops:        req.AmountDrops,
		FeeDrops:           req.FeeDrops,
		Sequence:           req.Sequence,
		LastLedgerSequence: req.LastLedgerSequence,
		DestinationTag:     req.DestinationTag,
		Flags:              xrpl.TfFullyCanonicalSig,
		Memos:              []xrpl.Memo{memo},
	}
	return p, nil
}

// accountIDFromWord unpacks a bytes32 carrying a left-aligned 20-byte AccountID.
//
// The trailing twelve bytes must be zero: a non-zero tail means the caller
// packed something other than an AccountID, and silently truncating it would
// send money to an address nobody chose.
func accountIDFromWord(word [32]byte) (xrpl.AccountID, error) {
	for i := 20; i < 32; i++ {
		if word[i] != 0 {
			return xrpl.AccountID{}, fmt.Errorf("not a left-aligned 20-byte AccountID")
		}
	}

	var id xrpl.AccountID
	copy(id[:], word[:20])
	if id == (xrpl.AccountID{}) {
		return xrpl.AccountID{}, fmt.Errorf("AccountID is zero")
	}
	return id, nil
}

// multiSignPaymentFromRequest builds the payment every signer hashes.
//
// The sending account comes from the request rather than from this machine, and
// is only trusted because the multi-sign digest has already been checked against
// it. Every other field is built exactly as the single-signing path builds it,
// so the two produce the same transaction and differ only in how it is
// authorised.
func multiSignPaymentFromRequest(req *types.MultiSignRequest) (*xrpl.Payment, error) {
	signRequest := req.SignRequest()
	p, err := paymentFromRequest(&signRequest)
	if err != nil {
		return nil, err
	}

	source, err := accountIDFromWord(req.SourceAccountId)
	if err != nil {
		return nil, fmt.Errorf("source: %w", err)
	}
	p.Account = source

	return p, nil
}

// signerEntries turns the contract's AccountID words into signer list entries.
//
// Every signer carries weight 1. Weights would let one machine's signature
// count for more than another's, and there is no rule in the policy engine that
// would decide which — an unexplained asymmetry in who can spend a treasury is
// worse than none.
func signerEntries(words [][32]byte) ([]xrpl.SignerEntry, error) {
	if len(words) == 0 {
		return nil, fmt.Errorf("a signer list needs at least one entry")
	}

	entries := make([]xrpl.SignerEntry, 0, len(words))
	for i, w := range words {
		id, err := accountIDFromWord(w)
		if err != nil {
			return nil, fmt.Errorf("signer %d: %w", i, err)
		}
		entries = append(entries, xrpl.SignerEntry{Account: id, Weight: 1})
	}
	return entries, nil
}

// requestMemo builds the memo that links this XRPL transaction to its on-chain
// request.
//
// ExecutionVerifier matches the FDC payment reference against
// keccak256(abi.encode(requestId)), so this encoding and that check must change
// together or settlement can never be proven.
func requestMemo(req *types.SignRequest) (xrpl.Memo, error) {
	reference, err := types.RequestReference(req.RequestId)
	if err != nil {
		return xrpl.Memo{}, err
	}
	return xrpl.Memo{Data: reference[:]}, nil
}
