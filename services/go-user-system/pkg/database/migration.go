package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

const migrationPingTimeout = 10 * time.Second

type MigrationConfig struct {
	Host     string
	Port     string
	User     string
	Password string
	Database string
}

func MigrationConfigFromEnv(getenv func(string) string) (MigrationConfig, error) {
	if getenv == nil {
		getenv = os.Getenv
	}
	cfg := MigrationConfig{
		Host:     strings.TrimSpace(getenv("DB_HOST")),
		Port:     strings.TrimSpace(getenv("DB_PORT")),
		User:     strings.TrimSpace(getenv("DB_USER")),
		Password: getenv("DB_PASSWORD"),
		Database: strings.TrimSpace(getenv("DB_NAME")),
	}
	var missing []string
	for _, field := range []struct {
		name  string
		value string
	}{
		{name: "DB_HOST", value: cfg.Host},
		{name: "DB_PORT", value: cfg.Port},
		{name: "DB_USER", value: cfg.User},
		{name: "DB_PASSWORD", value: cfg.Password},
		{name: "DB_NAME", value: cfg.Database},
	} {
		if field.value == "" {
			missing = append(missing, field.name)
		}
	}
	if len(missing) > 0 {
		return MigrationConfig{}, fmt.Errorf("migration database config missing: %s", strings.Join(missing, ", "))
	}
	return cfg, nil
}

func OpenMigrationDBFromEnv(ctx context.Context) (*sql.DB, error) {
	cfg, err := MigrationConfigFromEnv(os.Getenv)
	if err != nil {
		return nil, err
	}
	return OpenMigrationDB(ctx, cfg)
}

func OpenMigrationDB(ctx context.Context, cfg MigrationConfig) (*sql.DB, error) {
	if ctx == nil {
		return nil, errors.New("migration database context is required")
	}
	// ADR-0019 §2「两个驱动路径都要改」：迁移路径**不经 GORM**，
	// 它用 database/sql 直连。MySQL 的 `MultiStatements` 在 PG 里没有对应开关
	// （PG 的 pgx 驱动本身支持多语句），故整段改写成 PG 的 URL DSN。
	// 时区同样显式钉 UTC —— 理由见 db.go 的同名注释。
	dsn := fmt.Sprintf("postgres://%s:%s@%s/%s?sslmode=disable&timezone=UTC",
		cfg.User,
		url.QueryEscape(cfg.Password),
		net.JoinHostPort(cfg.Host, cfg.Port),
		cfg.Database,
	)

	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("open migration database: %w", err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, migrationPingTimeout)
	defer cancel()
	if err := db.PingContext(pingCtx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping migration database: %w", err)
	}
	return db, nil
}
