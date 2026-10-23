package medtrackercanary

import (
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"time"
	_ "time/tzdata"
)

const Namespace = "medtracker-canary"
const Database = "medtracker_canary"
const RuntimeRole = "medtracker_canary_runtime"
const controlDatabase = "medtracker_canary_control"
const databaseHost = "medtracker-canary-rw.medtracker-canary.svc.cluster.local"

var immutableImage = regexp.MustCompile(`^ghcr\.io/damacus/med-tracker-loco@sha256:[a-f0-9]{64}$`)

type Config struct {
	ControlURL      string
	Image           string
	SeedArgs        []string
	SmokeArgs       []string
	RuntimePassword string
}

// Load rejects incomplete activation settings before any database or API access.
func Load(getenv func(string) string) (Config, error) {
	c := Config{
		ControlURL: getenv("CONTROL_DATABASE_URL"), Image: getenv("LOCO_IMAGE"),
		RuntimePassword: getenv("RUNTIME_PASSWORD"),
	}
	if err := json.Unmarshal([]byte(getenv("SEED_ARGS")), &c.SeedArgs); err != nil {
		return c, errors.New("SEED_ARGS must select the implemented canary seed task")
	}
	if err := json.Unmarshal([]byte(getenv("SMOKE_ARGS")), &c.SmokeArgs); err != nil {
		return c, errors.New("SMOKE_ARGS must select the implemented canary journey task")
	}
	return c, c.Validate()
}

func (c Config) Validate() error {
	u, err := url.Parse(c.ControlURL)
	if err != nil {
		return errors.New("invalid control database address")
	}
	validTarget := u.Scheme == "postgresql" && u.Hostname() == databaseHost &&
		u.Port() == "5432" && u.Path == "/"+controlDatabase
	if !validTarget || u.User == nil || u.User.Username() != "postgres" {
		return errors.New("only the dedicated canary control database is allowed")
	}
	// URL options must not override the validated host, database, user or service.
	if u.RawQuery != "sslmode=verify-full&sslrootcert=/etc/postgres/ca.crt" {
		return errors.New("control connection requires the canary CA and verify-full TLS")
	}
	if !immutableImage.MatchString(c.Image) {
		return errors.New("LOCO_IMAGE must be a verified Loco registry digest")
	}
	if len(c.RuntimePassword) < 24 {
		return errors.New("a separate runtime password of at least 24 characters is required")
	}
	for _, args := range [][]string{c.SeedArgs, c.SmokeArgs} {
		if len(args) < 2 || args[0] != "task" || args[1] == "" {
			return errors.New("seed and smoke must use explicitly configured application tasks")
		}
	}
	return nil
}

// Week identifies the latest Sunday 04:00 in London, including DST transitions.
func Week(now time.Time) (time.Time, time.Time, error) {
	zone, err := time.LoadLocation("Europe/London")
	if err != nil {
		return time.Time{}, time.Time{}, err
	}
	local := now.In(zone)
	day := local.AddDate(0, 0, -int(local.Weekday()))
	start := time.Date(day.Year(), day.Month(), day.Day(), 4, 0, 0, 0, zone)
	if start.After(local) {
		start = start.AddDate(0, 0, -7)
	}
	return start, start.AddDate(0, 0, 7), nil
}
