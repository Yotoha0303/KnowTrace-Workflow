package testutil

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"testing"

	"gorm.io/driver/mysql"
	"gorm.io/gorm"
)

const testutilSQLDriverName = "go_user_system_testutil_test"

var registerTestutilSQLDriverOnce sync.Once

type testutilSQLDriver struct{}

func (testutilSQLDriver) Open(name string) (driver.Conn, error) {
	return testutilSQLConn{}, nil
}

type testutilSQLConn struct{}

func (testutilSQLConn) Prepare(query string) (driver.Stmt, error) {
	return nil, errors.New("prepare is not supported")
}

func (testutilSQLConn) Close() error {
	return nil
}

func (testutilSQLConn) Begin() (driver.Tx, error) {
	return testutilSQLTx{}, nil
}

func (testutilSQLConn) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	return driver.RowsAffected(1), nil
}

func (testutilSQLConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	upperQuery := strings.ToUpper(query)
	if strings.Contains(upperQuery, "DATABASE()") {
		return &testutilSQLRows{
			columns: []string{"database"},
			values:  []driver.Value{"go_user_test"},
		}, nil
	}
	if strings.Contains(upperQuery, "GET_LOCK") {
		return &testutilSQLRows{
			columns: []string{"lock_result"},
			values:  []driver.Value{int64(1)},
		}, nil
	}
	return &testutilSQLRows{
		columns: []string{"value"},
		values:  []driver.Value{int64(0)},
	}, nil
}

type testutilSQLTx struct{}

func (testutilSQLTx) Commit() error {
	return nil
}

func (testutilSQLTx) Rollback() error {
	return nil
}

type testutilSQLRows struct {
	columns []string
	values  []driver.Value
	read    bool
}

func (r *testutilSQLRows) Columns() []string {
	return r.columns
}

func (r *testutilSQLRows) Close() error {
	return nil
}

func (r *testutilSQLRows) Next(dest []driver.Value) error {
	if r.read {
		return io.EOF
	}
	for i := range dest {
		if i < len(r.values) {
			dest[i] = r.values[i]
			continue
		}
		dest[i] = nil
	}
	r.read = true
	return nil
}

func openTestutilGormDB(t *testing.T) *gorm.DB {
	t.Helper()

	registerTestutilSQLDriverOnce.Do(func() {
		sql.Register(testutilSQLDriverName, testutilSQLDriver{})
	})

	sqlDB, err := sql.Open(testutilSQLDriverName, "testutil")
	if err != nil {
		t.Fatalf("open sql db failed: %v", err)
	}

	db, err := gorm.Open(mysql.New(mysql.Config{
		Conn:                      sqlDB,
		SkipInitializeWithVersion: true,
	}), &gorm.Config{DisableAutomaticPing: true})
	if err != nil {
		t.Fatalf("open gorm db failed: %v", err)
	}
	return db
}

func TestOpenMySQLSkipsWhenDSNIsMissing(t *testing.T) {
	t.Setenv(TestDatabaseDSNEnv, "")

	OpenMySQL(t)
}

func TestOpenMySQLInitializesTestDatabase(t *testing.T) {
	oldOpenMySQLDB := openMySQLDB
	t.Cleanup(func() {
		openMySQLDB = oldOpenMySQLDB
	})

	var gotDSN string
	openMySQLDB = func(dsn string) (*gorm.DB, error) {
		gotDSN = dsn
		return openTestutilGormDB(t), nil
	}

	t.Setenv(TestDatabaseDSNEnv, "fake-test-dsn")

	db := OpenMySQL(t)
	if gotDSN != "fake-test-dsn" {
		t.Fatalf("expected dsn fake-test-dsn, got %s", gotDSN)
	}
	CloseMySQL(t, db)
}

// skipRecorder 记录 OpenMySQL 是否调用了 Skip/Skipf，但**不真的 skip**。
//
// 为什么需要它：真实的 `t.Skip()` 会让调用方用例变成 SKIP，而 SKIP 在 CI 里是绿的
// （`go test` 退出码 0）。也就是说，「DSN 配了却仍然 skip」这件事，
// 只用真实 *testing.T 断言是**观测不到**的——它恰恰会伪装成正常。
// 把它换成 ERROR 级别的失败，才让 CI 的 go job 红。
type skipRecorder struct {
	testing.TB
	reason string
}

