package herdr

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"herdrelay/internal/domain"
)

// CLIRepository implements AgentRepository using herdr CLI subprocess.
type CLIRepository struct {
	bin    string
	socket string
}

// NewCLIRepository creates a new herdr CLI repository.
func NewCLIRepository(bin, socket string) *CLIRepository {
	return &CLIRepository{
		bin:    bin,
		socket: socket,
	}
}

func (r *CLIRepository) run(args ...string) ([]byte, error) {
	cmd := exec.Command(r.bin, args...)
	// herdr CLI ignores HERDR_SOCKET and only honors HERDR_SOCKET_PATH
	// (see docs/10-herdr-api.md, gotcha #10). Using the wrong variable makes
	// every herdr call hit the default socket even when a named session is
	// configured.
	cmd.Env = append(os.Environ(), "HERDR_SOCKET_PATH="+r.socket)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("herdr %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// Snapshot returns the current state of all agents.
func (r *CLIRepository) Snapshot() (*domain.Snapshot, error) {
	out, err := r.run("api", "snapshot")
	if err != nil {
		return nil, err
	}
	var env struct {
		Result struct {
			Snapshot domain.Snapshot `json:"snapshot"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &env); err != nil {
		return nil, fmt.Errorf("parse snapshot: %w", err)
	}
	return &env.Result.Snapshot, nil
}

// ReadOutput reads the terminal output of an agent.
func (r *CLIRepository) ReadOutput(target string, lines int, format string) (string, error) {
	if format == "" {
		format = "text"
	}
	out, err := r.run("agent", "read", target, "--lines", fmt.Sprintf("%d", lines), "--format", format)
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// SendKeys sends key sequences to an agent.
func (r *CLIRepository) SendKeys(target string, keys []string) error {
	args := append([]string{"agent", "send-keys", target}, keys...)
	_, err := r.run(args...)
	return err
}

// SendPrompt sends a text prompt to an agent.
func (r *CLIRepository) SendPrompt(target, text string) error {
	_, err := r.run("agent", "prompt", target, text)
	return err
}
