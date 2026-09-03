package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"herdrelay/internal/domain"
)

// fetchPairInfo calls GET /pair on the local relay with the given token and
// decodes the pairing info. Shared by `herdrelay pair` and `herdrelay status`.
func fetchPairInfo(base, token string) (domain.PairInfo, error) {
	req, err := http.NewRequest("GET", base+"/pair", nil)
	if err != nil {
		return domain.PairInfo{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return domain.PairInfo{}, fmt.Errorf("relay is not responding (%v) — start it (launchctl start / install.sh)", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return domain.PairInfo{}, fmt.Errorf("relay responded %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	var info domain.PairInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return domain.PairInfo{}, err
	}
	return info, nil
}