func (r *skipRecorder) Skip(args ...interface{}) {
	r.reason = fmt.Sprint(args...)
}

func (r *skipRecorder) Skipf(format string, args ...interface{}) {
	r.reason = fmt.Sprintf(format, args...)
}

func (r *skipRecorder) SkipNow() {
	r.reason = "SkipNow"
}

// TestOpenMySQLDoesNotSkipWhenDSNIsSet 是 CI 集成测门的反向守卫：
// TEST_DATABASE_DSN 已配时，OpenMySQL 必须连接，不得走 skip 分支。
// 若有人把 skip 条件改错（例如改成只看数据库名、或漏掉 TrimSpace 后的空判断），
// 本用例会红——而集成测本身会静默 SKIP、CI 照旧全绿。
func TestOpenMySQLDoesNotSkipWhenDSNIsSet(t *testing.T) {
	oldOpenMySQLDB := openMySQLDB
	t.Cleanup(func() {
		openMySQLDB = oldOpenMySQLDB
	})

	var opened bool
	openMySQLDB = func(string) (*gorm.DB, error) {
		opened = true
		return openTestutilGormDB(t), nil
	}

	t.Setenv(TestDatabaseDSNEnv, "fake-test-dsn")

	recorder := &skipRecorder{TB: t}
	db := OpenMySQL(recorder)
	t.Cleanup(func() {
		CloseMySQL(t, db)
	})

	if recorder.reason != "" {
		t.Fatalf("TEST_DATABASE_DSN 已配置，OpenMySQL 却 skip 了：%s", recorder.reason)
	}
	if !opened {
		t.Fatal("TEST_DATABASE_DSN 已配置，OpenMySQL 却没有尝试连接")
	}
}

func TestDefaultOpenMySQLDBReturnsConnectionError(t *testing.T) {
	_, err := openMySQLDB("root:secret@tcp(127.0.0.1:1)/go_user_test?timeout=1ms")

	if err == nil {
		t.Fatal("expected connection error")
	}
}

func TestCloseMySQLIgnoresNilDatabase(t *testing.T) {
	CloseMySQL(t, nil)
}

func TestCloseMySQLClosesDatabase(t *testing.T) {
	CloseMySQL(t, openTestutilGormDB(t))
}

func TestResetTablesIgnoresEmptyTableList(t *testing.T) {
	ResetTables(t, nil)
}

func TestResetTablesDropsProvidedTables(t *testing.T) {
	db := openTestutilGormDB(t)
	t.Cleanup(func() {
		sqlDB, err := db.DB()
		if err == nil {
			_ = sqlDB.Close()
		}
	})

	ResetTables(t, db, "schema_migrations", "users")
}

func TestCreateAuthTables(t *testing.T) {
	db := openTestutilGormDB(t)
	t.Cleanup(func() {
		sqlDB, err := db.DB()
		if err == nil {
			_ = sqlDB.Close()
		}
	})

	CreateUsersTable(t, db)
	CreateRefreshTokensTable(t, db)
	CreateRoleAssignmentTables(t, db)
}

func TestUniqueNameUsesPrefix(t *testing.T) {
	name := UniqueName(t, "user")

	if !strings.HasPrefix(name, "user_") {
		t.Fatalf("expected prefix user_, got %s", name)
	}
	if len(name) != len("user_")+8 {
		t.Fatalf("expected 8 hex characters, got %s", name)
	}
}

func TestQuoteIdentifierAcceptsSafeIdentifier(t *testing.T) {
	got := quoteIdentifier(t, "schema_migrations_2026")

	if got != "`schema_migrations_2026`" {
		t.Fatalf("expected quoted identifier, got %s", got)
	}
}

func TestAssertTestDatabaseAcceptsDatabaseWithTestInName(t *testing.T) {
	db := openTestutilGormDB(t)
	t.Cleanup(func() {
		sqlDB, err := db.DB()
		if err == nil {
			_ = sqlDB.Close()
		}
	})

	assertTestDatabase(t, db)
}

func TestAcquireIntegrationLockSucceeds(t *testing.T) {
	db := openTestutilGormDB(t)
	t.Cleanup(func() {
		sqlDB, err := db.DB()
		if err == nil {
			_ = sqlDB.Close()
		}
	})

	acquireIntegrationLock(t, db)
}
