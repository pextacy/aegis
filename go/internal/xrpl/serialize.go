package xrpl

import (
	"errors"
	"fmt"
)

// AccountID is the 20-byte XRPL account identifier.
type AccountID [20]byte

// Memo is one entry of the Memos array. Aegis populates only Data, with the
// keccak256 of the on-chain request id — that is what links an XRPL transaction
// to a Flare request in an FDC proof. Type and Format exist because real
// transactions carry them and the serialiser is validated against real blobs.
type Memo struct {
	Type   []byte
	Data   []byte
	Format []byte
}

// Payment is an XRPL Payment in the fields this system needs.
//
// Amounts are drops throughout — 1 XRP is 1,000,000 drops — and never touch a
// float.
type Payment struct {
	Account            AccountID
	Destination        AccountID
	AmountDrops        uint64
	FeeDrops           uint64
	Sequence           uint32
	LastLedgerSequence uint32

	// DestinationTag is omitted from the serialisation when zero. Serialising a
	// zero tag produces a different hash than omitting it, and omitting is what
	// XRPL does.
	DestinationTag uint32

	// Flags is omitted when zero. Aegis always sets TfFullyCanonicalSig, so in
	// this system it is always present; the zero case exists because the
	// reference transactions used to validate this package do not set it.
	Flags uint32

	SigningPubKey []byte
	TxnSignature  []byte
	Memos         []Memo

	// Signers carries the k-of-n signatures of a multi-signed transaction. It is
	// empty for the single-signed path, and when it is populated SigningPubKey
	// is serialised as the empty blob — that emptiness is what tells XRPL to
	// authorise the transaction against the account's SignerList rather than
	// against its master key.
	Signers []Signer
}

// txForm selects which of the signature-carrying fields a serialisation
// includes. The field set is otherwise identical in all four, which is why the
// forms are a parameter rather than four separate functions that could drift.
type txForm uint8

const (
	// formForSigning is what a single signer hashes: SigningPubKey present,
	// TxnSignature absent.
	formForSigning txForm = iota

	// formSigned is a complete single-signed transaction.
	formSigned

	// formForMultiSigning is what each of n signers hashes. SigningPubKey is the
	// empty blob and no signature appears, so every signer hashes identical
	// bytes and only the AccountID appended after them differs.
	formForMultiSigning

	// formMultiSigned is a complete multi-signed transaction: empty
	// SigningPubKey, no TxnSignature, and the Signers array.
	formMultiSigned
)

// multiSigned reports whether the form authorises against a SignerList.
func (f txForm) multiSigned() bool {
	return f == formForMultiSigning || f == formMultiSigned
}

var (
	// ErrNoLastLedgerSequence rejects a transaction that could never be proven
	// non-existent. Without a LastLedgerSequence a stuck payment can neither
	// settle nor be shown not to have settled, which wedges the treasury.
	ErrNoLastLedgerSequence = errors.New("xrpl: LastLedgerSequence is required")

	// ErrNoAmount rejects a zero-value payment.
	ErrNoAmount = errors.New("xrpl: amount must be greater than zero")

	// ErrNoFee rejects a zero fee, which XRPL will not accept.
	ErrNoFee = errors.New("xrpl: fee must be greater than zero")

	// ErrNoSigningPubKey rejects serialisation without a signing key.
	ErrNoSigningPubKey = errors.New("xrpl: SigningPubKey is required")
)

// Validate checks the invariants that must hold before anything is signed.
func (p *Payment) Validate() error {
	return p.validate(false)
}

// validate checks the invariants for one signing mode.
//
// A multi-signed transaction carries no SigningPubKey of its own — the empty
// blob is what selects the SignerList — so that requirement is dropped there
// and nowhere else.
func (p *Payment) validate(multi bool) error {
	if p.LastLedgerSequence == 0 {
		return ErrNoLastLedgerSequence
	}
	if p.AmountDrops == 0 {
		return ErrNoAmount
	}
	if p.FeeDrops == 0 {
		return ErrNoFee
	}
	if !multi && len(p.SigningPubKey) == 0 {
		return ErrNoSigningPubKey
	}
	return nil
}

// Serialize returns the canonical binary form.
//
// When includeSignature is false the TxnSignature field is left out, which is
// the form that gets hashed and signed. Every other field, including
// SigningPubKey, is present in both forms.
func (p *Payment) Serialize(includeSignature bool) ([]byte, error) {
	if includeSignature {
		return p.serialize(formSigned)
	}
	return p.serialize(formForSigning)
}

