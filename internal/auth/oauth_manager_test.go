package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	gooauth2 "github.com/go-oauth2/oauth2/v4"
)

const (
	frameworkTestIssuer    = "https://agentdock.example"
	frameworkTestResource  = frameworkTestIssuer + "/mcp"
	frameworkTestRedirect  = "https://client.example/callback"
	frameworkTestVerifier  = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	frameworkTestChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
	frameworkTestKey       = "test-refresh-signing-key-32-bytes-long"
)

func TestOAuthFrameworkOwnsAuthorizationCodeAndRefreshLifecycle(t *testing.T) {
	store := NewOAuthStore()
	manager, clientID := newOAuthFrameworkTestManager(t, store)
	ctx := oauthFrameworkTestContext(clientID, frameworkTestResource)

	first := authorizeAndExchangeWithFramework(t, manager, clientID, ctx)
	if first.Access == "" || first.Refresh == "" || first.Code == "" {
		t.Fatalf("initial framework tokens = %#v", first)
	}
	if _, ok := validateLegacyAccessToken(first.Access, frameworkTestIssuer, frameworkTestResource, frameworkTestKey); ok {
		t.Fatal("new access token still used the legacy hand-written JWT format")
	}
	if _, err := manager.LoadAccessToken(ctx, first.Access); err != nil {
		t.Fatalf("framework rejected fresh access token: %v", err)
	}

	second := refreshWithFramework(t, manager, clientID, ctx, first.Refresh)
	if second.Access == first.Access || second.Refresh == first.Refresh {
		t.Fatalf("refresh did not rotate tokens: first=%#v second=%#v", first, second)
	}
	if _, err := manager.LoadAccessToken(ctx, first.Access); err == nil {
		t.Fatal("rotated access token remained active")
	}

	// 重放旧代 Refresh Token 后，TokenStore 会撤销整个 token family。
	if _, err := manager.RefreshAccessToken(ctx, refreshRequest(first.Refresh, clientID, frameworkTestResource)); err == nil {
		t.Fatal("framework accepted a consumed refresh token")
	}
	if _, err := manager.RefreshAccessToken(ctx, refreshRequest(second.Refresh, clientID, frameworkTestResource)); err == nil {
		t.Fatal("current refresh token remained active after family revocation")
	}
	if _, err := manager.LoadAccessToken(ctx, second.Access); err == nil {
		t.Fatal("access token remained active after refresh-token replay")
	}
}

func TestOAuthFrameworkPersistsHashedTokensAcrossReload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oauth", "state-v1.json")
	store, err := NewPersistentOAuthStore(path, frameworkTestKey)
	if err != nil {
		t.Fatal(err)
	}
	manager, clientID := newOAuthFrameworkTestManager(t, store)
	ctx := oauthFrameworkTestContext(clientID, frameworkTestResource)
	first := authorizeAndExchangeWithFramework(t, manager, clientID, ctx)

	state, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(state), first.Access) || strings.Contains(string(state), first.Refresh) {
		t.Fatal("OAuth state persisted a raw access or refresh token")
	}
	var version struct {
		Version int `json:"version"`
	}
	if err := json.Unmarshal(state, &version); err != nil {
		t.Fatal(err)
	}
	if version.Version != oauthStateVersion {
		t.Fatalf("OAuth state version = %d, want %d", version.Version, oauthStateVersion)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("OAuth state mode = %o, want 600", info.Mode().Perm())
	}

	reloaded, err := NewPersistentOAuthStore(path, frameworkTestKey)
	if err != nil {
		t.Fatal(err)
	}
	reloadedManager, _ := newOAuthFrameworkTestManagerForClient(t, reloaded, clientID)
	if _, err := reloadedManager.LoadAccessToken(ctx, first.Access); err != nil {
		t.Fatalf("persisted access token was not restored: %v", err)
	}
	second := refreshWithFramework(t, reloadedManager, clientID, ctx, first.Refresh)

	reloadedAgain, err := NewPersistentOAuthStore(path, frameworkTestKey)
	if err != nil {
		t.Fatal(err)
	}
	thirdManager, _ := newOAuthFrameworkTestManagerForClient(t, reloadedAgain, clientID)
	third := refreshWithFramework(t, thirdManager, clientID, ctx, second.Refresh)
	if third.Refresh == second.Refresh || third.Access == second.Access {
		t.Fatal("reloaded framework did not rotate persisted token state")
	}
}

