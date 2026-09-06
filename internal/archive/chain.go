package archive

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
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
	return mediaHashes(out, "claim media")
}

// FolderHashes returns the sha256s a FOLDER references — its one picture.
//
// A FOLDER IS A REFERENCE TOO, and until this existed it was not one. The realm
// has always had SetFolderImage and the overlay has always drawn `.mfimg` from
// it, but promotion ran over claims alone: `GetServable` serves `promoted = 1`
// only, so a folder's picture was uploaded, staged, never promoted, swept an
// hour later, and until then served as a 404. Every part worked and the picture
// could not appear on any deployment. Found on kourt.xyz the first time a folder
// was given one.
//
// FolderImage answers the same JSON as ClaimMedia — one item rather than a list,
// but the same shape — so this reads it the same way, purge rule included.
func (c *Chain) FolderHashes(ctx context.Context, court string, folderID uint64) ([]string, error) {
	out, err := c.qeval(ctx, fmt.Sprintf("FolderImage(%q,%d)", court, folderID))
	if err != nil {
		return nil, err
	}
	return mediaHashes(out, "folder image")
}

// ImagedFolders lists the folders of a court that carry a picture, in one read.
//
// THE TREE ALREADY KNOWS. FolderTree answers "id:parent:flags:bornOf" for every
// folder in the court, and `i` in the flags means this folder has an image — so
// the folders worth asking about are named by a read the client already makes,
// and a hundred FolderImage queries per pass become one plus the few that say
// yes. A court with no pictures costs exactly one query.
//
// A FOLDER'S PICTURE CAN BE SET AT ANY TIME, which is why backfill cannot walk
// folders behind a cursor the way it walks claims. A claim's evidence is fixed
// when it is filed, so a forward-only cursor sees all of it; a moderator can
// give folder 2 a picture years after folder 900 was made, and a cursor past it
// would never look again. This lists them all, every pass, cheaply.
func (c *Chain) ImagedFolders(ctx context.Context, court string) ([]uint64, error) {
	out, err := c.qeval(ctx, fmt.Sprintf("FolderTree(%q)", court))
	if err != nil {
		return nil, err
	}
	return imagedFolders(out), nil
}

// imagedFolders parses FolderTree's rows. Split out so the format is tested
// without a node, since this is the one place the archive reads that wire shape.
func imagedFolders(out string) []uint64 {
	body := unquoteQeval(out)
	var ids []uint64
	for _, row := range strings.Split(body, ",") {
		f := strings.Split(strings.TrimSpace(row), ":")
		if len(f) < 3 || !strings.Contains(f[2], "i") {
			continue
		}
		// A purged or retired folder still has its bytes referenced by the chain
		// until the image itself is cleared, and FolderImage is what says so —
		// this only decides who to ASK.
		id, err := strconv.ParseUint(f[0], 10, 64)
		if err != nil || id == 0 {
			continue
		}
		ids = append(ids, id)
	}
	return ids
}

// unquoteQeval strips the `("<json>" string)` wrapper qeval puts around a string
// answer. One spelling, because two readers of the same wire format is how they
// come to disagree about an escape.
func unquoteQeval(out string) string {
	body := out
	if i, j := bytes.IndexByte([]byte(body), '"'), bytes.LastIndexByte([]byte(body), '"'); i >= 0 && j > i {
		var unquoted string
		if err := json.Unmarshal([]byte(body[i:j+1]), &unquoted); err == nil {
			body = unquoted
		}
	}
	return body
}

// mediaHashes reads the JSON ClaimMedia and FolderImage both publish.
//
// A purged item yields nothing: the court has withdrawn its pointer to those
// bytes, so nothing here should be buying them permanent storage.
func mediaHashes(out, what string) ([]string, error) {
	var items []mediaItem
	if err := json.Unmarshal([]byte(unquoteQeval(out)), &items); err != nil {
		return nil, fmt.Errorf("%s was not the expected JSON: %w", what, err)
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
