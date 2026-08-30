package clusterhealth

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1" //nolint:gosec // SHA-1 is required by the WebSocket handshake protocol.
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/textproto"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type EdgeOptions struct {
	SkipHTTP3                bool
	IncludeESPHomeCanary     bool
	ESPHomeWebSocketPath     string
	ESPHomeWebSocketContains string
}

type httpCheck struct {
	name          string
	url           string
	expectedCodes map[int]struct{}
}

type webSocketCheck struct {
	name            string
	host            string
	path            string
	expectSubstring string
	port            int
}

var baselineHTTPChecks = []httpCheck{
	newHTTPCheck("Home Assistant", "https://home-assistant.ironstone.casa/"),
	newHTTPCheck("code-server", "https://code.ironstone.casa/"),
	newHTTPCheck("Echo Server", "https://echo-server.ironstone.casa/"),
}

var baselineWebSocketChecks = []webSocketCheck{
	{
		name:            "Home Assistant WebSocket",
		host:            "home-assistant.ironstone.casa",
		path:            "/api/websocket",
		expectSubstring: "auth_required",
		port:            443,
	},
}

func newHTTPCheck(name, target string) httpCheck {
	return httpCheck{
		name: name,
		url:  target,
		expectedCodes: map[int]struct{}{
			200: {},
			301: {},
			302: {},
			308: {},
		},
	}
}

func (c *Checker) EdgeSmoke(ctx context.Context, options EdgeOptions) Result {
	curlPath := c.resolveCurl(ctx)
	if curlPath == "" {
		return Result{
			Name:    "edge-smoke",
			Status:  StatusFail,
			Summary: "edge smoke failed",
			Details: []string{"curl is required"},
		}
	}

	checks := append([]httpCheck{}, baselineHTTPChecks...)
	if options.IncludeESPHomeCanary {
		checks = append(checks, newHTTPCheck("ESPHome canary", "https://esphome-traefik.ironstone.casa/"))
	}
	details := []string{"[INFO] Using curl: " + curlPath}
	failed := false
	for _, check := range checks {
		for _, version := range []string{"http1.1", "http2"} {
			ok, detail := c.runHTTPCheck(ctx, curlPath, check, version)
			details = append(details, detail)
			failed = failed || !ok
		}
		if !options.SkipHTTP3 {
			ok, detail := c.runHTTPCheck(ctx, curlPath, check, "http3")
			details = append(details, detail)
			failed = failed || !ok
		}
	}
	for _, check := range baselineWebSocketChecks {
		ok, detail := runWebSocketCheck(ctx, check)
		details = append(details, detail)
		failed = failed || !ok
	}
	if options.IncludeESPHomeCanary && options.ESPHomeWebSocketPath != "" {
		ok, detail := runWebSocketCheck(ctx, webSocketCheck{
			name:            "ESPHome canary WebSocket",
			host:            "esphome-traefik.ironstone.casa",
			path:            options.ESPHomeWebSocketPath,
			expectSubstring: options.ESPHomeWebSocketContains,
			port:            443,
		})
		details = append(details, detail)
		failed = failed || !ok
	}
	return NewResult("edge-smoke", failed, "edge smoke passed", "edge smoke failed", details)
}

func (c *Checker) resolveCurl(ctx context.Context) string {
	const homebrewCurl = "/opt/homebrew/opt/curl/bin/curl"
	if _, err := os.Stat(homebrewCurl); err == nil {
		version := c.Runner.Run(ctx, homebrewCurl, "-V")
		if version.ExitCode == 0 && strings.Contains(version.Stdout, "HTTP3") {
			return homebrewCurl
		}
	}
	path, err := exec.LookPath("curl")
	if err != nil {
		return ""
	}
	return path
}

func (c *Checker) runHTTPCheck(ctx context.Context, curlPath string, check httpCheck, version string) (bool, string) {
	args := []string{
		"--silent",
		"--show-error",
		"--output", "/dev/null",
		"--write-out", "%{http_code}",
		"--max-time", "20",
	}
	switch version {
	case "http1.1":
		args = append(args, "--http1.1")
	case "http2":
		args = append(args, "--http2")
	case "http3":
		args = append(args, "--http3-only")
	default:
		return false, fmt.Sprintf("[FAIL] %s %s: unsupported HTTP version", check.name, version)
	}
	args = append(args, check.url)
	output := c.Runner.Run(ctx, curlPath, args...)
	if output.ExitCode != 0 {
		if version == "http3" && strings.Contains(output.Stderr, "option --http3-only") {
			return true, fmt.Sprintf("[WARN] %s %s: local curl build lacks HTTP/3 support", check.name, version)
		}
		return false, fmt.Sprintf(
			"[FAIL] %s %s: curl exited %d: %s",
			check.name,
			version,
			output.ExitCode,
			strings.TrimSpace(output.Stderr),
		)
	}
	statusCode, err := strconv.Atoi(strings.TrimSpace(output.Stdout))
	if err != nil {
		return false, fmt.Sprintf("[FAIL] %s %s: unexpected status output %q", check.name, version, output.Stdout)
	}
	if _, ok := check.expectedCodes[statusCode]; !ok {
		return false, fmt.Sprintf("[FAIL] %s %s: unexpected HTTP status %d", check.name, version, statusCode)
	}
	return true, fmt.Sprintf("[PASS] %s %s: %d", check.name, version, statusCode)
}

