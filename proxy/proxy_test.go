package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

// generateTestCA creates a self-signed CA cert+key for MITM testing.
func generateTestCA() (certPEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}

	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test CA"},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}

	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})

	return certPEM, keyPEM, nil
}

// startTestProxy starts a proxy with the given whitelist and returns its URL and cleanup func.
func startTestProxy(t *testing.T, whitelist []string) (proxyURL string, cleanup func()) {
	t.Helper()

	certPEM, keyPEM, err := generateTestCA()
	if err != nil {
		t.Fatalf("generate CA: %v", err)
	}

	certFile, err := os.CreateTemp("", "proxy-test-cert-*.pem")
	if err != nil {
		t.Fatalf("create cert temp file: %v", err)
	}
	if _, err := certFile.Write(certPEM); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	certFile.Close()

	keyFile, err := os.CreateTemp("", "proxy-test-key-*.pem")
	if err != nil {
		t.Fatalf("create key temp file: %v", err)
	}
	if _, err := keyFile.Write(keyPEM); err != nil {
		t.Fatalf("write key: %v", err)
	}
	keyFile.Close()

	p, err := newProxy(whitelist, certFile.Name(), keyFile.Name())
	if err != nil {
		t.Fatalf("newProxy: %v", err)
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	go http.Serve(listener, p.handler)

	addr := listener.Addr().String()
	return "http://" + addr, func() {
		listener.Close()
		os.Remove(certFile.Name())
		os.Remove(keyFile.Name())
	}
}

// proxyClient returns an http.Client configured to use the given proxy URL,
// trusting the given CA cert for HTTPS.
func proxyClient(t *testing.T, proxyURL string, caCertPEM []byte) *http.Client {
	t.Helper()

	purl, err := url.Parse(proxyURL)
	if err != nil {
		t.Fatalf("parse proxy URL: %v", err)
	}

	pool := x509.NewCertPool()
	if caCertPEM != nil {
		pool.AppendCertsFromPEM(caCertPEM)
	}

	return &http.Client{
		Transport: &http.Transport{
			Proxy:           http.ProxyURL(purl),
			TLSClientConfig: &tls.Config{RootCAs: pool},
		},
		Timeout: 5 * time.Second,
	}
}

// ---------------------------------------------------------------------------
// Whitelist parsing tests
// ---------------------------------------------------------------------------

func TestParseWhitelist(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{"empty string", "", nil},
		{"single domain", "api.example.com", []string{"api.example.com"}},
		{"multiple domains", "api.example.com,api.other.io", []string{"api.example.com", "api.other.io"}},
		{"strips whitespace", " api.example.com , api.other.io ", []string{"api.example.com", "api.other.io"}},
		{"skips empty segments", "api.example.com,,api.other.io", []string{"api.example.com", "api.other.io"}},
		{"strips scheme prefix", "https://api.example.com", []string{"api.example.com"}},
		{"strips http scheme", "http://api.example.com", []string{"api.example.com"}},
		{"strips path", "https://api.example.com/v1/chat", []string{"api.example.com"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseWhitelist(tt.input)
			if len(got) != len(tt.want) {
				t.Fatalf("parseWhitelist(%q) = %v (len %d), want %v (len %d)",
					tt.input, got, len(got), tt.want, len(tt.want))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("parseWhitelist(%q)[%d] = %q, want %q",
						tt.input, i, got[i], tt.want[i])
				}
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Domain matching tests
// ---------------------------------------------------------------------------

func TestIsWhitelisted(t *testing.T) {
	whitelist := []string{"api.example.com", "bedrock-runtime.*.amazonaws.com", "127.0.0.1:8080"}

	tests := []struct {
		host string
		want bool
	}{
		{"api.example.com", true},
		{"api.example.com:443", true},
		{"API.EXAMPLE.COM", true},
		{"evil.com", false},
		{"sub.api.example.com", false},
		{"bedrock-runtime.us-east-1.amazonaws.com", true},
		{"bedrock-runtime.eu-west-1.amazonaws.com", true},
		{"bedrock-runtime.amazonaws.com", false},
		{"notbedrock-runtime.us-east-1.amazonaws.com", false},
		{"127.0.0.1:8080", true},
		{"127.0.0.1", true},
	}

	for _, tt := range tests {
		t.Run(tt.host, func(t *testing.T) {
			got := isWhitelisted(tt.host, whitelist)
			if got != tt.want {
				t.Errorf("isWhitelisted(%q, ...) = %v, want %v", tt.host, got, tt.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// HTTP method filtering tests (plain HTTP via upstream test server)
// ---------------------------------------------------------------------------

func TestMethodFiltering_HTTP(t *testing.T) {
	// Start a simple upstream HTTP server
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "OK %s", r.Method)
	}))
	defer upstream.Close()

	// Extract upstream host for whitelisting
	upstreamURL, _ := url.Parse(upstream.URL)

	tests := []struct {
		name       string
		method     string
		whitelist  []string
		wantStatus int
	}{
		{"GET always allowed", "GET", nil, 200},
		{"HEAD always allowed", "HEAD", nil, 200},
		{"OPTIONS always allowed", "OPTIONS", nil, 200},
		{"POST blocked when not whitelisted", "POST", nil, 403},
		{"PUT blocked when not whitelisted", "PUT", nil, 403},
		{"PATCH blocked when not whitelisted", "PATCH", nil, 403},
		{"DELETE blocked when not whitelisted", "DELETE", nil, 403},
		{"POST allowed when whitelisted", "POST", []string{upstreamURL.Host}, 200},
		{"PUT allowed when whitelisted", "PUT", []string{upstreamURL.Host}, 200},
		{"PATCH allowed when whitelisted", "PATCH", []string{upstreamURL.Host}, 200},
		{"DELETE allowed when whitelisted", "DELETE", []string{upstreamURL.Host}, 200},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			proxyURL, cleanup := startTestProxy(t, tt.whitelist)
			defer cleanup()

			client := proxyClient(t, proxyURL, nil)
			req, err := http.NewRequest(tt.method, upstream.URL+"/test", nil)
			if err != nil {
				t.Fatalf("create request: %v", err)
			}

			resp, err := client.Do(req)
			if err != nil {
				t.Fatalf("request failed: %v", err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != tt.wantStatus {
				t.Errorf("got status %d, want %d", resp.StatusCode, tt.wantStatus)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// 403 response body test
// ---------------------------------------------------------------------------

func TestBlockedResponse_ContainsDetails(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()

	proxyURL, cleanup := startTestProxy(t, nil)
	defer cleanup()

	client := proxyClient(t, proxyURL, nil)
	req, err := http.NewRequest("POST", upstream.URL+"/api/chat", nil)
	if err != nil {
		t.Fatalf("create request: %v", err)
	}

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 403 {
		t.Fatalf("expected 403, got %d", resp.StatusCode)
	}

	buf := make([]byte, 4096)
	n, _ := resp.Body.Read(buf)
	body := string(buf[:n])

	// Must include method, domain, and instructions
	if !strings.Contains(body, "POST") {
		t.Errorf("403 body missing method 'POST': %s", body)
	}
	upstreamURL, _ := url.Parse(upstream.URL)
	if !strings.Contains(body, upstreamURL.Host) {
		t.Errorf("403 body missing domain %q: %s", upstreamURL.Host, body)
	}
	if !strings.Contains(body, "allowed_post_urls") {
		t.Errorf("403 body missing config instructions: %s", body)
	}
}

// ---------------------------------------------------------------------------
// WebSocket filtering test
// ---------------------------------------------------------------------------

func TestWebSocketFiltering(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer upstream.Close()

	upstreamURL, _ := url.Parse(upstream.URL)

	tests := []struct {
		name       string
		whitelist  []string
		wantStatus int
	}{
		{"blocked when not whitelisted", nil, 403},
		{"allowed when whitelisted", []string{upstreamURL.Host}, 200},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			proxyURL, cleanup := startTestProxy(t, tt.whitelist)
			defer cleanup()

			client := proxyClient(t, proxyURL, nil)
			req, err := http.NewRequest("GET", upstream.URL+"/ws", nil)
			if err != nil {
				t.Fatalf("create request: %v", err)
			}
			req.Header.Set("Upgrade", "websocket")
			req.Header.Set("Connection", "Upgrade")

			resp, err := client.Do(req)
			if err != nil {
				t.Fatalf("request failed: %v", err)
			}
			defer resp.Body.Close()

			if resp.StatusCode != tt.wantStatus {
				t.Errorf("got status %d, want %d", resp.StatusCode, tt.wantStatus)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Request/response body non-modification test
// ---------------------------------------------------------------------------

func TestAllowedRequestNotModified(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Echo back the User-Agent to prove headers are preserved
		w.Header().Set("X-Echo-UA", r.Header.Get("User-Agent"))
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "response-body-intact")
	}))
	defer upstream.Close()

	proxyURL, cleanup := startTestProxy(t, nil)
	defer cleanup()

	client := proxyClient(t, proxyURL, nil)
	req, err := http.NewRequest("GET", upstream.URL+"/test", nil)
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	req.Header.Set("User-Agent", "test-agent-1234")

	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	if got := resp.Header.Get("X-Echo-UA"); got != "test-agent-1234" {
		t.Errorf("header not preserved: got %q, want %q", got, "test-agent-1234")
	}

	buf := make([]byte, 4096)
	n, _ := resp.Body.Read(buf)
	body := string(buf[:n])
	if body != "response-body-intact" {
		t.Errorf("response body modified: got %q", body)
	}
}
