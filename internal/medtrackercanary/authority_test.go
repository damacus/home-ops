package medtrackercanary

import (
	"io"
	"os"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestResetAuthorityCannotReadSecretsOrDeleteDatabaseInfrastructure(t *testing.T) {
	f, err := os.Open("../../kubernetes/apps/medtracker-canary/app/reset.yaml")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	decoder := yaml.NewDecoder(f)
	roles := 0
	for {
		var object struct {
			Kind  string                                `yaml:"kind"`
			Rules []struct{ Resources, Verbs []string } `yaml:"rules"`
		}
		err := decoder.Decode(&object)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if object.Kind == "ClusterRole" || object.Kind == "ClusterRoleBinding" {
			t.Fatal("cross-namespace reset authority")
		}
		if object.Kind != "Role" {
			continue
		}
		roles++
		for _, rule := range object.Rules {
			for _, resource := range rule.Resources {
				if resource != "pods" && resource != "jobs" {
					t.Fatalf("unsafe resource authority %s", resource)
				}
				for _, verb := range rule.Verbs {
					if verb != "get" && verb != "list" && !(resource == "pods" && verb == "delete") && !(resource == "jobs" && verb == "create") {
						t.Fatalf("unsafe %s authority on %s", verb, resource)
					}
				}
			}
		}
	}
	if roles == 0 {
		t.Fatal("no reset role found")
	}
}
