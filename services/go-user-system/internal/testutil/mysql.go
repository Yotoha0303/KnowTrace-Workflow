package testutil

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
	"unicode"

	"gorm.io/driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

const TestDatabaseDSNEnv = "TEST_DATABASE_DSN"
const mysqlIntegrationLockName = "go_user_system_integration_tests"

// RealDBFingerprintPrefix 是「本测试二进制确实连上过真实 MySQL」的日志标记前缀。
//
// CI 的断言步（scripts/check-go-integration-gate.mjs）grep 它，用来堵住
// 「集成测被换成 fake driver，却照样 PASS」这条假绿路径——fake driver
// （mysql_test.go 的 testutilSQLDriver）不经过这里，也就产不出这一行。
//
// 标记必须由**数据库自己答出来的值**构成，不能是常量：`database` 来自
// `SELECT DATABASE()`、`version` 来自 `SELECT VERSION()`。
const RealDBFingerprintPrefix = "REAL_DB_FINGERPRINT "

// mysqlVersionPattern 要求 version 形如 8.0.36。fake driver 对未识别查询兜底返回 0，
// 若不做这个校验，一个假连接就会打印 `version=0` —— 标记就失去意义。
var mysqlVersionPattern = regexp.MustCompile(`^\d+\.\d+\.\d+`)

const createUsersTableSQL = `CREATE TABLE users (
	id BIGINT NOT NULL AUTO_INCREMENT,
	username VARCHAR(64) NOT NULL,
	password_hash VARCHAR(255) NOT NULL,
	nickname VARCHAR(64) NOT NULL DEFAULT '',
	status TINYINT NOT NULL DEFAULT 1,
	auth_version BIGINT NOT NULL DEFAULT 1,
	created_at DATETIME(3) NULL DEFAULT NULL,
	updated_at DATETIME(3) NULL DEFAULT NULL,
	last_login_at DATETIME(3) NULL DEFAULT NULL,
	deleted_at DATETIME(3) NULL DEFAULT NULL,
	PRIMARY KEY (id),
	UNIQUE KEY idx_username (username),
	KEY idx_users_deleted_at (deleted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`

//nolint:gosec // Schema column names are not credentials.
const createRefreshTokensTableSQL = `CREATE TABLE refresh_tokens (
	id BIGINT NOT NULL AUTO_INCREMENT,
	user_id BIGINT NOT NULL,
	jti VARCHAR(64) NOT NULL,
	family_id VARCHAR(64) NOT NULL,
	token_hash CHAR(64) NOT NULL,
	expires_at DATETIME(3) NOT NULL,
	revoked_at DATETIME(3) NULL DEFAULT NULL,
	revoked_reason VARCHAR(32) NULL DEFAULT NULL,
	replaced_by_jti VARCHAR(64) NULL DEFAULT NULL,
	created_at DATETIME(3) NULL DEFAULT NULL,
	updated_at DATETIME(3) NULL DEFAULT NULL,
	PRIMARY KEY (id),
	UNIQUE KEY uk_refresh_tokens_jti (jti),
	UNIQUE KEY uk_refresh_tokens_hash (token_hash),
	KEY idx_refresh_tokens_user_id (user_id),
	KEY idx_refresh_tokens_family_id (family_id),
	KEY idx_refresh_tokens_expires_at (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`

const createRolesTableSQL = `CREATE TABLE roles (
	id BIGINT NOT NULL AUTO_INCREMENT,
	code VARCHAR(64) NOT NULL,
	name VARCHAR(64) NOT NULL,
	created_at DATETIME(3) NULL DEFAULT NULL,
	updated_at DATETIME(3) NULL DEFAULT NULL,
	PRIMARY KEY (id),
	UNIQUE KEY uk_roles_code (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`

const createUserRolesTableSQL = `CREATE TABLE user_roles (
	user_id BIGINT NOT NULL,
	role_id BIGINT NOT NULL,
	created_at DATETIME(3) NULL DEFAULT NULL,
	PRIMARY KEY (user_id, role_id),
	KEY idx_user_roles_role_id (role_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci`

const seedRolesSQL = `INSERT INTO roles (code, name, created_at, updated_at)
VALUES
	('admin', 'admin', NOW(3), NOW(3)),
	('user', 'user', NOW(3), NOW(3))`

