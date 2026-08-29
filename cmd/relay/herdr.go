package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// AgentAPI is what the relay needs from herdr. Implemented via the subprocess
// CLI (v1); later it can be swapped for direct JSON-RPC over the socket without
// changing the API.
type AgentAPI interface {
	Snapshot() (*Snapshot, error)
	Read(target string, lines int, format string) (string, error)
	Keys(target string, keys []string) error
	Prompt(target, text string) error
}

// Herdr is a subprocess wrapper around the herdr CLI.
type Herdr struct {
	Bin    string
	Socket string
}

func (h *Herdr) run(args ...string) ([]byte, error) {
	cmd := exec.Command(h.Bin, args...)
	cmd.Env = append(os.Environ(), "HERDR_SOCKET="+h.Socket)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("herdr %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

func (h *Herdr) Snapshot() (*Snapshot, error) {
	out, err := h.run("api", "snapshot")
	if err != nil {
		return nil, err
	}
	var env struct {
		Result struct {
			Snapshot Snapshot `json:"snapshot"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &env); err != nil {
		return nil, fmt.Errorf("parse snapshot: %w", err)
	}
	return &env.Result.Snapshot, nil
}

func (h *Herdr) Read(target string, lines int, format string) (string, error) {
	if format == "" {
		format = "text"
	}
	out, err := h.run("agent", "read", target, "--lines", fmt.Sprintf("%d", lines), "--format", format)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func (h *Herdr) Keys(target string, keys []string) error {
	args := append([]string{"agent", "send-keys", target}, keys...)
	_, err := h.run(args...)
	return err
}

func (h *Herdr) Prompt(target, text string) error {
	_, err := h.run("agent", "prompt", target, text)
	return err
}