func TestOAuthFrameworkRejectsClientAndResourceMismatchWithoutConsumption(t *testing.T) {
	store := NewOAuthStore()
	manager, clientID := newOAuthFrameworkTestManager(t, store)
	ctx := oauthFrameworkTestContext(clientID, frameworkTestResource)
	first := authorizeAndExchangeWithFramework(t, manager, clientID, ctx)

	otherClient, err := store.RegisterClient(
		"other",
		[]string{"https://other.example/callback"},
		[]string{gooauth2.AuthorizationCode.String(), gooauth2.Refreshing.String()},
	)
	if err != nil {
		t.Fatal(err)
	}
	wrongClientCtx := oauthFrameworkTestContext(otherClient, frameworkTestResource)
	if _, err := manager.RefreshAccessToken(wrongClientCtx, refreshRequest(first.Refresh, otherClient, frameworkTestResource)); err == nil {
		t.Fatal("refresh token was accepted for another client")
	}
	wrongResourceCtx := oauthFrameworkTestContext(clientID, frameworkTestIssuer+"/other")
	if _, err := manager.RefreshAccessToken(wrongResourceCtx, refreshRequest(first.Refresh, clientID, frameworkTestIssuer+"/other")); err == nil {
		t.Fatal("refresh token was accepted for another resource")
	}

	// 绑定失败不能消耗合法 Refresh Token。
	second := refreshWithFramework(t, manager, clientID, ctx, first.Refresh)
	if second.Refresh == "" {
		t.Fatal("valid refresh failed after rejected binding attempts")
	}
}

func TestOAuthFrameworkAuthorizationCodeReplayRevokesIssuedFamily(t *testing.T) {
	store := NewOAuthStore()
	manager, clientID := newOAuthFrameworkTestManager(t, store)
	ctx := oauthFrameworkTestContext(clientID, frameworkTestResource)
	issued := authorizeAndExchangeWithFramework(t, manager, clientID, ctx)

	if _, err := manager.GenerateAccessToken(ctx, gooauth2.AuthorizationCode, authorizationCodeRequest(
		issued.Code, clientID, frameworkTestResource,
	)); err == nil {
		t.Fatal("authorization code replay was accepted")
	}
	if _, err := manager.LoadAccessToken(ctx, issued.Access); err == nil {
		t.Fatal("authorization code replay did not revoke the issued token family")
	}
	if _, err := manager.RefreshAccessToken(ctx, refreshRequest(issued.Refresh, clientID, frameworkTestResource)); err == nil {
		t.Fatal("authorization code replay did not revoke refresh token")
	}
}

func TestOAuthFrameworkRefreshRotationStateRemainsBounded(t *testing.T) {
	store := NewOAuthStore()
	manager, clientID := newOAuthFrameworkTestManager(t, store)
	ctx := oauthFrameworkTestContext(clientID, frameworkTestResource)
	current := authorizeAndExchangeWithFramework(t, manager, clientID, ctx)

	for index := 0; index < 500; index++ {
		current = refreshWithFramework(t, manager, clientID, ctx, current.Refresh)
	}
	if len(store.grants) != 1 {
		t.Fatalf("grant count = %d, want 1", len(store.grants))
	}
	for _, grant := range store.grants {
		if grant.CurrentGeneration != 501 {
			t.Fatalf("refresh generation = %d, want 501", grant.CurrentGeneration)
		}
	}
}

func TestOAuthFrameworkSupportsNeverExpiringAccessToken(t *testing.T) {
	store := NewOAuthStore()
	clientID, err := store.RegisterClient(
		"never-expiring test",
		[]string{frameworkTestRedirect},
		[]string{gooauth2.AuthorizationCode.String(), gooauth2.Refreshing.String()},
	)
	if err != nil {
		t.Fatal(err)
	}
	manager := NewOAuthManager(store, frameworkTestKey, 0, 90*24*time.Hour)
	ctx := oauthFrameworkTestContext(clientID, frameworkTestResource)
	issued := authorizeAndExchangeWithFramework(t, manager, clientID, ctx)
	info, err := manager.LoadAccessToken(ctx, issued.Access)
	if err != nil {
		t.Fatalf("LoadAccessToken() error = %v", err)
	}
	if info.GetAccessExpiresIn() != 0 {
		t.Fatalf("access token lifetime = %s, want no expiration", info.GetAccessExpiresIn())
	}

	store.mu.Lock()
	for grantID, grant := range store.grants {
		if !grant.AccessNeverExpires || grant.AccessExpiresAt != 0 {
			store.mu.Unlock()
			t.Fatalf("grant = %#v, want permanent access token metadata", grant)
		}
		grant.ExpiresAt = time.Now().Add(-time.Second).Unix()
		store.grants[grantID] = grant
	}
	store.mu.Unlock()

	if _, err := manager.LoadAccessToken(ctx, issued.Access); err != nil {
		t.Fatalf("access token expired with its refresh token: %v", err)
	}
	if _, err := manager.RefreshAccessToken(ctx, refreshRequest(issued.Refresh, clientID, frameworkTestResource)); err == nil {
		t.Fatal("expired refresh token remained active")
	}
}

