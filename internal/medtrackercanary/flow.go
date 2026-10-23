package medtrackercanary

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"
)

type State struct{ RunID, Phase, Week, Image string }

type Store interface {
	Lock(context.Context) (bool, error)
	State(context.Context) (State, error)
	Begin(context.Context, string, string, time.Time) error
	Fence(context.Context) error
	Fresh(context.Context) error
	Open(context.Context) error
	Phase(context.Context, string, string) error
	CheckLock(context.Context) error
}

type Workloads interface {
	Preflight(context.Context) error
	Quiesce(context.Context) error
	Ready(context.Context) error
	Job(context.Context, string, string, []string) error
}

// Run never retries destructive phases. An unfinished durable run requires recovery.
func Run(ctx context.Context, c Config, db Store, workloads Workloads, now time.Time) error {
	if err := c.Validate(); err != nil {
		return err
	}
	locked, err := db.Lock(ctx)
	if err != nil {
		return errors.New("cannot acquire reset lock")
	}
	if !locked {
		return errors.New("another reset holds the lock")
	}
	state, err := db.State(ctx)
	if err != nil {
		return errors.New("canary ownership marker is missing")
	}
	if state.Phase != "empty" && state.Phase != "ready" {
		return errors.New("unfinished reset requires explicit recovery")
	}
	start, next, err := Week(now)
	if err != nil {
		return err
	}
	week := start.Format(time.RFC3339)
	if state.Phase == "ready" && state.Week == week {
		if state.Image != c.Image {
			return errors.New("this week was seeded with a different image; an approved reset is required")
		}
		return nil
	}
	if err := workloads.Preflight(ctx); err != nil {
		return fmt.Errorf("preflight: %w", err)
	}
	runID := fmt.Sprintf("reset-%d", now.UnixNano())
	// This application task must validate seed/gate/no-send capabilities without
	// changing data. An older image fails here, before Begin, fencing or DROP.
	if err := workloads.Job(ctx, runID, "preflight", []string{"task", "canary-capabilities", "--environment", "production"}); err != nil {
		return errors.New("image does not pass canary capability preflight")
	}
	if err := db.Begin(ctx, runID, week, next); err != nil {
		return errors.New("cannot record reset start")
	}
	steps := []struct {
		name string
		run  func(context.Context) error
	}{
		{name: "fencing", run: db.Fence},
		{name: "quiescing", run: workloads.Quiesce},
		{name: "creating", run: db.Fresh},
		{name: "migrating", run: func(ctx context.Context) error {
			return workloads.Job(ctx, runID, "migrate", []string{"db", "migrate", "--environment", "production"})
		}},
		{name: "seeding", run: func(ctx context.Context) error { return workloads.Job(ctx, runID, "seed", c.SeedArgs) }},
		{name: "verifying", run: db.Open},
		{name: "verifying", run: workloads.Ready},
		{name: "verifying", run: func(ctx context.Context) error { return workloads.Job(ctx, runID, "smoke", c.SmokeArgs) }},
	}
	for _, step := range steps {
		slog.Info("canary reset phase", "phase", step.name, "run_id", runID)
		if err := db.CheckLock(ctx); err != nil {
			return fail(db, runID, "lock lost")
		}
		if err := db.Phase(ctx, runID, step.name); err != nil {
			return fail(db, runID, "cannot record phase")
		}
		if err := step.run(ctx); err != nil {
			return fail(db, runID, step.name+" failed")
		}
	}
	if err := db.CheckLock(ctx); err != nil {
		return fail(db, runID, "lock lost")
	}
	if err := db.Phase(ctx, runID, "ready"); err != nil {
		return fail(db, runID, "cannot record success")
	}
	return nil
}

func fail(db Store, runID, reason string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	// A lost DB session cannot guarantee cleanup. The durable in-progress marker
	// still prevents a successor from starting another destructive reset.
	fenceErr := db.Fence(ctx)
	stateErr := db.Phase(ctx, runID, "failed")
	if fenceErr != nil || stateErr != nil {
		return fmt.Errorf("%s; recovery required, fence/status not confirmed", reason)
	}
	return fmt.Errorf("%s; canary fenced, recovery required", reason)
}
