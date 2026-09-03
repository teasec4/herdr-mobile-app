package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"

	"herdrelay/internal/domain"
)

// loadIdentity returns the relay identity (relay_id + name), creating the
// identity file on first run — same pattern as loadToken. relay_id stays
// stable across restarts so clients can recognise this relay when they switch
// sessions or machines.
func loadIdentity(cfg Config) (domain.Identity, error) {
	if b, err := os.ReadFile(cfg.IdentityFile); err == nil {
		var id domain.Identity
		if err := json.Unmarshal(b, &id); err == nil && id.RelayID != "" {
			// Name is derived from the host, refresh it in case the host changed.
			if id.Name == "" {
				id.Name, _ = os.Hostname()
			}
			return id, nil
		}
	}

	// No valid identity file — generate a fresh one.
	name, _ := os.Hostname()
	rid, err := newRelayID()
	if err != nil {
		return domain.Identity{}, err
	}
	id := domain.Identity{RelayID: rid, Name: name}

	if err := os.MkdirAll(filepath.Dir(cfg.IdentityFile), 0o700); err != nil {
		return id, err
	}
	b, err := json.MarshalIndent(id, "", "  ")
	if err != nil {
		return id, err
	}

	// Atomic create with O_EXCL to prevent race condition
	f, err := os.OpenFile(cfg.IdentityFile, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		if os.IsExist(err) {
			// Another process won the race, re-read the file
			return loadIdentity(cfg)
		}
		return id, err
	}
	defer func() { _ = f.Close() }()

	if _, err := f.Write(append(b, '\n')); err != nil {
		return id, err
	}
	return id, nil
}

// newRelayID returns a 128-bit random id as 32 hex characters.
func newRelayID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
