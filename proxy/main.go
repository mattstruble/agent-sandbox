package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/elazarl/goproxy"
)

// proxy holds the configured proxy handler and whitelist.
type proxy struct {
	handler   http.Handler
	whitelist []string
}

// parseWhitelist splits a comma-separated string of domains/origins into
// a cleaned list of bare hostnames (scheme and path stripped).
func parseWhitelist(raw string) []string {
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	var result []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		// Strip scheme and path if present
		if strings.Contains(p, "://") {
			if u, err := url.Parse(p); err == nil && u.Host != "" {
				p = u.Host
			}
		}
		// Strip port-less path (e.g., "example.com/v1")
		if idx := strings.Index(p, "/"); idx >= 0 {
			p = p[:idx]
		}
		// Strip port using net.SplitHostPort for correct IPv6 handling
		p = stripPort(p)
		result = append(result, p)
	}
	return result
}

// stripPort removes the port from a host:port string, handling IPv6 brackets.
// Returns the bare hostname if no port is present or on parse error.
func stripPort(hostport string) string {
	h, _, err := net.SplitHostPort(hostport)
	if err != nil {
		// No port present, or malformed — return as-is (stripped of brackets)
		return strings.TrimRight(strings.TrimLeft(hostport, "["), "]")
	}
	return h
}

// isWhitelisted checks whether a host (with optional port) matches any entry
// in the whitelist. Supports wildcard segments (e.g., "bedrock-runtime.*.amazonaws.com").
func isWhitelisted(host string, whitelist []string) bool {
	h := strings.ToLower(stripPort(host))

	for _, entry := range whitelist {
		entry = strings.ToLower(stripPort(entry))
		if entry == h {
			return true
		}
		// Wildcard matching: "bedrock-runtime.*.amazonaws.com"
		if strings.Contains(entry, "*") {
			if matchWildcard(entry, h) {
				return true
			}
		}
	}
	return false
}

// matchWildcard matches a pattern like "a.*.b.com" against a host like "a.us-east-1.b.com".
// Each * matches exactly one dot-separated segment.
func matchWildcard(pattern, host string) bool {
	pParts := strings.Split(pattern, ".")
	hParts := strings.Split(host, ".")
	if len(pParts) != len(hParts) {
		return false
	}
	for i, pp := range pParts {
		if pp == "*" {
			continue
		}
		if pp != hParts[i] {
			return false
		}
	}
	return true
}

// isWriteMethod returns true for HTTP methods that modify server state.
func isWriteMethod(method string) bool {
	switch strings.ToUpper(method) {
	case "POST", "PUT", "PATCH", "DELETE":
		return true
	}
	return false
}

// isWebSocketUpgrade checks if a request is a WebSocket upgrade request.
// Requires both Upgrade: websocket and Connection: Upgrade headers per RFC 6455.
func isWebSocketUpgrade(req *http.Request) bool {
	if !strings.EqualFold(req.Header.Get("Upgrade"), "websocket") {
		return false
	}
	// Connection header may contain multiple tokens (e.g., "keep-alive, Upgrade")
	for _, tok := range strings.Split(req.Header.Get("Connection"), ",") {
		if strings.EqualFold(strings.TrimSpace(tok), "upgrade") {
			return true
		}
	}
	return false
}

// blockedResponse returns a 403 response with a descriptive body.
func blockedResponse(req *http.Request) *http.Response {
	host := req.URL.Host
	if host == "" {
		host = req.Host
	}
	body := fmt.Sprintf(
		"403 Forbidden\n\n"+
			"agent-sandbox proxy blocked this request:\n"+
			"  Method: %s\n"+
			"  Domain: %s\n\n"+
			"To allow write requests to this domain, add it to\n"+
			"[proxy].allowed_post_urls in your config.toml:\n\n"+
			"  [proxy]\n"+
			"  allowed_post_urls = [\"%s\"]\n",
		req.Method, host, host,
	)

	return goproxy.NewResponse(req, "text/plain", http.StatusForbidden, body)
}

// logBlocked logs a blocked request to stderr.
func logBlocked(method, host string) {
	log.Printf("BLOCKED %s %s", method, host)
}

// newProxy creates a configured proxy. certFile and keyFile are paths to the
// CA certificate and key used for MITM HTTPS interception.
//
// NOTE: goproxy.GoproxyCa is a package-level global. This function must not be
// called concurrently. In tests, do not use t.Parallel() on tests that call
// startTestProxy/newProxy.
func newProxy(whitelist []string, certFile, keyFile string) (*proxy, error) {
	// Load CA cert and key for MITM
	caCert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load CA keypair: %w", err)
	}

	// goproxy requires the CA to be set as a package global (no per-instance API)
	goproxy.GoproxyCa = caCert

	px := goproxy.NewProxyHttpServer()
	px.Verbose = false

	// Verify upstream TLS certificates (goproxy defaults to InsecureSkipVerify)
	px.Tr = &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: false},
	}

	// For HTTPS: always MITM so we can inspect the request method
	px.OnRequest().HandleConnect(goproxy.AlwaysMitm)

	// For both HTTP and HTTPS requests (after MITM decryption):
	px.OnRequest().DoFunc(func(req *http.Request, ctx *goproxy.ProxyCtx) (*http.Request, *http.Response) {
		host := req.URL.Host
		if host == "" {
			host = req.Host
		}

		// WebSocket upgrade to non-whitelisted domain
		if isWebSocketUpgrade(req) && !isWhitelisted(host, whitelist) {
			logBlocked("WEBSOCKET", host)
			return req, blockedResponse(req)
		}

		// Write method to non-whitelisted domain
		if isWriteMethod(req.Method) && !isWhitelisted(host, whitelist) {
			logBlocked(req.Method, host)
			return req, blockedResponse(req)
		}

		// Allow — pass through unmodified
		return req, nil
	})

	return &proxy{
		handler:   px,
		whitelist: whitelist,
	}, nil
}

func main() {
	// Configure logging first, before any log output
	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ldate | log.Ltime)

	listenAddr := os.Getenv("PROXY_LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8080"
	}

	certFile := os.Getenv("PROXY_CA_CERT")
	keyFile := os.Getenv("PROXY_CA_KEY")
	if certFile == "" || keyFile == "" {
		log.Fatal("PROXY_CA_CERT and PROXY_CA_KEY environment variables must be set")
	}

	whitelistRaw := os.Getenv("PROXY_ALLOW_POST")
	whitelist := parseWhitelist(whitelistRaw)

	log.Printf("Starting sandbox-proxy on %s", listenAddr)

	p, err := newProxy(whitelist, certFile, keyFile)
	if err != nil {
		log.Fatalf("Failed to create proxy: %v", err)
	}

	if err := http.ListenAndServe(listenAddr, p.handler); err != nil {
		log.Fatalf("Proxy server failed: %v", err)
	}
}
