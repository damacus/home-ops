package provisioning

import "testing"

func TestResolveK3sVersion(t *testing.T) {
	t.Parallel()

	plan := []byte(`
spec:
  version: v1.36.3+k3s1
---
spec:
  version: v1.36.3+k3s1
`)

	version, err := ResolveK3sVersion(plan)
	if err != nil {
		t.Fatalf("ResolveK3sVersion() error = %v", err)
	}
	if version != "v1.36.3+k3s1" {
		t.Fatalf("ResolveK3sVersion() = %q", version)
	}
}

func TestResolveK3sVersionRejectsDisagreement(t *testing.T) {
	t.Parallel()

	_, err := ResolveK3sVersion([]byte("version: v1.36.2+k3s1\nversion: v1.36.3+k3s1\n"))
	if err == nil {
		t.Fatal("ResolveK3sVersion() accepted different Plan versions")
	}
}