var openMySQLDB = func(dsn string) (*gorm.DB, error) {
	return gorm.Open(mysql.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
}

func OpenMySQL(t testing.TB) *gorm.DB {
	t.Helper()

	dsn := strings.TrimSpace(os.Getenv(TestDatabaseDSNEnv))
	if dsn == "" {
		t.Skipf("set %s to run MySQL integration tests", TestDatabaseDSNEnv)
	}

	db, err := openMySQLDB(dsn)
	if err != nil {
		t.Fatalf("open test mysql failed: %v", err)
	}

	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get sql db failed: %v", err)
	}
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)

	assertTestDatabase(t, db)
	acquireIntegrationLock(t, db)

	// 必须在返回前打印：调用方拿到的 db 已经过 assertTestDatabase 的「库名含 test」检查
	// 与 GET_LOCK，此时若能答出 DATABASE()/VERSION()，就是一条真实连接。
	emitRealDBFingerprint(t, db)

	return db
}

// emitRealDBFingerprint 打印一行可被 CI 断言步 grep 的标记，证明 db 背后是真实 MySQL。
//
// 为什么放在 OpenMySQL 里、而不是某个 TestMain：
//   - 全仓 import testutil 的包只有 dao / service（`grep internal/testutil` 实测），
//     它们**只**通过 OpenMySQL 拿库；放在这里覆盖 100% 的真实集成用例路径。
//   - 它不是「每条用例各写一遍」的调用：签名是 func(testing.TB, *gorm.DB)，但只在
//     OpenMySQL 内被调一次，调用方没有出错的余地。
//   - 与 assertTestDatabase / acquireIntegrationLock 同层：DRY 修法自会经过它。
//   - 它**自带**由数据库回答的两问（DATABASE() / VERSION()），不依赖上游的 assertTestDatabase
//     的查询顺序；单独 dump 这一行就拼得出完整指纹。
//
// 失败时**只用 t.Log，绝不 t.Fatalf**：mysql_test.go 里有多条用例把 openMySQLDB 指向
// fake driver 并照常调用 OpenMySQL（如 TestOpenMySQLInitializesTestDatabase、
// TestOpenMySQLDoesNotSkipWhenDSNIsSet）。若这里 Fatal，那些单元测会红，而它们的 red
// 与「指纹没打出来」混在一起，反而让门更难诊断。
// **假连接不会因此蒙混过关**：buildRealDBFingerprint 拿不到合法值就返回空串，
// 标记不会出现，断言步照样红。
func emitRealDBFingerprint(t testing.TB, db *gorm.DB) {
	t.Helper()

	marker, err := buildRealDBFingerprint(db)
	if err != nil {
		t.Logf("could not build the real-db fingerprint: %v", err)
		return
	}
	if marker == "" {
		t.Log("not emitting a real-db fingerprint: the connection does not answer like a real MySQL")
		return
	}

	// 走 testing 的日志而非 os.Stdout：`go test -json` 会把它包成一条 Output 事件，
	// CI 用同一个 `go test -json | tee` 就同时拿到 PASS 计数与指纹。
	t.Log(marker)
}

// buildRealDBFingerprint 向数据库要 DATABASE() 与 VERSION()，拼成可 grep 的标记。
// 返回空串表示「这条连接答不出真实 MySQL 的答案」，调用方不得打印标记。
func buildRealDBFingerprint(db *gorm.DB) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var databaseName string
	if err := db.WithContext(ctx).Raw("SELECT DATABASE()").Scan(&databaseName).Error; err != nil {
		return "", fmt.Errorf("read DATABASE(): %w", err)
	}

	var serverVersion string
	if err := db.WithContext(ctx).Raw("SELECT VERSION()").Scan(&serverVersion).Error; err != nil {
		return "", fmt.Errorf("read VERSION(): %w", err)
	}

	if !isRealDBFingerprint(databaseName, serverVersion) {
		return "", nil
	}

	return RealDBFingerprintPrefix + "database=" + databaseName + " version=" + serverVersion, nil
}

