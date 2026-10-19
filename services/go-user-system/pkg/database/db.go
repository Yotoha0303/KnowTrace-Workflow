package database

import (
	"context"
	"fmt"
	"go-user-system/config"
	"net"
	"net/url"
	"os"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

var openPostgres = func(cfg *config.Config, dsn string) (*gorm.DB, error) {
	gormDB, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		return nil, fmt.Errorf("connect postgres failed: %w", err)
	}

	sqlDB, err := gormDB.DB()
	if err != nil {
		return nil, fmt.Errorf("get postgres db failed: %w", err)
	}

	sqlDB.SetMaxOpenConns(cfg.Postgres.MaxOpenConns)
	sqlDB.SetMaxIdleConns(cfg.Postgres.MaxIdleConns)
	sqlDB.SetConnMaxIdleTime(cfg.Postgres.ConnMaxIdleTime)
	sqlDB.SetConnMaxLifetime(cfg.Postgres.ConnMaxLifetime)

	ctx, cancel := context.WithTimeout(
		context.Background(),
		cfg.Postgres.PingTimeout,
	)
	defer cancel()

	if err := sqlDB.PingContext(ctx); err != nil {
		_ = sqlDB.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}
	return gormDB, nil
}

func buildDSN(cfg *config.Config, dbPassword string) (string, error) {
	if cfg.Postgres.User == "" || dbPassword == "" || cfg.Postgres.Host == "" || cfg.Postgres.Port == "" || cfg.Postgres.Database == "" {
		return "", fmt.Errorf("database config missing")
	}

	// ADR-0019 §2：`loc=Local` 是 MySQL 的**时区隐式契约**（DATETIME 无时区）。
	// PG 的 timestamptz 是**绝对时刻**，没有"本地"这回事。
	// ⇒ 必须**显式钉住会话时区**，不能依赖服务端默认（本机实测默认为 Asia/Shanghai，
	//    而容器里通常是 UTC —— 两者相差 8 小时，且**错了不会响**）。
	// 选 UTC：与 schema 的 timestamptz(3) 语义一致，且与 K8s/容器生态的默认对齐。
	return fmt.Sprintf("postgres://%s:%s@%s/%s?sslmode=disable&timezone=UTC",
		cfg.Postgres.User,
		url.QueryEscape(dbPassword),
		net.JoinHostPort(cfg.Postgres.Host, cfg.Postgres.Port),
		cfg.Postgres.Database,
	), nil
}

func InitDB(cfg *config.Config) (*gorm.DB, error) {
	dsn, err := buildDSN(cfg, os.Getenv("DB_PASSWORD"))
	if err != nil {
		return nil, err
	}

	if dsn == "" {
		return nil, fmt.Errorf("database dsn not found")
	}
	return openPostgres(cfg, dsn)
}
