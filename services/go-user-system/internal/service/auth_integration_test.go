package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"go-user-system/internal/auth"
	"go-user-system/internal/model"
	"go-user-system/internal/request"
	"go-user-system/internal/testutil"

	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
)

func prepareAuthIntegrationDB(t *testing.T) *gorm.DB {
	t.Helper()

	db := testutil.OpenTestDB(t)
	sqlDB, err := db.DB()
	if err != nil {
		t.Fatalf("get sql db failed: %v", err)
	}
	sqlDB.SetMaxOpenConns(5)
	sqlDB.SetMaxIdleConns(5)
	testutil.ResetTables(t, db, "refresh_tokens", "users")
	testutil.CreateUsersTable(t, db)
	testutil.CreateRefreshTokensTable(t, db)

	t.Cleanup(func() {
		testutil.ResetTables(t, db, "refresh_tokens", "users")
		testutil.CloseTestDB(t, db)
	})
	return db
}

// testTokenHash 造一个 64 位十六进制串，对齐 schema 的 char(64)。
//
// 为什么不能随手写 "old-hash"：**生产里的 token_hash 本来就是 SHA-256 十六进制**
// （`internal/auth/token_manager.go:252` 产出的就是 64 位 hex）。测试里写短字符串，
// 等于用**与生产不符的数据形状**去验一条鉴权路径 —— 它可能在某个库上碰巧过，
// 在另一个库上不过，而失败原因与真实缺陷无关。本测试只是把这个前提**显式化**，
// 不是把判据改松。
//
// ⚠️ 更正一条曾经写在这里的错误说法：**PG 的 `char(n)` 读出时<u>不会</u>补齐**。
// 实测（PG 17.11）：`char(64)` 写入 `'old-hash'`（8 字符），`length()` 返回 **8**，
// 输出也不带尾随空格 —— 补齐到 n 位是 **MySQL 的 `CHAR`** 的行为，不是 PG 的。
// （PG 的 `bpchar` 只在**比较**时忽略尾随空格。）⇒ 改用真实 hash 的理由是
// **数据形状与生产一致**，不是"绕开补齐"。
func testTokenHash(seed string) string {
	sum := sha256.Sum256([]byte(seed))
	return hex.EncodeToString(sum[:])
}

func createAuthIntegrationUser(t *testing.T, db *gorm.DB, password string) *model.User {
	t.Helper()

	passwordHash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		t.Fatalf("hash password failed: %v", err)
	}
	user := &model.User{
		Username:     testutil.UniqueName(t, "auth_user"),
		PasswordHash: string(passwordHash),
		Nickname:     "auth-user",
		Status:       model.UserStatusActive,
		AuthVersion:  1,
	}
	if err := db.Create(user).Error; err != nil {
		t.Fatalf("create user failed: %v", err)
	}
	return user
}