// isRealDBFingerprint 是标记的准入判据：库名非空 + 版本号形如 x.y.z。
//
// 版本形状这一条是有牙的：mysql_test.go 的 fake driver 对未识别查询兜底返回 int64(0)，
// 于是 fake 连接上的 VERSION() 就是字符串 "0"——不含小数点，被这里挡掉。
func isRealDBFingerprint(databaseName, serverVersion string) bool {
	if strings.TrimSpace(databaseName) == "" {
		return false
	}
	return mysqlVersionPattern.MatchString(serverVersion)
}

func CloseMySQL(t testing.TB, db *gorm.DB) {
	t.Helper()

	if db == nil {
		return
	}

	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get sql db failed: %v", err)
	}
	if err := sqlDB.Close(); err != nil {
		t.Fatalf("close sql db failed: %v", err)
	}
}

func ResetTables(t testing.TB, db *gorm.DB, tableNames ...string) {
	t.Helper()

	if len(tableNames) == 0 {
		return
	}

	if err := db.Exec("SET FOREIGN_KEY_CHECKS = 0").Error; err != nil {
		t.Fatalf("disable foreign key checks failed: %v", err)
	}
	defer func() {
		if err := db.Exec("SET FOREIGN_KEY_CHECKS = 1").Error; err != nil {
			t.Fatalf("enable foreign key checks failed: %v", err)
		}
	}()

	for _, tableName := range tableNames {
		if err := db.Exec(fmt.Sprintf("DROP TABLE IF EXISTS %s", quoteIdentifier(t, tableName))).Error; err != nil {
			t.Fatalf("drop table %s failed: %v", tableName, err)
		}
	}
}

func CreateUsersTable(t testing.TB, db *gorm.DB) {
	t.Helper()

	if err := db.Exec(createUsersTableSQL).Error; err != nil {
		t.Fatalf("create users table failed: %v", err)
	}
}

func CreateRefreshTokensTable(t testing.TB, db *gorm.DB) {
	t.Helper()

	if err := db.Exec(createRefreshTokensTableSQL).Error; err != nil {
		t.Fatalf("create refresh tokens table failed: %v", err)
	}
}

func CreateRoleAssignmentTables(t testing.TB, db *gorm.DB) {
	t.Helper()

	statements := []struct {
		name string
		sql  string
	}{
		{name: "roles", sql: createRolesTableSQL},
		{name: "user_roles", sql: createUserRolesTableSQL},
		{name: "role seeds", sql: seedRolesSQL},
	}
	for _, statement := range statements {
		if err := db.Exec(statement.sql).Error; err != nil {
			t.Fatalf("create %s failed: %v", statement.name, err)
		}
	}
}

func UniqueName(t testing.TB, prefix string) string {
	t.Helper()

	randomBytes := make([]byte, 4)
	if _, err := rand.Read(randomBytes); err != nil {
		t.Fatalf("generate random bytes failed: %v", err)
	}

	return fmt.Sprintf("%s_%s", prefix, hex.EncodeToString(randomBytes))
}

func assertTestDatabase(t testing.TB, db *gorm.DB) {
	t.Helper()

	var databaseName string
	if err := db.Raw("SELECT DATABASE()").Scan(&databaseName).Error; err != nil {
		t.Fatalf("read current database failed: %v", err)
	}

	if !strings.Contains(strings.ToLower(databaseName), "test") {
		t.Fatalf("refusing to run integration tests on non-test database %q", databaseName)
	}
}

func acquireIntegrationLock(t testing.TB, db *gorm.DB) {
	t.Helper()

	var lockResult int
	if err := db.Raw("SELECT GET_LOCK(?, 30)", mysqlIntegrationLockName).Scan(&lockResult).Error; err != nil {
		t.Fatalf("acquire mysql integration lock failed: %v", err)
	}
	if lockResult != 1 {
		t.Fatalf("acquire mysql integration lock timed out")
	}
}

func quoteIdentifier(t testing.TB, identifier string) string {
	t.Helper()

	if identifier == "" {
		t.Fatal("empty sql identifier")
	}

	for _, character := range identifier {
		if character == '_' || unicode.IsLetter(character) || unicode.IsDigit(character) {
			continue
		}
		t.Fatalf("invalid sql identifier %q", identifier)
	}

	return "`" + identifier + "`"
}
