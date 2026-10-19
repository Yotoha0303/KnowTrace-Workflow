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

	"gorm.io/driver/postgres"
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

// QueryContext 按查询文本分派，模拟 postgres.go 真实启动序列里的那几问。
//
// ⚠️ 这里**刻意不实现**一个「永远答得像真 PG」的 fake：兜底分支返回 version="0"，
// 好让 TestBuildRealDBFingerprintRejectsFakeConnection 能证明「fake 连接不产指纹」，
// 而不是让 fake 恰好把指纹蒙出来。分派用的是 PG 的语句（current_database /
// server_version / pg_try_advisory_lock），不是 MySQL 的 DATABASE()/VERSION()/GET_LOCK。
func (testutilSQLConn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	lowerQuery := strings.ToLower(query)
	switch {
	case strings.Contains(lowerQuery, "current_database()"):
		return &testutilSQLRows{
			columns: []string{"current_database"},
			values:  []driver.Value{"go_user_system_test"},
		}, nil
	case strings.Contains(lowerQuery, "pg_try_advisory_lock"):
		return &testutilSQLRows{
			columns: []string{"pg_try_advisory_lock"},
			values:  []driver.Value{true},
		}, nil
	default:
		// current_setting('server_version') 落在这里：fake 答 "0"，与真 PG 的 "17.11" 不同形。
		return &testutilSQLRows{
			columns: []string{"value"},
			values:  []driver.Value{"0"},
		}, nil
	}
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

// openTestutilGormDB 用自注册的 fake driver 造一个 *gorm.DB。
//
// 方言必须是 **postgres**，不能用 mysql 方言代替：gorm 的 clause builder 挂了方言，
// 换方言后 fake 用例照样 PASS，但它们的 PASS 就不再说明「PG 方言下这条路径能走通」——
// 那正是 M3 要验的东西。postgres.New 在给了 Conn 时**不做版本探测**、**不连接**。
func openTestutilGormDB(t *testing.T) *gorm.DB {
	t.Helper()

	registerTestutilSQLDriverOnce.Do(func() {
		sql.Register(testutilSQLDriverName, testutilSQLDriver{})
	})

	sqlDB, err := sql.Open(testutilSQLDriverName, "testutil")
	if err != nil {
		t.Fatalf("open sql db failed: %v", err)
	}

	db, err := gorm.Open(postgres.New(postgres.Config{
		Conn: sqlDB,
	}), &gorm.Config{DisableAutomaticPing: true})
	if err != nil {
		t.Fatalf("open gorm db failed: %v", err)
	}
	return db
}

func TestOpenTestDBSkipsWhenDSNIsMissing(t *testing.T) {
	t.Setenv(TestDatabaseDSNEnv, "")

	// 没有 DSN ⇒ OpenTestDB 走 t.Skipf。本用例的 PASS 形态就是 SKIP。
	OpenTestDB(t)
}

func TestOpenTestDBInitializesTestDatabase(t *testing.T) {
	oldOpenTestDB := openPostgresDB
	t.Cleanup(func() {
		openPostgresDB = oldOpenTestDB
	})

	var gotDSN string
	openPostgresDB = func(dsn string) (*gorm.DB, error) {
		gotDSN = dsn
		return openTestutilGormDB(t), nil
	}

	t.Setenv(TestDatabaseDSNEnv, "fake-test-dsn")

	db := OpenTestDB(t)
	if gotDSN != "fake-test-dsn" {
		t.Fatalf("expected dsn fake-test-dsn, got %s", gotDSN)
	}
	CloseTestDB(t, db)
}

// skipRecorder 记录 OpenTestDB 是否调用了 Skip/Skipf，但**不真的 skip**。
//
// 为什么需要它：真实的 `t.Skip()` 会让调用方用例变成 SKIP，而 SKIP 在 CI 里是绿的
// （`go test` 退出码 0）。也就是说，「DSN 配了却仍然 skip」这件事，
// 只用真实 *testing.T 断言是**观测不到**的——它恰恰会伪装成正常。
// 把它换成 ERROR 级别的失败，才让 CI 的 go job 红。
type skipRecorder struct {
	testing.TB
	reason string
}

func (r *skipRecorder) Skip(args ...any) {
	r.reason = fmt.Sprint(args...)
}

func (r *skipRecorder) Skipf(format string, args ...any) {
	r.reason = fmt.Sprintf(format, args...)
}

func (r *skipRecorder) SkipNow() {
	r.reason = "SkipNow"
}

// TestOpenTestDBDoesNotSkipWhenDSNIsSet 是 CI 集成测门的反向守卫：
// TEST_DATABASE_DSN 已配时，OpenTestDB 必须连接，不得走 skip 分支。
// 若有人把 skip 条件改错（例如改成只看数据库名、或漏掉 TrimSpace 后的空判断），
// 本用例会红——而集成测本身会静默 SKIP、CI 照旧全绿。
func TestOpenTestDBDoesNotSkipWhenDSNIsSet(t *testing.T) {
	oldOpenTestDB := openPostgresDB
	t.Cleanup(func() {
		openPostgresDB = oldOpenTestDB
	})

	var opened bool
	openPostgresDB = func(string) (*gorm.DB, error) {
		opened = true
		return openTestutilGormDB(t), nil
	}

	t.Setenv(TestDatabaseDSNEnv, "fake-test-dsn")

	recorder := &skipRecorder{TB: t}
	db := OpenTestDB(recorder)
	t.Cleanup(func() {
		CloseTestDB(t, db)
	})

	if recorder.reason != "" {
		t.Fatalf("TEST_DATABASE_DSN 已配置，OpenTestDB 却 skip 了：%s", recorder.reason)
	}
	if !opened {
		t.Fatal("TEST_DATABASE_DSN 已配置，OpenTestDB 却没有尝试连接")
	}
}

// TestDefaultOpenPostgresDBReturnsConnectionError 断言**默认**的 openPostgresDB
// 对不可达的 PG 返回错误（而不是静默成功）。
//
// DSN 刻意用 PG 的 URL 形态并指向 127.0.0.1:1（拒绝连接），且带 connect_timeout=1：
// MySQL 的 `root:secret@tcp(...)` 形态喂给 postgres 驱动会在**解析**阶段就报错，
// 那样这条用例测到的是「DSN 写错」，不是「连接失败」——判据会变味。
func TestDefaultOpenPostgresDBReturnsConnectionError(t *testing.T) {
	_, err := openPostgresDB("postgres://root:secret@127.0.0.1:1/go_user_test?sslmode=disable&connect_timeout=1")

	if err == nil {
		t.Fatal("expected connection error")
	}
}

func TestCloseTestDBIgnoresNilDatabase(t *testing.T) {
	CloseTestDB(t, nil)
}

func TestCloseTestDBClosesDatabase(t *testing.T) {
	CloseTestDB(t, openTestutilGormDB(t))
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

	// PG 用双引号；反引号是 MySQL 的写法，出现在这里说明 quoteIdentifier 没跟着迁移。
	if got != `"schema_migrations_2026"` {
		t.Fatalf("expected double-quoted identifier, got %s", got)
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

// TestBuildRealDBFingerprintRejectsFakeConnection 是 CI 集成测门的反向守卫（A2）：
// fake driver 明明能 PASS，但**不得**产出 REAL_DB_FINGERPRINT 标记。
// 若有人把准入判据放宽（例如只看「current_database() 非空」、或把版本判据改成
// 「非空即可」），这条会红——而断言步会因此把「8 条真用例全换成 fake」的门判绿。
func TestBuildRealDBFingerprintRejectsFakeConnection(t *testing.T) {
	db := openTestutilGormDB(t)
	t.Cleanup(func() {
		sqlDB, err := db.DB()
		if err == nil {
			_ = sqlDB.Close()
		}
	})

	// fake 能答出 current_database() 与一个"版本"（"0"），所以这里 err 必须为 nil。
	// 若它开始报错，说明 fake 与真实启动序列的语句对不上了——那会让下面的断言失去意义。
	marker, err := buildRealDBFingerprint(db)
	if err != nil {
		t.Fatalf("fake driver should answer current_database()/server_version without error, got %v", err)
	}
	if marker != "" {
		t.Fatalf("fake connection must not produce %q, got %q", RealDBFingerprintPrefix, marker)
	}
}

func TestIsRealDBFingerprint(t *testing.T) {
	cases := []struct {
		name          string
		databaseName  string
		serverVersion string
		want          bool
	}{
		// 正向：真实 PG 的 server_version 是**两段**（本机 17.11 实测）。
		{name: "postgres 17", databaseName: "go_user_system_test", serverVersion: "17.11", want: true},
		{name: "postgres 18", databaseName: "go_user_system_test", serverVersion: "18.0", want: true},
		// 容忍三段（部分构建 / Debian 包可能带修订号）。
		{name: "postgres with patch", databaseName: "go_user_system_test", serverVersion: "17.11.0", want: true},
		{name: "empty database", databaseName: "", serverVersion: "17.11", want: false},
		{name: "blank database", databaseName: "   ", serverVersion: "17.11", want: false},
		// fake driver 的兜底答案是 "0"——单段，必须被拒。这条是 A2 的核心。
		{name: "fake driver answers zero", databaseName: "go_user_system_test", serverVersion: "0", want: false},
		{name: "empty version", databaseName: "go_user_system_test", serverVersion: "", want: false},
		// 发行版后缀不是版本号形态（MySQL 的 "8.4.0-log" 同理不适用）。
		{name: "not a version", databaseName: "go_user_system_test", serverVersion: "PostgreSQL", want: false},
		// 单段是 fake 的签名，只接受两段及以上。
		{name: "one component only", databaseName: "go_user_system_test", serverVersion: "17", want: false},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := isRealDBFingerprint(testCase.databaseName, testCase.serverVersion); got != testCase.want {
				t.Fatalf("isRealDBFingerprint(%q, %q) = %v, want %v", testCase.databaseName, testCase.serverVersion, got, testCase.want)
			}
		})
	}
}