func TestAuthServiceIntegrationConcurrentRefreshAllowsOneSuccessAndRevokesFamilyOnReplay(t *testing.T) {
	db := prepareAuthIntegrationDB(t)
	user := createAuthIntegrationUser(t, db, "password1234")
	now := time.Now().UTC()
	// token_hash 在 schema 里是 char(64)（migrations/00003_create_refresh_tokens.sql:8）。
	// **必须用 64 位十六进制**——理由：生产里的 token_hash 就是 SHA-256 hex
	// （`internal/auth/token_manager.go:252`），写短字符串等于用与生产不符的数据形状
	// 去验一条鉴权路径。单位测全用 fake repo，观测不到这一点。
	//
	// ⚠️ 这里原写「PG 的 char(n) 读出时会补齐到 n 位」——**那条实测是错的**
	// （PG 17.11：`length()` 返回 8，不补）；补齐是 MySQL `CHAR` 的行为。详见 testTokenHash 的注释。
	current := &model.RefreshToken{
		UserID:    user.ID,
		JTI:       "old-jti",
		FamilyID:  "family-1",
		TokenHash: testTokenHash("old"),
		ExpiresAt: now.Add(time.Hour),
	}
	if err := db.Create(current).Error; err != nil {
		t.Fatalf("create refresh token failed: %v", err)
	}

	authService := NewAuthService(db)
	start := make(chan struct{})
	results := make(chan error, 2)
	var wg sync.WaitGroup
	for index := 1; index <= 2; index++ {
		index := index
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			results <- authService.RotateRefreshToken(
				context.Background(),
				user.ID,
				1,
				current.JTI,
				current.TokenHash,
				&model.RefreshToken{
					JTI:       fmt.Sprintf("next-jti-%d", index),
					TokenHash: testTokenHash(fmt.Sprintf("next-%d", index)),
					ExpiresAt: now.Add(2 * time.Hour),
				},
			)
		}()
	}
	close(start)
	wg.Wait()
	close(results)

	successes := 0
	replays := 0
	for err := range results {
		switch {
		case err == nil:
			successes++
		case errors.Is(err, ErrRefreshTokenReplay):
			replays++
		default:
			t.Fatalf("unexpected refresh result: %v", err)
		}
	}
	if successes != 1 || replays != 1 {
		t.Fatalf("expected one success and one replay, successes=%d replays=%d", successes, replays)
	}

	var activeFamilyTokens int64
	if err := db.Model(&model.RefreshToken{}).
		Where("family_id = ? AND revoked_at IS NULL", current.FamilyID).
		Count(&activeFamilyTokens).Error; err != nil {
		t.Fatalf("count active family tokens failed: %v", err)
	}
	if activeFamilyTokens != 0 {
		t.Fatalf("expected replay to revoke all family tokens, got %d active", activeFamilyTokens)
	}
}

func TestUserServiceIntegrationPasswordChangeInvalidatesOldAuthVersionAndRefreshTokens(t *testing.T) {
	db := prepareAuthIntegrationDB(t)
	user := createAuthIntegrationUser(t, db, "old-password")
	refreshToken := &model.RefreshToken{
		UserID:    user.ID,
		JTI:       "refresh-jti",
		FamilyID:  "refresh-family",
		TokenHash: testTokenHash("refresh"),
		ExpiresAt: time.Now().Add(time.Hour),
	}
	if err := db.Create(refreshToken).Error; err != nil {
		t.Fatalf("create refresh token failed: %v", err)
	}

	manager, err := auth.NewTokenManagerWithTTL(
		"integration_test_jwt_secret_32_chars",
		"integration-test",
		time.Minute,
		time.Hour,
	)
	if err != nil {
		t.Fatalf("new token manager failed: %v", err)
	}
	oldAccessToken, err := manager.GenerateAccessToken(user.ID, user.Username, user.AuthVersion)
	if err != nil {
		t.Fatalf("generate access token failed: %v", err)
	}
	oldClaims, err := manager.ParseAccessToken(oldAccessToken)
	if err != nil {
		t.Fatalf("parse access token failed: %v", err)
	}

	userService := NewUserService(db)
	if err := userService.UpdateUserPassword(context.Background(), user.ID, request.UpdatePasswordRequest{
		OldPassword: "old-password",
		NewPassword: "new-password",
	}); err != nil {
		t.Fatalf("update password failed: %v", err)
	}

	var updatedUser model.User
	if err := db.First(&updatedUser, user.ID).Error; err != nil {
		t.Fatalf("read updated user failed: %v", err)
	}
	if updatedUser.AuthVersion != user.AuthVersion+1 {
		t.Fatalf("expected auth version %d, got %d", user.AuthVersion+1, updatedUser.AuthVersion)
	}
	var updatedRefresh model.RefreshToken
	if err := db.First(&updatedRefresh, refreshToken.ID).Error; err != nil {
		t.Fatalf("read updated refresh token failed: %v", err)
	}
	if updatedRefresh.RevokedAt == nil || updatedRefresh.RevokedReason == nil || *updatedRefresh.RevokedReason != model.RefreshTokenRevokedReasonPasswordChange {
		t.Fatalf("expected refresh token revoked for password change, got %+v", updatedRefresh)
	}

	authService := NewAuthService(db)
	if err := authService.ValidateAccessToken(context.Background(), oldClaims); !errors.Is(err, ErrAccessSessionInvalid) {
		t.Fatalf("expected pre-change access token rejected, got %v", err)
	}
}
