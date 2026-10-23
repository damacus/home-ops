package medtrackercanary

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestQuiesceUsesCanaryNamespaceAndUIDPreconditions(t *testing.T) {
	lists := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/v1/namespaces/medtracker-canary/pods") {
			t.Errorf("escaped canary namespace: %s", r.URL.Path)
		}
		switch r.Method {
		case http.MethodGet:
			if !strings.Contains(r.URL.Query().Get("labelSelector"), "runtime=true") {
				t.Error("missing runtime selector")
			}
			lists++
			if lists == 1 {
				fmt.Fprint(w, `{"items":[{"metadata":{"name":"server-old","uid":"old-uid"}}]}`)
				return
			}
			fmt.Fprint(w, `{"items":[{"metadata":{"name":"server-new","uid":"new-uid"}}]}`)
		case http.MethodDelete:
			var body strings.Builder
			buf := make([]byte, 4096)
			n, _ := r.Body.Read(buf)
			body.Write(buf[:n])
			if !strings.Contains(body.String(), `"uid":"old-uid"`) {
				t.Error("missing deletion UID fence")
			}
			fmt.Fprint(w, `{}`)
		default:
			t.Errorf("unexpected mutation %s", r.Method)
		}
	}))
	defer server.Close()
	k := &Kubernetes{Client: server.Client(), Endpoint: server.URL}
	if err := k.Quiesce(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestPreflightRejectsOldImageAndOrphanJobs(t *testing.T) {
	for _, body := range []string{
		`{"items":[{"spec":{"containers":[{"image":"old"}]}}]}`,
		`{"items":[]}`,
	} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if strings.Contains(r.URL.Path, "/jobs") {
				fmt.Fprint(w, `{"items":[{"status":{"active":1}}]}`)
				return
			}
			fmt.Fprint(w, body)
		}))
		k := &Kubernetes{Client: server.Client(), Endpoint: server.URL, Image: config().Image}
		if k.Preflight(context.Background()) == nil {
			t.Fatal("unsafe image/orphan accepted")
		}
		server.Close()
	}
}
