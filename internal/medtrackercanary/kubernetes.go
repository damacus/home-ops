package medtrackercanary

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const runtimeSelector = "app.kubernetes.io/part-of=medtracker-canary,canary.medtracker.io/runtime=true"
const jobSelector = "app.kubernetes.io/part-of=medtracker-canary,canary.medtracker.io/setup=true"

type Kubernetes struct {
	Client   *http.Client
	Endpoint string
	Token    string
	Image    string
	Pulse    func(context.Context) error
}

type pod struct {
	Metadata struct{ Name, UID string }
	Spec     struct{ Containers []struct{ Image string } }
}
type job struct {
	Metadata struct{ Name string }
	Status   struct{ Succeeded, Failed, Active int }
}

func InCluster(image string) (*Kubernetes, error) {
	const mount = "/var/run/secrets/kubernetes.io/serviceaccount/"
	token, err := os.ReadFile(mount + "token")
	if err != nil {
		return nil, errors.New("service account token unavailable")
	}
	ca, err := os.ReadFile(mount + "ca.crt")
	if err != nil {
		return nil, errors.New("API CA unavailable")
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		return nil, errors.New("invalid API CA")
	}
	return &Kubernetes{
		Endpoint: "https://kubernetes.default.svc", Token: strings.TrimSpace(string(token)), Image: image,
		Client: &http.Client{Timeout: 15 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}}},
	}, nil
}

