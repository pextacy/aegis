// Package xrpl implements XRPL transaction serialisation, address derivation
// and signing directly, with no XRPL library dependency.
//
// The enclave image is the unit of attestation, so it must stay small and
// reproducible. This package is a few hundred lines and is validated against
// blobs taken from XRPL itself, which is worth more than a dependency.
package xrpl

import (
	"encoding/binary"
	"fmt"
	"sort"
)

// Field type codes, from the XRPL binary format definitions.
const (
	typeUInt16    = 1
	typeUInt32    = 2
	typeAmount    = 6
	typeBlob      = 7
	typeAccountID = 8
	typeSTObject  = 14
	typeSTArray   = 15
)

// Field codes within each type.
const (
	fieldTransactionType    = 2  // UInt16
	fieldSignerWeight       = 3  // UInt16
	fieldFlags              = 2  // UInt32
	fieldSequence           = 4  // UInt32
	fieldDestinationTag     = 14 // UInt32
	fieldLastLedgerSequence = 27 // UInt32
	fieldSetFlag            = 33 // UInt32
	fieldSignerQuorum       = 35 // UInt32
	fieldAmount             = 1  // Amount
	fieldFee                = 8  // Amount
	fieldSigningPubKey      = 3  // Blob
	fieldTxnSignature       = 4  // Blob
	fieldMemoType           = 12 // Blob
	fieldMemoData           = 13 // Blob
	fieldMemoFormat         = 14 // Blob
	fieldAccount            = 1  // AccountID
	fieldDestination        = 3  // AccountID
	fieldSignerEntry        = 11 // STObject
	fieldMemo               = 10 // STObject
	fieldSigner             = 16 // STObject
	fieldSigners            = 3  // STArray
	fieldSignerEntries      = 4  // STArray
	fieldMemos              = 9  // STArray
	fieldObjectEndMarker    = 1  // STObject
	fieldArrayEndMarker     = 1  // STArray
)

// TransactionType values.
const (
	txTypePayment       = 0
	txTypeAccountSet    = 3
	txTypeSignerListSet = 12
)

// TfFullyCanonicalSig must be set in Flags on every transaction this package
// produces. It forbids the malleable form of a signature.
const TfFullyCanonicalSig uint32 = 0x80000000

// maxVLLength is the largest blob the variable-length prefix can express.
const maxVLLength = 918744

// field is one serialised transaction field, kept with its codes so the whole
// set can be sorted canonically rather than trusting the order they were built.
type field struct {
	typeCode  uint8
	fieldCode uint8
	payload   []byte
}

// header encodes the field id.
//
// The high nibble carries the type code and the low nibble the field code, but
// only when each fits in four bits; anything larger moves to its own trailing
// byte and leaves its nibble zero. LastLedgerSequence (field 27) is the one
// field in a Payment that takes the two-byte form.
func (f field) header() []byte {
	var high, low uint8
	if f.typeCode < 16 {
		high = f.typeCode << 4
	}
	if f.fieldCode < 16 {
		low = f.fieldCode
	}

	out := []byte{high | low}
	if f.typeCode >= 16 {
		out = append(out, f.typeCode)
	}
	if f.fieldCode >= 16 {
		out = append(out, f.fieldCode)
	}
	return out
}

// encode returns the field id followed by its payload.
func (f field) encode() []byte {
	return append(f.header(), f.payload...)
}

// sortFields orders by (typeCode, fieldCode). This is the canonical order — not
// alphabetical by name, and not the order the fields were declared in.
func sortFields(fields []field) {
	sort.SliceStable(fields, func(i, j int) bool {
		if fields[i].typeCode != fields[j].typeCode {
			return fields[i].typeCode < fields[j].typeCode
		}
		return fields[i].fieldCode < fields[j].fieldCode
	})
}

// vlPrefix encodes a variable-length prefix for a blob of n bytes.
//
// XRPL uses three ranges rather than a fixed width, so the common short blob
// costs one byte.
func vlPrefix(n int) ([]byte, error) {
	switch {
	case n < 0:
		return nil, fmt.Errorf("negative length %d", n)
	case n <= 192:
		return []byte{uint8(n)}, nil
	case n <= 12480:
		v := n - 193
		return []byte{uint8(193 + v/256), uint8(v % 256)}, nil
	case n <= maxVLLength:
		v := n - 12481
		return []byte{uint8(241 + v/65536), uint8((v >> 8) % 256), uint8(v % 256)}, nil
	default:
		return nil, fmt.Errorf("blob of %d bytes exceeds the maximum %d", n, maxVLLength)
	}
}

// blobField builds a length-prefixed field.
func blobField(typeCode, fieldCode uint8, data []byte) (field, error) {
	prefix, err := vlPrefix(len(data))
	if err != nil {
		return field{}, fmt.Errorf("encoding length for field (%d,%d): %w", typeCode, fieldCode, err)
	}
	return field{typeCode: typeCode, fieldCode: fieldCode, payload: append(prefix, data...)}, nil
}

// uint16Field builds a two-byte big-endian field.
func uint16Field(fieldCode uint8, v uint16) field {
	payload := make([]byte, 2)
	binary.BigEndian.PutUint16(payload, v)
	return field{typeCode: typeUInt16, fieldCode: fieldCode, payload: payload}
}

// uint32Field builds a four-byte big-endian field.
func uint32Field(fieldCode uint8, v uint32) field {
	payload := make([]byte, 4)
	binary.BigEndian.PutUint32(payload, v)
	return field{typeCode: typeUInt32, fieldCode: fieldCode, payload: payload}
}

// xrpAmountField builds an XRP amount.
//
// Bit 62 marks the value as XRP rather than an issued currency, and bit 63 is
// the sign bit, left clear because a payment amount is never negative.
func xrpAmountField(fieldCode uint8, drops uint64) (field, error) {
	if drops > maxDrops {
		return field{}, fmt.Errorf("amount %d drops exceeds the total XRP supply", drops)
	}
	payload := make([]byte, 8)
	binary.BigEndian.PutUint64(payload, drops|0x4000000000000000)
	return field{typeCode: typeAmount, fieldCode: fieldCode, payload: payload}, nil
}

// maxDrops is the total XRP supply in drops — 100 billion XRP.
const maxDrops uint64 = 100_000_000_000 * 1_000_000
