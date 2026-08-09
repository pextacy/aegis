// Package config contains configuration values and defaults used by the extension.
package config

import (
	"os"
	"strconv"
	"time"
)

const (
	// Version is part of the extension lifecycle and the attestation identity.
	// Bump it whenever behaviour or the on-chain interface changes.
	Version = "0.3.0"

	// OPTypeXRPL must be byte-identical to OP_TYPE_XRPL in
	// AegisInstructionSender.sol and to the teeutils.ToHash call in
	// internal/extension. A mismatch in any of the three shows up as
	// "unsupported op type" and is the most common failure in this layer.
	//
	// bytes32("...") truncates at 32 bytes, so these stay short.
	OPTypeXRPL = "XRPLW"

	// OPCommandKeygen generates a treasury's XRPL key inside the enclave.
	OPCommandKeygen = "KEYGEN"
	// OPCommandSignTx signs a payment, but only once the policy digest matches.
	OPCommandSignTx = "SIGNTX"
	// OPCommandStatus reports whether a treasury has a key, and nothing more.
	OPCommandStatus = "STATUS"

	// OPCommandSignerKeygen generates this machine's signer key for a treasury,
	// held separately from any master key it may also hold. One machine losing
	// its signer key costs a treasury one signature, not the treasury.
	OPCommandSignerKeygen = "SKEYGN"

	// OPCommandMultiSign produces this machine's contribution to a k-of-n
	// signature, subject to the same digest check as SIGNTX plus the one that
	// binds the account the payment leaves.
	OPCommandMultiSign = "MSIGN"

	// OPCommandSetup signs a transaction that moves a treasury to k-of-n:
	// installing its signer list, then retiring its master key. Master-key
	// signed, so only the machine that ran KEYGEN can answer.
	OPCommandSetup = "SETUP"

	TimeoutShutdown = 5 * time.Second
)

// Defaults.
var (
	ExtensionPort = 8080
	SignPort      = 9090
)

// Environment variables override defaults.
func init() {
	ep := os.Getenv("EXTENSION_PORT")
	sp := os.Getenv("SIGN_PORT")

	if ep != "" {
		if v, err := strconv.Atoi(ep); err == nil {
			ExtensionPort = v
		}
	}
	if sp != "" {
		if v, err := strconv.Atoi(sp); err == nil {
			SignPort = v
		}
	}
}