func runWebSocketCheck(ctx context.Context, check webSocketCheck) (bool, string) {
	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		return false, fmt.Sprintf("[FAIL] %s: generate WebSocket key: %v", check.name, err)
	}
	key := base64.StdEncoding.EncodeToString(keyBytes)
	address := net.JoinHostPort(check.host, strconv.Itoa(check.port))
	dialer := &net.Dialer{Timeout: 20 * time.Second}
	tlsConfig := &tls.Config{
		ServerName: check.host,
		MinVersion: tls.VersionTLS12,
	}
	connection, err := tls.DialWithDialer(dialer, "tcp", address, tlsConfig)
	if err != nil {
		return false, fmt.Sprintf("[FAIL] %s: %v", check.name, err)
	}
	defer connection.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = connection.SetDeadline(deadline)
	} else {
		_ = connection.SetDeadline(time.Now().Add(20 * time.Second))
	}

	const requestTemplate = "GET %s HTTP/1.1\r\n" +
		"Host: %s\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: %s\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Origin: https://%s\r\n\r\n"
	request := fmt.Sprintf(
		requestTemplate,
		check.path,
		check.host,
		key,
		check.host,
	)
	if _, err := io.WriteString(connection, request); err != nil {
		return false, fmt.Sprintf("[FAIL] %s: %v", check.name, err)
	}
	reader := bufio.NewReader(connection)
	statusLine, err := reader.ReadString('\n')
	if err != nil {
		return false, fmt.Sprintf("[FAIL] %s: read handshake: %v", check.name, err)
	}
	headers, err := textproto.NewReader(reader).ReadMIMEHeader()
	if err != nil {
		return false, fmt.Sprintf("[FAIL] %s: read handshake headers: %v", check.name, err)
	}
	if !strings.Contains(statusLine, "101 Switching Protocols") {
		return false, fmt.Sprintf("[FAIL] %s: missing 101 response", check.name)
	}
	digest := sha1.Sum([]byte(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	expectedAccept := base64.StdEncoding.EncodeToString(digest[:])
	if headers.Get("Sec-WebSocket-Accept") != expectedAccept {
		return false, fmt.Sprintf("[FAIL] %s: invalid Sec-WebSocket-Accept", check.name)
	}
	if check.expectSubstring != "" {
		payload, err := readWebSocketFrame(reader)
		if err != nil {
			return false, fmt.Sprintf("[FAIL] %s: %v", check.name, err)
		}
		if !strings.Contains(string(payload), check.expectSubstring) {
			return false, fmt.Sprintf(
				"[FAIL] %s: expected payload containing %q, got %q",
				check.name,
				check.expectSubstring,
				payload,
			)
		}
	}
	return true, fmt.Sprintf("[PASS] %s: websocket handshake succeeded", check.name)
}

func readWebSocketFrame(reader io.Reader) ([]byte, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(reader, header); err != nil {
		return nil, fmt.Errorf("read WebSocket frame: %w", err)
	}
	payloadLength := uint64(header[1] & 0x7f)
	switch payloadLength {
	case 126:
		extended := make([]byte, 2)
		if _, err := io.ReadFull(reader, extended); err != nil {
			return nil, fmt.Errorf("read WebSocket frame length: %w", err)
		}
		payloadLength = uint64(extended[0])<<8 | uint64(extended[1])
	case 127:
		extended := make([]byte, 8)
		if _, err := io.ReadFull(reader, extended); err != nil {
			return nil, fmt.Errorf("read WebSocket frame length: %w", err)
		}
		payloadLength = 0
		for _, current := range extended {
			payloadLength = payloadLength<<8 | uint64(current)
		}
	}
	masked := header[1]&0x80 != 0
	mask := make([]byte, 4)
	if masked {
		if _, err := io.ReadFull(reader, mask); err != nil {
			return nil, fmt.Errorf("read WebSocket mask: %w", err)
		}
	}
	if payloadLength > 1<<20 {
		return nil, fmt.Errorf("WebSocket frame exceeds 1 MiB")
	}
	payload := make([]byte, int(payloadLength))
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, fmt.Errorf("read WebSocket payload: %w", err)
	}
	if masked {
		for index := range payload {
			payload[index] ^= mask[index%len(mask)]
		}
	}
	return payload, nil
}
