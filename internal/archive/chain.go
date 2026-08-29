package archive

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// The chain is the only thing that can say a blob is worth keeping.
//
// PROMOTION IS THE WHOLE ANTI-ABUSE STORY. Staged bytes expire in an hour; they
// become permanent only when a claim on chain is seen to reference their hash.
// That reference is the one thing an attacker cannot fabricate or get for free,
// because filing a claim costs a deposit the court already charges.
//
// So this file is deliberately the smallest chain client that can answer one
// question — "does claim N of court C reference this hash?" — and nothing else.
// A general node client would be a much larger surface for a job with exactly
// one caller.

// Chain reads claim media from a gno node over JSON-RPC.
type Chain struct {
	// RPC is the node endpoint, e.g. https://rpc.kourt.xyz.
	RPC string
	// PkgPath is the realm, e.g. gno.land/r/kourt/kourtv2.
	PkgPath string
	// HTTP is the client used for queries; nil means a 10-second default.
	HTTP *http.Client
}

type rpcResponse struct {
	Error  *struct{ Message string } `json:"error"`
	Result struct {
		Response struct {
			Data         string `json:"Data"`
			Error        any    `json:"Error"`
			Log          string `json:"Log"`
			ResponseBase *struct {
				Data  string `json:"Data"`
				Error any    `json:"Error"`
				Log   string `json:"Log"`
			} `json:"ResponseBase"`
		} `json:"response"`
	} `json:"result"`
}

// qeval evaluates one expression against the realm and returns the raw typed
// output, exactly as the overlay's own reader sees it.
func (c *Chain) qeval(ctx context.Context, expr string) (string, error) {
	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": "archive", "method": "abci_query",
		"params": map[string]any{
			"path":   "vm/qeval",
			"data":   base64.StdEncoding.EncodeToString([]byte(c.PkgPath + "." + expr)),
			"height": "0", "prove": false,
		},
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.RPC, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")

	hc := c.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 10 * time.Second}
	}
	res, err := hc.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("node HTTP %d", res.StatusCode)
	}

	var out rpcResponse
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		return "", err
	}
	if out.Error != nil {
		return "", fmt.Errorf("rpc: %s", out.Error.Message)
	}
	r := out.Result.Response
	data, logMsg, qErr := r.Data, r.Log, r.Error
	if r.ResponseBase != nil {
		// Older nodes nest the same three fields one level down.
		if data == "" {
			data = r.ResponseBase.Data
		}
		if qErr == nil {
			qErr, logMsg = r.ResponseBase.Error, r.ResponseBase.Log
		}
	}
	if qErr != nil {
		return "", fmt.Errorf("query failed: %s", logMsg)
	}
	if data == "" {
		return "", nil
	}
	raw, err := base64.StdEncoding.DecodeString(data)
	if err != nil {
		return "", fmt.Errorf("decoding node reply: %w", err)
	}
	return string(raw), nil
}

// ClaimCount is how many claims a court has ever opened, so backfill knows
// where the end is.
func (c *Chain) ClaimCount(ctx context.Context, court string) (uint64, error) {
	out, err := c.qeval(ctx, fmt.Sprintf("ClaimCount(%q)", court))
	if err != nil {
		return 0, err
	}
	// qeval answers `(12 uint64)`.
	var n uint64
	if _, err := fmt.Sscanf(strings.TrimSpace(out), "(%d", &n); err != nil {
		return 0, fmt.Errorf("claim count was not a number: %q", out)
	}
	return n, nil
}

// mediaItem is the shape ClaimMedia publishes. Only the hash is read here — the
// archive has no opinion about captions or dimensions.
type mediaItem struct {
	Kind   string `json:"kind"`
	SHA256 string `json:"sha256"`
	Purged bool   `json:"purged"`
}

// ClaimHashes returns the sha256s a claim references, as the chain reports them.
//
// A purged item yields nothing: the court has withdrawn its pointer to those
// bytes, so nothing here should be buying them permanent storage.
func (c *Chain) ClaimHashes(ctx context.Context, court string, claimID uint64) ([]string, error) {
	out, err := c.qeval(ctx, fmt.Sprintf("ClaimMedia(%q,%d)", court, claimID))
	if err != nil {
		return nil, err
	}
	// qeval answers `("<json>" string)`; the payload is one line by construction.
	body := out
	if i, j := bytes.IndexByte([]byte(body), '"'), bytes.LastIndexByte([]byte(body), '"'); i >= 0 && j > i {
		var unquoted string
		if err := json.Unmarshal([]byte(body[i:j+1]), &unquoted); err == nil {
			body = unquoted
		}
	}
	var items []mediaItem
	if err := json.Unmarshal([]byte(body), &items); err != nil {
		return nil, fmt.Errorf("claim media was not the expected JSON: %w", err)
	}
	hashes := make([]string, 0, len(items))
	for _, it := range items {
		if it.Purged || !digestRe.MatchString(it.SHA256) {
			continue
		}
		hashes = append(hashes, it.SHA256)
	}
	return hashes, nil
}
