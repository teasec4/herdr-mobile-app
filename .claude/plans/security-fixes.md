# Plan for fixing mandatory security and correctness issues

## Overview

We are fixing 4 critical issues (P1-P2) found during the Linus audit:
1. **P1**: Timing attack in token verification
2. **P1**: Race condition in event subscription
3. **P2**: Missing timeout in exec.Command (netdetect)
4. **P2**: Race condition when creating token/identity files

## Fix details

### 1. Timing attack in token verification

**File:** `cmd/relay/router.go:51-56`

**Problem:** A plain string comparison `==` is used to check the token, which lets an attacker recover the token byte-by-byte via a timing attack.

**Solution:**
```go
import "crypto/subtle"

func verifyToken(r *http.Request, token string) bool {
    var candidate string
    if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
        candidate = h[len("Bearer "):]
    } else {
        candidate = r.URL.Query().Get("token")
    }
    return subtle.ConstantTimeCompare([]byte(candidate), []byte(token)) == 1
}
```

**Rationale:** `crypto/subtle.ConstantTimeCompare` performs the comparison in constant time regardless of the position of the first differing byte.

**Tests:** Add `TestVerifyTokenConstantTime` — verify that incorrect tokens are rejected (functionality); explicit timing verification is not possible in a unit test, but code review will show the use of subtle.

---

### 2. Race condition in event subscription

**File:** `cmd/relay/main.go:49-59`

**Problem:** The goroutine calls `Subscribe()` after startup. If `Start()` begins generating events before `Subscribe()` is called, they will be lost.

**Current code:**
```go
hub := ws.NewHub()

go func() {
    events := eventService.Subscribe()  // ← called inside the goroutine
    for event := range events {
        hub.BroadcastEvent(event)
    }
}()

if err := eventService.Start(); err != nil {  // ← Start may begin generating events before Subscribe
```

**Solution:**
```go
hub := ws.NewHub()
events := eventService.Subscribe()  // ← Subscribe BEFORE launching the goroutine and Start

go func() {
    for event := range events {
        hub.BroadcastEvent(event)
    }
}()

if err := eventService.Start(); err != nil {
```

**Rationale:** `Subscribe()` creates a channel and adds it to the listeners list before `Start()` begins broadcasting. EventService already has a sync.RWMutex protecting the listeners, so this is safe.

**Tests:** Add `TestEventSubscriptionOrdering` — verify that `Subscribe()` returns a channel before `Start()`, and that no events are lost.

---

### 3. Missing timeout in exec.Command

**File:** `internal/infrastructure/netdetect/detector.go`

**Problem:** All `exec.Command()` calls (ipconfig, hostname, tailscale) run without a timeout. A hung process blocks the HTTP handler forever.

**Methods to fix:**
- `LANIP()` — lines 45, 52
- `Tailscale()` — line 74
- `TailscaleReachable()` — already has a 2s timeout in net.DialTimeout, OK
- `FunnelEnabled()` — line 113

**Solution:** Add `context.WithTimeout(2*time.Second)` for all exec.Command calls:

```go
import "context"

func (SystemDetector) LANIP() string {
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    
    switch runtime.GOOS {
    case "darwin":
        for _, iface := range []string{"en0", "en1"} {
            out, err := exec.CommandContext(ctx, "ipconfig", "getifaddr", iface).Output()
            if err == nil {
                if ip := strings.TrimSpace(string(out)); ip != "" {
                    return ip
                }
            }
        }
    case "linux":
        out, err := exec.CommandContext(ctx, "hostname", "-I").Output()
        if err == nil {
            for _, ip := range strings.Fields(string(out)) {
                if !strings.Contains(ip, ":") {
                    return ip
                }
            }
        }
    }
    return ""
}
```

Do the same for `Tailscale()` and `FunnelEnabled()`.

**Rationale:** 2 seconds is enough for a local command to complete, but prevents infinite hangs.

**Tests:** The existing tests in `server_test.go` use `stubDetector`, which does not invoke real commands. Add an integration test with the real SystemDetector — verify that the methods return within a reasonable time (< 3s).

---

### 4. Race condition when creating token/identity files

**Files:** 
- `cmd/relay/token.go:12-32`
- `cmd/relay/identity.go:17-48`

**Problem:** Two concurrent relay processes can both read the missing file and create different tokens/relay_ids. The last WriteFile wins, but the first process will keep working with the wrong value.

**Solution:** Use `os.OpenFile` with the `O_EXCL` flag — it atomically creates the file and returns an error if the file already exists.

**For token.go:**
```go
func loadToken(cfg Config) (string, error) {
    if cfg.Token != "" {
        return cfg.Token, nil
    }
    
    // Try to read existing file
    if b, err := os.ReadFile(cfg.TokenFile); err == nil {
        if t := strings.TrimSpace(string(b)); t != "" {
            return t, nil
        }
    }
    
    // Generate new token
    tok, err := newToken()
    if err != nil {
        return "", err
    }
    
    // Create directory
    dir := filepath.Dir(cfg.TokenFile)
    if err := os.MkdirAll(dir, 0o700); err != nil {
        return "", err
    }
    
    // Atomic create with O_EXCL
    f, err := os.OpenFile(cfg.TokenFile, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
    if err != nil {
        if os.IsExist(err) {
            // Another process won the race, re-read the file
            return loadToken(cfg)
        }
        return "", err
    }
    defer f.Close()
    
    if _, err := f.WriteString(tok + "\n"); err != nil {
        return "", err
    }
    return tok, nil
}
```

**For identity.go:** The same logic, but with JSON marshalling.

**Rationale:** 
- `O_EXCL` guarantees atomic file creation at the OS level
- If the file already exists (another process won), make a recursive call to read the existing file
- The recursion is safe: at most 2 levels (the first creates, the second reads)

**Tests:** 
- Extend `TestLoadTokenCreatesFile` — run two concurrent loadToken() calls and verify that both get the same token
- Extend `TestLoadIdentityCreatesFile` — same for identity

---

## Execution order

1. **Fix timing attack** (task #1) — independent change, simple
2. **Fix event subscription race** (task #2) — independent change, simple
3. **Add timeouts to netdetect** (task #3) — independent change, medium complexity
4. **Fix token race** (task #4) — medium complexity
5. **Fix identity race** (task #5) — similar to #4, can copy the pattern
6. **Add tests** (task #6) — after all fixes, verify correctness

## Verification

After all changes:
1. Run the existing tests: `go test ./cmd/relay -v`
2. Run the new tests for the security fixes
3. Verify that the relay starts and responds to `/pair`
4. Verify that WebSocket clients receive events

## Risks and trade-offs

**Minimal changes:** All fixes are local and do not change public APIs or behavior (except for fixing bugs).

**Backwards compatibility:** 
- Token/identity files created by the old version are read by the new version without issues
- The new version creates files in the same format

**Performance:** 
- `subtle.ConstantTimeCompare` adds ~microseconds per HTTP request — imperceptible
- `context.WithTimeout` for exec.Command does not affect the happy path (commands execute quickly)
- O_EXCL in loadToken/loadIdentity is called once at startup — no impact

**Concurrency:** Race conditions are fixed; concurrent startup of relay processes is now safe.