type oauthFrameworkTokens struct {
	Code    string
	Access  string
	Refresh string
}

func newOAuthFrameworkTestManager(t *testing.T, store *OAuthStore) (gooauth2.Manager, string) {
	t.Helper()
	clientID, err := store.RegisterClient(
		"framework test",
		[]string{frameworkTestRedirect},
		[]string{gooauth2.AuthorizationCode.String(), gooauth2.Refreshing.String()},
	)
	if err != nil {
		t.Fatal(err)
	}
	return newOAuthFrameworkTestManagerForClient(t, store, clientID)
}

func newOAuthFrameworkTestManagerForClient(t *testing.T, store *OAuthStore, clientID string) (gooauth2.Manager, string) {
	t.Helper()
	manager := NewOAuthManager(
		store,
		frameworkTestKey,
		int64(time.Hour/time.Second),
		90*24*time.Hour,
	)
	return manager, clientID
}

func authorizeAndExchangeWithFramework(t *testing.T, manager gooauth2.Manager, clientID string, ctx context.Context) oauthFrameworkTokens {
	t.Helper()
	authorizeRequest := httptest.NewRequest(
		http.MethodGet,
		"/oauth/authorize?resource="+url.QueryEscape(frameworkTestResource),
		nil,
	)
	codeInfo, err := manager.GenerateAuthToken(ctx, gooauth2.Code, &gooauth2.TokenGenerateRequest{
		ClientID:            clientID,
		RedirectURI:         frameworkTestRedirect,
		CodeChallenge:       frameworkTestChallenge,
		CodeChallengeMethod: gooauth2.CodeChallengeS256,
		Request:             authorizeRequest,
	})
	if err != nil {
		t.Fatalf("GenerateAuthToken() error = %v", err)
	}
	accessInfo, err := manager.GenerateAccessToken(ctx, gooauth2.AuthorizationCode, authorizationCodeRequest(
		codeInfo.GetCode(), clientID, frameworkTestResource,
	))
	if err != nil {
		t.Fatalf("GenerateAccessToken() error = %v", err)
	}
	return oauthFrameworkTokens{
		Code:    codeInfo.GetCode(),
		Access:  accessInfo.GetAccess(),
		Refresh: accessInfo.GetRefresh(),
	}
}

func authorizationCodeRequest(code, clientID, resource string) *gooauth2.TokenGenerateRequest {
	values := url.Values{
		"grant_type":    {gooauth2.AuthorizationCode.String()},
		"code":          {code},
		"redirect_uri":  {frameworkTestRedirect},
		"client_id":     {clientID},
		"code_verifier": {frameworkTestVerifier},
		"resource":      {resource},
	}
	request := httptest.NewRequest(http.MethodPost, "/oauth/token", strings.NewReader(values.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return &gooauth2.TokenGenerateRequest{
		ClientID:     clientID,
		RedirectURI:  frameworkTestRedirect,
		Code:         code,
		CodeVerifier: frameworkTestVerifier,
		Request:      request,
	}
}

func refreshRequest(refresh, clientID, resource string) *gooauth2.TokenGenerateRequest {
	values := url.Values{
		"grant_type":    {gooauth2.Refreshing.String()},
		"refresh_token": {refresh},
		"client_id":     {clientID},
		"resource":      {resource},
	}
	request := httptest.NewRequest(http.MethodPost, "/oauth/token", strings.NewReader(values.Encode()))
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return &gooauth2.TokenGenerateRequest{
		ClientID: clientID,
		Refresh:  refresh,
		Request:  request,
	}
}

func refreshWithFramework(t *testing.T, manager gooauth2.Manager, clientID string, ctx context.Context, refresh string) oauthFrameworkTokens {
	t.Helper()
	info, err := manager.RefreshAccessToken(ctx, refreshRequest(refresh, clientID, frameworkTestResource))
	if err != nil {
		t.Fatalf("RefreshAccessToken() error = %v", err)
	}
	return oauthFrameworkTokens{Access: info.GetAccess(), Refresh: info.GetRefresh()}
}

func oauthFrameworkTestContext(clientID, resource string) context.Context {
	return WithOAuthRequest(context.Background(), frameworkTestIssuer, resource, clientID)
}
