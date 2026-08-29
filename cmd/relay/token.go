package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
)

// loadToken returns the pairing token: env > file; creates the file on first run.
func loadToken(cfg Config) (string, error) {
	if cfg.Token != "" {
		return cfg.Token, nil
	}
	if b, err := os.ReadFile(cfg.TokenFile); err == nil {
		if t := strings.TrimSpace(string(b)); t != "" {
			return t, nil
		}
	}
	tok, err := newToken()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(cfg.TokenFile), 0o700); err != nil {
		return "", err
	}
	if err := os.WriteFile(cfg.TokenFile, []byte(tok+"\n"), 0o600); err != nil {
		return "", err
	}
	return tok, nil
}

func newToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}