// serialize builds the canonical binary form for one signing mode.
func (p *Payment) serialize(form txForm) ([]byte, error) {
	fields := []field{
		uint16Field(fieldTransactionType, txTypePayment),
		uint32Field(fieldSequence, p.Sequence),
		uint32Field(fieldLastLedgerSequence, p.LastLedgerSequence),
	}

	if p.Flags != 0 {
		fields = append(fields, uint32Field(fieldFlags, p.Flags))
	}
	if p.DestinationTag != 0 {
		fields = append(fields, uint32Field(fieldDestinationTag, p.DestinationTag))
	}

	amount, err := xrpAmountField(fieldAmount, p.AmountDrops)
	if err != nil {
		return nil, fmt.Errorf("serialising Amount: %w", err)
	}
	fee, err := xrpAmountField(fieldFee, p.FeeDrops)
	if err != nil {
		return nil, fmt.Errorf("serialising Fee: %w", err)
	}
	fields = append(fields, amount, fee)

	// A multi-signed transaction still carries SigningPubKey, as the empty blob.
	// Omitting the field entirely is a different serialisation and a different
	// hash, and XRPL reads the emptiness — not the absence — as "authorise this
	// against the SignerList".
	signingKey := p.SigningPubKey
	if form.multiSigned() {
		signingKey = nil
	}
	pubKey, err := blobField(typeBlob, fieldSigningPubKey, signingKey)
	if err != nil {
		return nil, err
	}
	fields = append(fields, pubKey)

	if form == formSigned {
		sig, err := blobField(typeBlob, fieldTxnSignature, p.TxnSignature)
		if err != nil {
			return nil, err
		}
		fields = append(fields, sig)
	}

	account, err := blobField(typeAccountID, fieldAccount, p.Account[:])
	if err != nil {
		return nil, err
	}
	destination, err := blobField(typeAccountID, fieldDestination, p.Destination[:])
	if err != nil {
		return nil, err
	}
	fields = append(fields, account, destination)

	if len(p.Memos) > 0 {
		memos, err := serializeMemos(p.Memos)
		if err != nil {
			return nil, err
		}
		fields = append(fields, memos)
	}

	if form == formMultiSigned {
		signers, err := serializeSigners(p.Signers)
		if err != nil {
			return nil, err
		}
		fields = append(fields, signers)
	}

	// Sorting here rather than relying on the order above is the point: the
	// canonical order is a property of the codes, not of this function.
	sortFields(fields)

	var out []byte
	for _, f := range fields {
		out = append(out, f.encode()...)
	}
	return out, nil
}

// serializeMemos builds the Memos STArray.
//
// Each entry is an STObject terminated by an object end marker, and the array
// itself by an array end marker.
func serializeMemos(memos []Memo) (field, error) {
	var payload []byte
	for i, m := range memos {
		if len(m.Type) == 0 && len(m.Data) == 0 && len(m.Format) == 0 {
			return field{}, fmt.Errorf("memo %d is empty", i)
		}

		var inner []field
		if len(m.Type) > 0 {
			f, err := blobField(typeBlob, fieldMemoType, m.Type)
			if err != nil {
				return field{}, err
			}
			inner = append(inner, f)
		}
		if len(m.Data) > 0 {
			f, err := blobField(typeBlob, fieldMemoData, m.Data)
			if err != nil {
				return field{}, err
			}
			inner = append(inner, f)
		}
		if len(m.Format) > 0 {
			f, err := blobField(typeBlob, fieldMemoFormat, m.Format)
			if err != nil {
				return field{}, err
			}
			inner = append(inner, f)
		}
		sortFields(inner)

		memoHeader := field{typeCode: typeSTObject, fieldCode: fieldMemo}
		payload = append(payload, memoHeader.header()...)
		for _, f := range inner {
			payload = append(payload, f.encode()...)
		}
		endObject := field{typeCode: typeSTObject, fieldCode: fieldObjectEndMarker}
		payload = append(payload, endObject.header()...)
	}

	endArray := field{typeCode: typeSTArray, fieldCode: fieldArrayEndMarker}
	payload = append(payload, endArray.header()...)

	return field{typeCode: typeSTArray, fieldCode: fieldMemos, payload: payload}, nil
}
