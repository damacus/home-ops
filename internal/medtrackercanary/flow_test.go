package medtrackercanary

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func config() Config {
	return Config{
		ControlURL:      "postgresql://postgres:example@" + databaseHost + ":5432/" + controlDatabase + "?sslmode=verify-full&sslrootcert=/etc/postgres/ca.crt",
		Image:           "ghcr.io/damacus/med-tracker-loco@sha256:" + strings.Repeat("a", 64),
		RuntimePassword: strings.Repeat("x", 32),
		SeedArgs:        []string{"task", "canary-seed", "--environment", "production"},
		SmokeArgs:       []string{"task", "canary-smoke", "--environment", "production"},
	}
}

func TestRejectsOtherDatabaseTargets(t *testing.T) {
	for _, mutation := range []func(*Config){
		func(c *Config) {
			c.ControlURL = strings.ReplaceAll(c.ControlURL, databaseHost, "med-tracker-rw.home.svc.cluster.local")
		},
		func(c *Config) { c.ControlURL = strings.ReplaceAll(c.ControlURL, controlDatabase, "med-tracker") },
		func(c *Config) { c.ControlURL += "&host=production" },
		func(c *Config) { c.Image = "ghcr.io/damacus/med-tracker-loco:latest" },
		func(c *Config) { c.SeedArgs = nil },
	} {
		c := config()
		mutation(&c)
		if c.Validate() == nil {
			t.Fatal("unsafe activation accepted")
		}
	}
}

type fakeStore struct {
	state  State
	held   bool
	events []string
}

func (s *fakeStore) Lock(context.Context) (bool, error)   { return s.held, nil }
func (s *fakeStore) CheckLock(context.Context) error      { return nil }
func (s *fakeStore) State(context.Context) (State, error) { return s.state, nil }
func (s *fakeStore) Begin(_ context.Context, id, week string, _ time.Time) error {
	s.events = append(s.events, "begin")
	s.state = State{RunID: id, Phase: "starting", Week: week}
	return nil
}
func (s *fakeStore) Fence(context.Context) error { s.events = append(s.events, "fence"); return nil }
func (s *fakeStore) Fresh(context.Context) error { s.events = append(s.events, "drop"); return nil }
func (s *fakeStore) Open(context.Context) error  { s.events = append(s.events, "open"); return nil }
func (s *fakeStore) Phase(_ context.Context, _ string, phase string) error {
	s.state.Phase = phase
	return nil
}

type fakeWorkloads struct {
	failStage string
	calls     []string
}

func (w *fakeWorkloads) Preflight(context.Context) error { return nil }
func (w *fakeWorkloads) Quiesce(context.Context) error   { return nil }
func (w *fakeWorkloads) Job(_ context.Context, _ string, stage string, _ []string) error {
	w.calls = append(w.calls, stage)
	if stage == w.failStage {
		return errors.New("injected")
	}
	return nil
}

func TestMissingCapabilityCannotDropDatabase(t *testing.T) {
	db := &fakeStore{held: true, state: State{Phase: "empty"}}
	w := &fakeWorkloads{failStage: "preflight"}
	if Run(context.Background(), config(), db, w, time.Now()) == nil {
		t.Fatal("expected rejection")
	}
	if len(db.events) != 0 {
		t.Fatalf("changed data before capability validation: %v", db.events)
	}
}

func TestFailedSeedFencesAndCannotAutomaticallyRetry(t *testing.T) {
	db := &fakeStore{held: true, state: State{Phase: "empty"}}
	w := &fakeWorkloads{failStage: "seed"}
	if Run(context.Background(), config(), db, w, time.Now()) == nil {
		t.Fatal("expected seed failure")
	}
	if db.state.Phase != "failed" {
		t.Fatal("failure not durable")
	}
	if strings.Join(db.events, ",") != "begin,fence,drop,fence" {
		t.Fatalf("unsafe sequence: %v", db.events)
	}
	before := len(db.events)
	if Run(context.Background(), config(), db, w, time.Now()) == nil {
		t.Fatal("failed run retried")
	}
	if len(db.events) != before {
		t.Fatal("retry changed data")
	}
}

func TestCompletedWeekIsNoOp(t *testing.T) {
	now := time.Date(2026, 10, 25, 6, 0, 0, 0, time.UTC)
	start, _, _ := Week(now)
	db := &fakeStore{held: true, state: State{Phase: "ready", Week: start.Format(time.RFC3339), Image: config().Image}}
	w := &fakeWorkloads{}
	if err := Run(context.Background(), config(), db, w, now); err != nil {
		t.Fatal(err)
	}
	if len(db.events) != 0 || len(w.calls) != 0 {
		t.Fatal("duplicate reset performed work")
	}
	db.state.Image = "previous-image"
	if err := Run(context.Background(), config(), db, w, now); err == nil {
		t.Fatal("different image was reported as already seeded")
	}
	if len(db.events) != 0 || len(w.calls) != 0 {
		t.Fatal("same-week image mismatch changed data")
	}
}

func TestLondonWeekAcrossDST(t *testing.T) {
	for _, utc := range []string{"2026-10-25T03:59:00Z", "2026-10-25T04:00:00Z", "2026-03-29T03:00:00Z"} {
		now, _ := time.Parse(time.RFC3339, utc)
		start, next, err := Week(now)
		if err != nil {
			t.Fatal(err)
		}
		if start.Hour() != 4 || next.Hour() != 4 || start.Weekday() != time.Sunday || start.After(now) || !next.After(now) {
			t.Fatalf("incorrect London reset window %s %s for %s", start, next, utc)
		}
	}
}