func (k *Kubernetes) request(ctx context.Context, method, path string, input, output any) error {
	if k.Pulse != nil {
		if err := k.Pulse(ctx); err != nil {
			return err
		}
	}
	var body io.Reader
	if input != nil {
		encoded, err := json.Marshal(input)
		if err != nil {
			return err
		}
		body = bytes.NewReader(encoded)
	}
	req, err := http.NewRequestWithContext(ctx, method, k.Endpoint+path, body)
	if err != nil {
		return errors.New("invalid API request")
	}
	req.Header.Set("Authorization", "Bearer "+k.Token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := k.Client.Do(req)
	if err != nil {
		return errors.New("Kubernetes API unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("Kubernetes API %s returned %d", method, resp.StatusCode)
	}
	if output == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(output)
}

func (k *Kubernetes) pods(ctx context.Context) ([]pod, error) {
	var result struct{ Items []pod }
	path := "/api/v1/namespaces/" + Namespace + "/pods?labelSelector=" + url.QueryEscape(runtimeSelector)
	err := k.request(ctx, http.MethodGet, path, nil, &result)
	return result.Items, err
}

func (k *Kubernetes) Preflight(ctx context.Context) error {
	pods, err := k.pods(ctx)
	if err != nil {
		return err
	}
	for _, pod := range pods {
		for _, container := range pod.Spec.Containers {
			if container.Image != k.Image {
				return errors.New("runtime image differs from reset image")
			}
		}
	}
	var jobs struct{ Items []job }
	path := "/apis/batch/v1/namespaces/" + Namespace + "/jobs?labelSelector=" + url.QueryEscape(jobSelector)
	if err := k.request(ctx, http.MethodGet, path, nil, &jobs); err != nil {
		return err
	}
	for _, job := range jobs.Items {
		if job.Status.Succeeded == 0 {
			return errors.New("unfinished setup Job requires recovery")
		}
	}
	return nil
}

func (k *Kubernetes) Quiesce(ctx context.Context) error {
	pods, err := k.pods(ctx)
	if err != nil {
		return err
	}
	old := make(map[string]bool)
	for _, pod := range pods {
		old[pod.Metadata.UID] = true
		path := "/api/v1/namespaces/" + Namespace + "/pods/" + url.PathEscape(pod.Metadata.Name)
		options := map[string]any{"apiVersion": "v1", "kind": "DeleteOptions", "preconditions": map[string]string{"uid": pod.Metadata.UID}}
		if err := k.request(ctx, http.MethodDelete, path, options, nil); err != nil {
			return err
		}
	}
	return k.poll(ctx, func() (bool, error) {
		current, err := k.pods(ctx)
		if err != nil {
			return false, err
		}
		for _, pod := range current {
			if old[pod.Metadata.UID] {
				return false, nil
			}
		}
		return true, nil
	})
}

func (k *Kubernetes) Job(ctx context.Context, runID, stage string, args []string) error {
	stamp, err := strconv.ParseInt(strings.TrimPrefix(runID, "reset-"), 10, 64)
	if err != nil {
		return errors.New("invalid reset run identifier")
	}
	if err := k.Preflight(ctx); err != nil {
		return err
	}
	name := runID + "-" + stage
	secret := "medtracker-canary-setup"
	if stage == "preflight" {
		secret = "medtracker-canary-preflight"
	}
	if stage == "smoke" {
		secret = "medtracker-canary-runtime"
	}
	labels := map[string]string{"app.kubernetes.io/part-of": Namespace, "canary.medtracker.io/setup": "true"}
	security := map[string]any{"allowPrivilegeEscalation": false, "readOnlyRootFilesystem": true, "capabilities": map[string]any{"drop": []string{"ALL"}}}
	container := map[string]any{
		"name": stage, "image": k.Image, "args": args, "securityContext": security,
		"env": []any{
			map[string]string{"name": "MEDTRACKER_CANARY_RUN_ID", "value": runID},
			map[string]string{"name": "MEDTRACKER_CANARY_EPOCH", "value": time.Unix(0, stamp).UTC().Format(time.RFC3339Nano)},
		},
		"envFrom":      []any{map[string]any{"configMapRef": map[string]string{"name": "medtracker-canary-settings"}}, map[string]any{"secretRef": map[string]string{"name": "medtracker-canary-runtime"}}, map[string]any{"secretRef": map[string]string{"name": secret}}},
		"resources":    map[string]any{"requests": map[string]string{"cpu": "100m", "memory": "128Mi"}, "limits": map[string]string{"cpu": "1", "memory": "512Mi"}},
		"volumeMounts": []any{map[string]any{"name": "tmp", "mountPath": "/tmp"}, map[string]any{"name": "config", "mountPath": "/app/config/production.yaml", "subPath": "production.yaml", "readOnly": true}, map[string]any{"name": "postgres-ca", "mountPath": "/etc/postgres", "readOnly": true}},
	}
	spec := map[string]any{
		"automountServiceAccountToken": false, "restartPolicy": "Never",
		"securityContext":  map[string]any{"runAsNonRoot": true, "runAsUser": 65532, "runAsGroup": 65532, "fsGroup": 65532, "seccompProfile": map[string]string{"type": "RuntimeDefault"}},
		"containers":       []any{container},
		"volumes":          []any{map[string]any{"name": "tmp", "emptyDir": map[string]any{}}, map[string]any{"name": "config", "configMap": map[string]string{"name": "medtracker-canary-config"}}, map[string]any{"name": "postgres-ca", "secret": map[string]string{"secretName": "medtracker-canary-ca"}}},
		"imagePullSecrets": []any{map[string]string{"name": "ghcr-credentials"}},
	}
	manifest := map[string]any{"apiVersion": "batch/v1", "kind": "Job", "metadata": map[string]any{"name": name, "namespace": Namespace, "labels": labels}, "spec": map[string]any{"backoffLimit": 0, "activeDeadlineSeconds": 300, "ttlSecondsAfterFinished": 604800, "template": map[string]any{"metadata": map[string]any{"labels": labels}, "spec": spec}}}
	path := "/apis/batch/v1/namespaces/" + Namespace + "/jobs"
	if err := k.request(ctx, http.MethodPost, path, manifest, nil); err != nil {
		return err
	}
	return k.poll(ctx, func() (bool, error) {
		var result job
		if err := k.request(ctx, http.MethodGet, path+"/"+name, nil, &result); err != nil {
			return false, err
		}
		if result.Status.Failed > 0 {
			return false, errors.New("application Job failed")
		}
		return result.Status.Succeeded == 1, nil
	})
}

func (k *Kubernetes) poll(ctx context.Context, done func() (bool, error)) error {
	for {
		if k.Pulse != nil {
			if err := k.Pulse(ctx); err != nil {
				return err
			}
		}
		finished, err := done()
		if err != nil {
			return err
		}
		if finished {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}
