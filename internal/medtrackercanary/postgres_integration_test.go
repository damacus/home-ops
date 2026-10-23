package medtrackercanary

import (
	"context"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestPostgresLifecycle(t *testing.T) {
	address := os.Getenv("CANARY_DISPOSABLE_TEST_DATABASE_URL")
	if address == "" {
		t.Skip("requires an explicitly provided disposable local PostgreSQL 18")
	}
	u, err := url.Parse(address)
	if err != nil || u.Hostname() != "127.0.0.1" || u.Path != "/postgres" {
		t.Fatal("integration tests only accept a disposable loopback PostgreSQL server")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	_, err = conn.Exec(ctx, `CREATE TABLE canary_control(scope text PRIMARY KEY,run_id text NOT NULL DEFAULT '',phase text NOT NULL DEFAULT 'empty',week text NOT NULL DEFAULT '',image text NOT NULL DEFAULT '',next_reset timestamptz,last_success timestamptz,updated_at timestamptz); INSERT INTO canary_control(scope) VALUES ('medtracker-canary')`)
	if err != nil {
		t.Fatal("expected a fresh test server", err)
	}
	p := &Postgres{conn: conn, config: config(), pid: conn.PgConn().PID()}
	locked, err := p.Lock(ctx)
	if err != nil || !locked {
		t.Fatal("lock", err)
	}
	other, err := pgx.Connect(ctx, address)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close(context.Background())
	contender := &Postgres{conn: other, pid: other.PgConn().PID()}
	locked, err = contender.Lock(ctx)
	if err != nil || locked {
		t.Fatal("second session acquired reset lock", err)
	}
	if err := p.Begin(ctx, "integration", "week", time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := p.Fence(ctx); err != nil {
		t.Fatal(err)
	}
	if err := p.Fresh(ctx); err != nil {
		t.Fatal(err)
	}
	if err := p.Open(ctx); err == nil {
		t.Fatal("runtime opened without completed application seed")
	}
	appConfig := conn.Config().Copy()
	appConfig.Database = Database
	admin, err := pgx.ConnectConfig(ctx, appConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close(context.Background())
	_, err = admin.Exec(ctx, `CREATE ROLE med_tracker_app NOLOGIN; CREATE TABLE canary_seed(scope text,image text,complete boolean); CREATE TABLE runtime_read(id int); INSERT INTO runtime_read VALUES (1); GRANT USAGE ON SCHEMA public TO med_tracker_app; GRANT SELECT ON runtime_read TO med_tracker_app`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := admin.Exec(ctx, `INSERT INTO canary_seed VALUES ($1,$2,true)`, Namespace, config().Image); err != nil {
		t.Fatal(err)
	}
	if err := p.Open(ctx); err != nil {
		t.Fatal(err)
	}
	runtimeConfig := appConfig.Copy()
	runtimeConfig.User = RuntimeRole
	runtimeConfig.Password = config().RuntimePassword
	runtime, err := pgx.ConnectConfig(ctx, runtimeConfig)
	if err != nil {
		t.Fatal("restricted login", err)
	}
	defer runtime.Close(context.Background())
	var visible int
	if err := runtime.QueryRow(ctx, "SELECT count(*) FROM runtime_read").Scan(&visible); err != nil || visible != 1 {
		t.Fatal("runtime did not inherit application table grants", err)
	}
	if err := p.Fence(ctx); err != nil {
		t.Fatal(err)
	}
	if err := runtime.Ping(ctx); err == nil {
		t.Fatal("existing runtime session survived fence")
	}
	if _, err := pgx.ConnectConfig(ctx, runtimeConfig); err == nil {
		t.Fatal("NOLOGIN runtime reconnected")
	}
	var rows int
	if err := conn.QueryRow(ctx, `SELECT count(*) FROM canary_control`).Scan(&rows); err != nil || rows != 1 {
		t.Fatal("control data lost", err)
	}
}
