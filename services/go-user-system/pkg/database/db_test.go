package database

import (
	"errors"
	"go-user-system/config"
	"strings"
	"testing"
	"time"

	"gorm.io/gorm"
)

func validDBConfig() *config.Config {
	return &config.Config{
		Postgres: config.PostgresConfig{
			Host:            "127.0.0.1",
			Port:            "3306",
			User:            "root",
			Database:        "go_user_system",
			MaxOpenConns:    10,
			MaxIdleConns:    5,
			ConnMaxLifetime: 30 * time.Minute,
			ConnMaxIdleTime: 5 * time.Minute,
			PingTimeout:     3 * time.Second,
		},
	}
}

func TestBuildDSNRequiresCompleteConfig(t *testing.T) {
	_, err := buildDSN(&config.Config{}, "secret")

	if err == nil {
		t.Fatal("expected missing database config error")
	}
}

func TestBuildDSNRequiresPassword(t *testing.T) {
	_, err := buildDSN(validDBConfig(), "")

	if err == nil {
		t.Fatal("expected missing password error")
	}
}

func TestBuildDSNBuildsPostgresConnectionString(t *testing.T) {
	dsn, err := buildDSN(validDBConfig(), "secret")

	if err != nil {
		t.Fatalf("build dsn failed: %v", err)
	}
	// ADR-0019 §2：MySQL 的 `charset=utf8mb4&parseTime=True&loc=Local` 全部消失，
	// 换成 PG 的 URL DSN。**`timezone=UTC` 是刻意钉的**（见 db.go 的注释：
	// 服务端默认可能是 Asia/Shanghai，容器里是 UTC，差 8 小时且错了不会响）。
	expectedParts := []string{
		"postgres://root:secret@127.0.0.1:3306/go_user_system",
		"sslmode=disable",
		"timezone=UTC",
	}
	// 反向断言：MySQL 专有的 DSN 参数**不得**再出现
	forbidden := []string{"charset=utf8mb4", "parseTime=", "loc=Local", "tcp("}
	for _, part := range forbidden {
		if strings.Contains(dsn, part) {
			t.Fatalf("mysql-era parameter %q must not appear in the postgres DSN, got %s", part, dsn)
		}
	}
	for _, part := range expectedParts {
		if !strings.Contains(dsn, part) {
			t.Fatalf("expected dsn to contain %s, got %s", part, dsn)
		}
	}
}

func TestInitDBReturnsConfigErrorBeforeOpeningConnection(t *testing.T) {
	t.Setenv("DB_PASSWORD", "")

	_, err := InitDB(validDBConfig())

	if err == nil {
		t.Fatal("expected database config error")
	}
}

func TestInitDBUsesOpenPostgres(t *testing.T) {
	t.Setenv("DB_PASSWORD", "secret")

	oldOpenPostgres := openPostgres
	t.Cleanup(func() {
		openPostgres = oldOpenPostgres
	})

	var gotDSN string
	expectedDB := &gorm.DB{}
	openPostgres = func(cfg *config.Config, dsn string) (*gorm.DB, error) {
		gotDSN = dsn
		return expectedDB, nil
	}

	db, err := InitDB(validDBConfig())

	if err != nil {
		t.Fatalf("init db failed: %v", err)
	}
	if db != expectedDB {
		t.Fatal("expected InitDB to return db from openPostgres")
	}
	if !strings.Contains(gotDSN, "postgres://root:secret@127.0.0.1:3306/go_user_system") {
		t.Fatalf("unexpected dsn: %s", gotDSN)
	}
}

func TestInitDBReturnsOpenError(t *testing.T) {
	t.Setenv("DB_PASSWORD", "secret")

	oldOpenPostgres := openPostgres
	t.Cleanup(func() {
		openPostgres = oldOpenPostgres
	})

	openErr := errors.New("open failed")
	openPostgres = func(cfg *config.Config, dsn string) (*gorm.DB, error) {
		return nil, openErr
	}

	_, err := InitDB(validDBConfig())

	if !errors.Is(err, openErr) {
		t.Fatalf("expected open error, got %v", err)
	}
}

func TestDefaultOpenPostgresReturnsConnectionError(t *testing.T) {
	_, err := openPostgres(&config.Config{}, "postgres://root:secret@127.0.0.1:1/go_user_system?sslmode=disable&connect_timeout=1")

	if err == nil {
		t.Fatal("expected connection error")
	}
}
