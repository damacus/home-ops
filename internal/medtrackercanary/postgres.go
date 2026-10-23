package medtrackercanary

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

const lockID int64 = 726351930117

type Postgres struct {
	conn   *pgx.Conn
	config Config
	pid    uint32
}

func Connect(ctx context.Context, c Config) (*Postgres, error) {
	if err := c.Validate(); err != nil {
		return nil, err
	}
	config, err := pgx.ParseConfig(c.ControlURL)
	if err != nil {
		return nil, errors.New("invalid control connection")
	}
	config.ConnectTimeout = 10 * time.Second
	conn, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		return nil, errors.New("cannot connect to canary control database")
	}
	return &Postgres{conn: conn, config: c, pid: conn.PgConn().PID()}, nil
}

func (p *Postgres) Close(ctx context.Context) error { return p.conn.Close(ctx) }
func (p *Postgres) Pulse(ctx context.Context) error {
	if err := p.CheckLock(ctx); err != nil {
		return err
	}
	_, err := p.conn.Exec(ctx, "UPDATE canary_control SET updated_at=now() WHERE scope=$1 AND phase NOT IN ('empty','ready','failed')", Namespace)
	return err
}
func (p *Postgres) Lock(ctx context.Context) (bool, error) {
	var held bool
	err := p.conn.QueryRow(ctx, "SELECT pg_try_advisory_lock($1)", lockID).Scan(&held)
	return held, err
}
func (p *Postgres) CheckLock(ctx context.Context) error {
	if p.conn.IsClosed() || p.conn.PgConn().PID() != p.pid {
		return errors.New("reset session lost")
	}
	var held bool
	err := p.conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid=pg_backend_pid() AND locktype='advisory' AND granted AND classid=($1::bigint >> 32)::oid AND objid=($1::bigint & 4294967295)::oid)`, lockID).Scan(&held)
	if err != nil {
		return err
	}
	if !held {
		return errors.New("reset lock lost")
	}
	return nil
}
func (p *Postgres) State(ctx context.Context) (State, error) {
	var s State
	err := p.conn.QueryRow(ctx, "SELECT run_id,phase,week,image FROM canary_control WHERE scope=$1", Namespace).Scan(&s.RunID, &s.Phase, &s.Week, &s.Image)
	return s, err
}
func (p *Postgres) Begin(ctx context.Context, runID, week string, next time.Time) error {
	// An unknown existing application DB is never adopted or reset on first use.
	var exists bool
	if err := p.conn.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=$1)", Database).Scan(&exists); err != nil {
		return err
	}
	s, err := p.State(ctx)
	if err != nil {
		return err
	}
	if s.Phase == "empty" && exists {
		return errors.New("unrecognised application database")
	}
	tag, err := p.conn.Exec(ctx, `UPDATE canary_control SET run_id=$1,week=$2,next_reset=$3,phase='starting',image=$4,updated_at=now() WHERE scope=$5 AND phase IN ('empty','ready')`, runID, week, next, p.config.Image, Namespace)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return errors.New("control state changed")
	}
	return nil
}
func (p *Postgres) Fence(ctx context.Context) error {
	if err := p.CheckLock(ctx); err != nil {
		return err
	}
	var exists bool
	if err := p.conn.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=$1)", RuntimeRole).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		return nil
	}
	if _, err := p.conn.Exec(ctx, "ALTER ROLE "+pgx.Identifier{RuntimeRole}.Sanitize()+" NOLOGIN"); err != nil {
		return err
	}
	if _, err := p.conn.Exec(ctx, "SELECT pg_terminate_backend(pid,5000) FROM pg_stat_activity WHERE usename=$1 AND pid<>pg_backend_pid()", RuntimeRole); err != nil {
		return err
	}
	var remaining int
	if err := p.conn.QueryRow(ctx, "SELECT count(*) FROM pg_stat_activity WHERE usename=$1", RuntimeRole).Scan(&remaining); err != nil {
		return err
	}
	if remaining != 0 {
		return errors.New("runtime sessions remain")
	}
	return nil
}
func (p *Postgres) Fresh(ctx context.Context) error {
	if err := p.CheckLock(ctx); err != nil {
		return err
	}
	// Do not FORCE-drop: orphan setup connections must be investigated, not killed.
	if _, err := p.conn.Exec(ctx, "DROP DATABASE IF EXISTS "+pgx.Identifier{Database}.Sanitize()); err != nil {
		return err
	}
	if _, err := p.conn.Exec(ctx, "CREATE DATABASE "+pgx.Identifier{Database}.Sanitize()+" TEMPLATE template0"); err != nil {
		return err
	}
	var exists bool
	if err := p.conn.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=$1)", RuntimeRole).Scan(&exists); err != nil {
		return err
	}
	if !exists {
		if _, err := p.conn.Exec(ctx, "CREATE ROLE "+pgx.Identifier{RuntimeRole}.Sanitize()+" NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS"); err != nil {
			return err
		}
	}
	// PostgreSQL utility statements cannot bind passwords. Ask PostgreSQL to quote
	// the literal; never construct or log a credential-bearing statement ourselves.
	var statement string
	if err := p.conn.QueryRow(ctx, "SELECT format('ALTER ROLE %I PASSWORD %L', $1::text, $2::text)", RuntimeRole, p.config.RuntimePassword).Scan(&statement); err != nil {
		return err
	}
	if _, err := p.conn.Exec(ctx, statement); err != nil {
		return errors.New("cannot configure runtime credential")
	}
	_, err := p.conn.Exec(ctx, "REVOKE CONNECT ON DATABASE "+pgx.Identifier{Database}.Sanitize()+" FROM PUBLIC")
	return err
}
func (p *Postgres) Open(ctx context.Context) error {
	if err := p.CheckLock(ctx); err != nil {
		return err
	}
	// The seed task must have committed its completion marker before exiting.
	config := p.conn.Config().Copy()
	config.Database = Database
	app, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		return errors.New("cannot check seeded database")
	}
	defer app.Close(context.Background())
	var seeded bool
	if err := app.QueryRow(ctx, "SELECT complete FROM canary_seed WHERE scope=$1 AND image=$2", Namespace, p.config.Image).Scan(&seeded); err != nil || !seeded {
		return errors.New("application seed marker missing")
	}
	if _, err := p.conn.Exec(ctx, "GRANT med_tracker_app TO "+pgx.Identifier{RuntimeRole}.Sanitize()+" WITH INHERIT TRUE"); err != nil {
		return err
	}
	var restricted bool
	if err := p.conn.QueryRow(ctx, `SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles granted ON granted.oid=m.roleid WHERE m.member=r.oid AND granted.rolname<>'med_tracker_app') FROM pg_roles r WHERE rolname=$1`, RuntimeRole).Scan(&restricted); err != nil || !restricted {
		return errors.New("runtime role has unexpected privileges")
	}
	if _, err := p.conn.Exec(ctx, "ALTER ROLE "+pgx.Identifier{RuntimeRole}.Sanitize()+" INHERIT LOGIN"); err != nil {
		return err
	}
	_, err = p.conn.Exec(ctx, "GRANT CONNECT ON DATABASE "+pgx.Identifier{Database}.Sanitize()+" TO "+pgx.Identifier{RuntimeRole}.Sanitize())
	return err
}
func (p *Postgres) Phase(ctx context.Context, runID, phase string) error {
	if err := p.CheckLock(ctx); err != nil {
		return err
	}
	tag, err := p.conn.Exec(ctx, `UPDATE canary_control SET phase=$1,updated_at=now(),last_success=CASE WHEN $1='ready' THEN now() ELSE last_success END WHERE scope=$2 AND run_id=$3`, phase, Namespace, runID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() != 1 {
		return errors.New("reset ownership changed")
	}
	return nil
}
