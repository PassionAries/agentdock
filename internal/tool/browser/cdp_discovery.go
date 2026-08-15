package browser

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const cdpProbeTimeout = 500 * time.Millisecond

var (
	remoteDebuggingPortPattern = regexp.MustCompile(`--remote-debugging-port(?:=|\s+)(\d+)`)
	userDataDirPattern         = regexp.MustCompile(`--user-data-dir(?:=|\s+)(?:"([^"]+)"|'([^']+)'|([^\s]+))`)
)

type cdpCandidate struct {
	URL    string
	Source string
}

type cdpVersion struct {
	WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
}

func validateCDPURL(rawURL string) error {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || parsed.Host == "" {
		return fmt.Errorf("CDP endpoint must be an absolute URL")
	}
	if parsed.User != nil || parsed.Fragment != "" {
		return fmt.Errorf("CDP endpoint must not contain user info or a fragment")
	}
	switch strings.ToLower(parsed.Scheme) {
	case "http", "https", "ws", "wss":
		return nil
	default:
		return fmt.Errorf("CDP endpoint must use http, https, ws, or wss")
	}
}

// Tool-level CDP URLs are model-controlled input, so keep them on loopback.
// User-configured endpoints may be remote (for example from Docker) because the
// administrator explicitly chose that network boundary.
func validateToolCDPURL(rawURL string) error {
	if err := validateCDPURL(rawURL); err != nil {
		return err
	}
	parsed, _ := url.Parse(strings.TrimSpace(rawURL))
	host := strings.TrimSpace(parsed.Hostname())
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("tool cdp_url must target a loopback IP; configure named or remote CDP endpoints in AgentDock settings")
	}
	return nil
}

func directHTTPClient(timeout time.Duration) *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	return &http.Client{
		Transport: transport,
		Timeout:   timeout,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func resolveCDPWebSocket(parent context.Context, rawURL string, timeout time.Duration) (string, error) {
	if err := validateCDPURL(rawURL); err != nil {
		return "", err
	}
	parsed, _ := url.Parse(strings.TrimSpace(rawURL))
	if (parsed.Scheme == "ws" || parsed.Scheme == "wss") && strings.Contains(parsed.Path, "/devtools/browser/") {
		return parsed.String(), nil
	}

	endpoint := *parsed
	switch strings.ToLower(endpoint.Scheme) {
	case "ws":
		endpoint.Scheme = "http"
	case "wss":
		endpoint.Scheme = "https"
	}
	endpoint.Path = "/json/version"
	endpoint.RawPath = ""
	endpoint.RawQuery = ""
	endpoint.Fragment = ""

	if timeout <= 0 || timeout > 20*time.Second {
		timeout = 20 * time.Second
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return "", err
	}
	resp, err := directHTTPClient(timeout).Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("unexpected CDP status: %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	var version cdpVersion
	if err := json.Unmarshal(data, &version); err != nil {
		return "", err
	}
	wsURL := strings.TrimSpace(version.WebSocketDebuggerURL)
	wsParsed, err := url.Parse(wsURL)
	if err != nil || wsParsed.Host == "" || (wsParsed.Scheme != "ws" && wsParsed.Scheme != "wss") || !strings.Contains(wsParsed.Path, "/devtools/browser/") {
		return "", fmt.Errorf("CDP endpoint did not expose a valid browser websocket")
	}
	// The configured HTTP endpoint is the trust boundary. Chrome normally
	// advertises the same listener host, but gateways and containerized
	// browsers may report an internal hostname. Keep the advertised browser
	// path while pinning the connection to the endpoint the user selected.
	wsParsed.Host = endpoint.Host
	return wsParsed.String(), nil
}

func discoverCDPEndpoints(ctx context.Context) ([]cdpCandidate, error) {
	candidateByURL := make(map[string]cdpCandidate)
	add := func(rawURL, source string) {
		rawURL = strings.TrimSpace(rawURL)
		if rawURL == "" {
			return
		}
		if _, exists := candidateByURL[rawURL]; !exists {
			candidateByURL[rawURL] = cdpCandidate{URL: rawURL, Source: source}
		}
	}

	lines, _ := browserProcessCommandLines(ctx)
	for _, line := range lines {
		lower := strings.ToLower(line)
		if !strings.Contains(lower, "chrome") && !strings.Contains(lower, "chromium") && !strings.Contains(lower, "msedge") && !strings.Contains(lower, "microsoft edge") {
			continue
		}
		portMatch := remoteDebuggingPortPattern.FindStringSubmatch(line)
		dataDir := extractUserDataDir(line)
		if len(portMatch) == 2 {
			port, err := strconv.Atoi(portMatch[1])
			if err == nil && port > 0 && port <= 65535 {
				add(fmt.Sprintf("http://127.0.0.1:%d", port), "process")
			}
			if port == 0 && dataDir != "" {
				if candidate, ok := candidateFromDevToolsActivePort(dataDir); ok {
					add(candidate.URL, candidate.Source)
				}
			}
		}
		if dataDir != "" {
			if candidate, ok := candidateFromDevToolsActivePort(dataDir); ok {
				add(candidate.URL, candidate.Source)
			}
		}
	}

	urls := make([]string, 0, len(candidateByURL))
	for rawURL := range candidateByURL {
		urls = append(urls, rawURL)
	}
	sort.Strings(urls)
	valid := make([]cdpCandidate, 0, len(urls))
	for _, rawURL := range urls {
		if err := probeCDPEndpoint(ctx, rawURL); err == nil {
			valid = append(valid, candidateByURL[rawURL])
		}
	}
	return valid, nil
}

func extractUserDataDir(line string) string {
	match := userDataDirPattern.FindStringSubmatch(line)
	if len(match) == 0 {
		return ""
	}
	for _, value := range match[1:] {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func candidateFromDevToolsActivePort(userDataDir string) (cdpCandidate, bool) {
	path := filepath.Join(userDataDir, "DevToolsActivePort")
	data, err := os.ReadFile(path)
	if err != nil || len(data) > 4096 {
		return cdpCandidate{}, false
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) == 0 {
		return cdpCandidate{}, false
	}
	port, err := strconv.Atoi(strings.TrimSpace(lines[0]))
	if err != nil || port < 1 || port > 65535 {
		return cdpCandidate{}, false
	}
	return cdpCandidate{URL: fmt.Sprintf("http://127.0.0.1:%d", port), Source: "devtools_active_port"}, true
}

func probeCDPEndpoint(parent context.Context, baseURL string) error {
	ctx, cancel := context.WithTimeout(parent, cdpProbeTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(baseURL, "/")+"/json/version", nil)
	if err != nil {
		return err
	}
	resp, err := directHTTPClient(cdpProbeTimeout).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("unexpected CDP status: %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	var version cdpVersion
	if err := json.Unmarshal(data, &version); err != nil {
		return err
	}
	if !strings.HasPrefix(version.WebSocketDebuggerURL, "ws://") && !strings.HasPrefix(version.WebSocketDebuggerURL, "wss://") {
		return fmt.Errorf("CDP endpoint did not expose a browser websocket")
	}
	return nil
}
