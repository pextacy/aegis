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

type Extension struct {
	mu     sync.RWMutex
	Server *http.Server

	keys *keystore

	keygenCount     int
	signedCount     int
	rejectedCount   int
	lastRejectedLog string
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
			LastSignedSequence: s.LastSignedSequence,
			ClassicAddress:     s.ClassicAddress,
		})
	}

	e.mu.RLock()
	stateResponse := types.StateResponse{
		StateVersion: teeutils.ToHash(config.Version),
		State: types.State{
			Treasuries:      treasuries,
			KeygenCount:     e.keygenCount,
			SignedCount:     e.signedCount,
			RejectedCount:   e.rejectedCount,
			LastRejectedLog: e.lastRejectedLog,
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

	default:
		return http.StatusNotImplemented, []byte(fmt.Sprintf(
			"unsupported op command: received %s, expected one of [%s (%s), %s (%s), %s (%s)]",
			df.OPCommand.Hex(),
			teeutils.ToHash(config.OPCommandKeygen).Hex(), config.OPCommandKeygen,
			teeutils.ToHash(config.OPCommandSignTx).Hex(), config.OPCommandSignTx,
			teeutils.ToHash(config.OPCommandStatus).Hex(), config.OPCommandStatus,
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
	for i := 20; i < 32; i++ {
		if req.DestinationAccountId[i] != 0 {
			return nil, fmt.Errorf("destination is not a left-aligned 20-byte AccountID")
		}
	}

	var dest xrpl.AccountID
	copy(dest[:], req.DestinationAccountId[:20])
	if dest == (xrpl.AccountID{}) {
		return nil, fmt.Errorf("destination AccountID is zero")
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
