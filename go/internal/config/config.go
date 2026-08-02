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
	Version = "0.2.0"

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
