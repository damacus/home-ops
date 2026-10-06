package clusterhealth

import (
	"bufio"
	"strings"
	"testing"
)

func TestWebSocketAuthenticationResponse(t *testing.T) {
	const login = "https://zitadel.damacus.io/oauth/v2/authorize"
	tests := []struct {
		name, response, redirect string
		want                     bool
	}{
		{"login redirect", "HTTP/1.1 302 Found\r\nLocation: " + login + "?client_id=dashboard\r\n\r\n", login, true},
		{"untrusted redirect", "HTTP/1.1 302 Found\r\nLocation: https://example.org/login\r\n\r\n", login, false},
		{"missing location", "HTTP/1.1 302 Found\r\n\r\n", login, false},
		{"wrong login path", "HTTP/1.1 302 Found\r\nLocation: https://zitadel.damacus.io/unrelated\r\n\r\n", login, false},
		{"insecure redirect", "HTTP/1.1 302 Found\r\nLocation: http://zitadel.damacus.io/oauth/v2/authorize\r\n\r\n", login, false},
		{"public dashboard", "HTTP/1.1 200 OK\r\n\r\n", login, false},
		{"backend failure", "HTTP/1.1 503 Unavailable\r\n\r\n", login, false},
		{"authentication bypass", "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n", login, false},
		{"ordinary websocket still requires upgrade", "HTTP/1.1 302 Found\r\nLocation: " + login + "\r\n\r\n", "", false},
		{"ordinary websocket upgrades", "HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n", "", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			ok, detail := readWebSocketResponse(bufio.NewReader(strings.NewReader(test.response)), "dGhlIHNhbXBsZSBub25jZQ==", webSocketCheck{name: "fixture", expectedAuthRedirect: test.redirect})
			if ok != test.want {
				t.Fatalf("got %v, want %v: %s", ok, test.want, detail)
			}
			if ok && test.redirect != "" && !strings.Contains(detail, "authenticated handshake not checked") {
				t.Fatalf("misleading result: %s", detail)
			}
		})
	}

	t.Run("payload assertion is not silently skipped", func(t *testing.T) {
		response := "HTTP/1.1 302 Found\r\nLocation: " + login + "\r\n\r\n"
		ok, detail := readWebSocketResponse(bufio.NewReader(strings.NewReader(response)), "unused", webSocketCheck{name: "fixture", expectedAuthRedirect: login, expectSubstring: "payload"})
		if ok || !strings.Contains(detail, "requires a session") {
			t.Fatalf("got %v: %s", ok, detail)
		}
	})
}
