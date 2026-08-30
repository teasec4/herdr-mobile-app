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

// Snapshot returns the complete herdr session snapshot: workspaces, panes,
// agents and the focused targets (`herdr api snapshot`).
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

// StartAgent launches an agent of the given kind into an existing pane:
// `herdr agent start <name> --kind <kind> --pane <paneID>`.
func (r *CLIRepository) StartAgent(name, kind, paneID string) error {
	_, err := r.run("agent", "start", name, "--kind", kind, "--pane", paneID)
	return err
}

// CreateWorkspace creates a new workspace and returns its id and label
// (`herdr workspace create [--label ...] [--cwd ...]`).
func (r *CLIRepository) CreateWorkspace(label, cwd string) (string, string, error) {
	args := []string{"workspace", "create"}
	if label != "" {
		args = append(args, "--label", label)
	}
	if cwd != "" {
		args = append(args, "--cwd", cwd)
	}
	out, err := r.run(args...)
	if err != nil {
		return "", "", err
	}
	var env struct {
		Result struct {
			WorkspaceID string `json:"workspace_id"`
			Label       string `json:"label"`
		} `json:"result"`
	}
	if err := json.Unmarshal(out, &env); err != nil {
		return "", "", fmt.Errorf("parse workspace create: %w", err)
	}
	return env.Result.WorkspaceID, env.Result.Label, nil
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

// SendText writes literal text into a pane (plain terminal input): `herdr
// pane send-text <paneID> <text>`.
func (r *CLIRepository) SendText(paneID, text string) error {
	_, err := r.run("pane", "send-text", paneID, text)
	return err
}
