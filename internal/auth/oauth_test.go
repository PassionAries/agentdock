package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

const oauthTestGrantID = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

func TestRandomTokenUsesRequestedEntropyLength(t *testing.T) {
	if _, err := RandomToken(0); err == nil {
		t.Fatal("RandomToken(0) error = nil, want validation error")
	}

	first, err := RandomToken(32)
	if err != nil {
		t.Fatalf("RandomToken() error = %v", err)
	}
	second, err := RandomToken(32)
	if err != nil {
		t.Fatalf("RandomToken() second error = %v", err)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(first)
	if err != nil {
		t.Fatalf("decode token: %v", err)
	}
	if len(decoded) != 32 {
		t.Fatalf("decoded token length = %d, want 32", len(decoded))
	}
	if first == second {
		t.Fatal("two independently generated tokens are equal")
	}
}

func TestPersistentOAuthStoreRegistersShortClientAcrossReloads(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oauth", "state-v1.json")
	store, err := NewPersistentOAuthStore(path, "test-refresh-signing-key-32-bytes-long")
	if err != nil {
		t.Fatal(err)
	}
	clientID, err := store.RegisterClient(
		"Test Client",
		[]string{"https://client.example/callback"},
		[]string{"authorization_code", "refresh_token"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(clientID, shortClientPrefix) || len(clientID) > 64 {
		t.Fatalf("client ID = %q, want short persisted ID", clientID)
	}
	registration, ok := store.ClientRegistration(clientID)
	if !ok || registration.ClientName != "Test Client" {
		t.Fatalf("registration = %#v, ok=%v", registration, ok)
	}
	if !store.ValidateClientRedirect(clientID, "https://client.example/callback") ||
		!store.ClientAllowsGrant(clientID, "refresh_token") {
		t.Fatal("new client registration was not bound to redirect URI and grant")
	}
	secondClientID, err := store.RegisterClient(
		"Test Client",
		[]string{"https://client.example/callback"},
		[]string{"authorization_code", "refresh_token"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if secondClientID == clientID {
		t.Fatal("separate dynamic registrations reused the same client ID")
	}

	reloaded, err := NewPersistentOAuthStore(path, "test-refresh-signing-key-32-bytes-long")
	if err != nil {
		t.Fatal(err)
	}
	if !reloaded.ValidateClientID(clientID) ||
		!reloaded.ValidateClientRedirect(clientID, "https://client.example/callback") ||
		!reloaded.ClientAllowsGrant(clientID, "authorization_code") {
		t.Fatal("persisted client registration was not valid after reload")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
		t.Fatalf("OAuth state mode = %o, want 600", info.Mode().Perm())
	}
}

func TestPersistentOAuthStoreRejectsVersionTwoState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oauth", "state-v1.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"version":2,"tokens":{},"clients":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewPersistentOAuthStore(path, "test-refresh-signing-key-32-bytes-long"); err == nil || !strings.Contains(err.Error(), "unsupported OAuth state version 2") {
		t.Fatalf("NewPersistentOAuthStore() error = %v, want version 2 rejection", err)
	}
}

func TestPersistentOAuthStoreRejectsVersionThreeState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oauth", "state-v1.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"version":3,"grants":{},"clients":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewPersistentOAuthStore(path, "test-refresh-signing-key-32-bytes-long"); err == nil || !strings.Contains(err.Error(), "unsupported OAuth state version 3") {
		t.Fatalf("NewPersistentOAuthStore() error = %v, want version 3 rejection", err)
	}
}

func TestPersistentOAuthStoreRejectsVersionFourState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oauth", "state-v1.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`{"version":4,"grants":{},"clients":{}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewPersistentOAuthStore(path, "test-refresh-signing-key-32-bytes-long"); err == nil || !strings.Contains(err.Error(), "unsupported OAuth state version 4") {
		t.Fatalf("NewPersistentOAuthStore() error = %v, want version 4 rejection", err)
	}
}

func TestPersistentOAuthStoreRejectsCorruptState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state-v1.json")
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewPersistentOAuthStore(path, "test-refresh-signing-key-32-bytes-long"); err == nil || !strings.Contains(err.Error(), "decode OAuth state") {
		t.Fatalf("NewPersistentOAuthStore() error = %v", err)
	}
}

func TestVerifyPKCEUsesS256(t *testing.T) {
	const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	const challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
	if !VerifyPKCE(verifier, challenge) {
		t.Fatal("VerifyPKCE() rejected RFC 7636 S256 example")
	}
	for _, invalidVerifier := range []string{
		verifier[:42],
		verifier + "!",
		strings.Repeat("a", 129),
		verifier + "x",
	} {
		if VerifyPKCE(invalidVerifier, challenge) {
			t.Fatalf("VerifyPKCE() accepted invalid verifier %q", invalidVerifier)
		}
	}
	for _, invalidChallenge := range []string{"", challenge[:42], challenge + "=", strings.Repeat("!", 43)} {
		if ValidPKCEChallenge(invalidChallenge) || VerifyPKCE(verifier, invalidChallenge) {
			t.Fatalf("invalid PKCE challenge accepted: %q", invalidChallenge)
		}
	}
	if !ValidPKCEChallenge(challenge) {
		t.Fatal("ValidPKCEChallenge() rejected RFC 7636 example")
	}
}

func TestValidateLegacyAccessTokenRejectsInvalidClaims(t *testing.T) {
	const issuer = "https://agentdock.example"
	const audience = issuer + "/mcp"
	const key = "test-signing-key"
	now := time.Now()
	tests := []struct {
		name   string
		claims tokenClaims
	}{
		{
			name: "expired",
			claims: tokenClaims{
				Issuer: issuer, Audience: audience, GrantID: "grant",
				IssuedAt: now.Add(-2 * time.Hour).Unix(), ExpiresAt: now.Add(-time.Hour).Unix(),
			},
		},
		{
			name: "missing issued at",
			claims: tokenClaims{
				Issuer: issuer, Audience: audience, GrantID: "grant", ExpiresAt: now.Add(time.Hour).Unix(),
			},
		},
		{
			name: "wrong audience",
			claims: tokenClaims{
				Issuer: issuer, Audience: "other", GrantID: "grant",
				IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Hour).Unix(),
			},
		},
		{
			name: "issued too far in future",
			claims: tokenClaims{
				Issuer: issuer, Audience: audience, GrantID: "grant",
				IssuedAt: now.Add(2 * time.Minute).Unix(), ExpiresAt: now.Add(time.Hour).Unix(),
			},
		},
		{
			name: "expires before issued at",
			claims: tokenClaims{
				Issuer: issuer, Audience: audience, GrantID: "grant",
				IssuedAt: now.Add(30 * time.Second).Unix(), ExpiresAt: now.Add(20 * time.Second).Unix(),
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			token := signClaimsForTest(t, test.claims, key)
			if _, ok := validateLegacyAccessToken(token, issuer, audience, key); ok {
				t.Fatal("ValidateToken() accepted invalid claims")
			}
		})
	}
	for _, token := range []string{"", "one-part", "not-base64.signature", "e30.invalid-signature"} {
		if _, ok := validateLegacyAccessToken(token, issuer, audience, key); ok {
			t.Fatalf("ValidateToken(%q) = true, want false", token)
		}
	}
}

func TestAppendQueryPreservesExistingValues(t *testing.T) {
	got := AppendQuery("https://client.example/callback?existing=1", url.Values{
		"code":  {"code-value"},
		"state": {"state-value"},
	})
	parsed, err := url.Parse(got)
	if err != nil {
		t.Fatalf("parse result: %v", err)
	}
	if parsed.Query().Get("existing") != "1" ||
		parsed.Query().Get("code") != "code-value" ||
		parsed.Query().Get("state") != "state-value" {
		t.Fatalf("query = %#v", parsed.Query())
	}
	if got := AppendQuery("://bad-url", url.Values{"code": {"value"}}); got != "://bad-url" {
		t.Fatalf("AppendQuery() invalid URL = %q, want original", got)
	}
}

func TestBearerAuthorization(t *testing.T) {
	request, err := http.NewRequest(http.MethodGet, "https://agentdock.example", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !(Bearer{}).Authorized(request) {
		t.Fatal("disabled bearer auth rejected request")
	}

	bearer := Bearer{Token: "secret"}
	for _, header := range []string{"", "Bearer", "Basic secret", "Bearer wrong"} {
		request.Header.Set("Authorization", header)
		if bearer.Authorized(request) {
			t.Fatalf("Authorized() accepted header %q", header)
		}
	}
	for _, header := range []string{"  Bearer secret  ", "bearer secret", "BEARER secret"} {
		request.Header.Set("Authorization", header)
		if !bearer.Authorized(request) {
			t.Fatalf("Authorized() rejected valid bearer header %q", header)
		}
	}
}

func TestEquivalentResourceURINormalizesSchemeHostAndDefaultPort(t *testing.T) {
	for _, pair := range [][2]string{
		{"HTTPS://MCP.EXAMPLE.COM/mcp", "https://mcp.example.com/mcp"},
		{"https://mcp.example.com:443/mcp", "https://mcp.example.com/mcp"},
		{"http://LOCALHOST:80/mcp", "http://localhost/mcp"},
	} {
		if !EquivalentResourceURI(pair[0], pair[1]) {
			t.Fatalf("resources should be equivalent: %q %q", pair[0], pair[1])
		}
	}
	for _, pair := range [][2]string{
		{"https://mcp.example.com/mcp", "https://mcp.example.com/other"},
		{"https://mcp.example.com/mcp?a=1", "https://mcp.example.com/mcp?a=2"},
		{"https://user@mcp.example.com/mcp", "https://mcp.example.com/mcp"},
	} {
		if EquivalentResourceURI(pair[0], pair[1]) {
			t.Fatalf("resources should differ: %q %q", pair[0], pair[1])
		}
	}
}

func signClaimsForTest(t *testing.T, claims tokenClaims, key string) string {
	t.Helper()
	body, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawURLEncoding.EncodeToString(body)
	mac := hmac.New(sha256.New, []byte(key))
	if _, err := mac.Write([]byte(encoded)); err != nil {
		t.Fatal(err)
	}
	return encoded + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func TestOAuthClientCleanupRemovesAssociatedStateAndFreesCapacity(t *testing.T) {
	store := NewOAuthStore()
	now := time.Now()
	expiredAt := now.Add(-oauthClientIdleTTL - time.Hour).Unix()
	for index := 0; index < maxOAuthClients; index++ {
		clientID := fmt.Sprintf("expired-client-%04d", index)
		store.clients[clientID] = OAuthClientRegistration{
			ClientName:   "expired",
			RedirectURIs: []string{"https://client.example/callback"},
			GrantTypes:   []string{"authorization_code"},
			IssuedAt:     expiredAt,
			LastUsedAt:   expiredAt,
		}
	}
	store.grants[oauthTestGrantID] = OAuthGrant{ClientID: "expired-client-0000", Resource: "https://agentdock.example/mcp", ExpiresAt: now.Add(time.Hour).Unix()}
	store.codes["expired-code"] = OAuthCode{ClientID: "expired-client-0000", ExpiresAt: now.Add(time.Hour)}

	clientID, err := store.RegisterClient("new", []string{"https://new.example/callback"}, []string{"authorization_code"})
	if err != nil {
		t.Fatalf("RegisterClient() after cleanup: %v", err)
	}
	if clientID == "" || len(store.clients) != 1 {
		t.Fatalf("client registry = %#v", store.clients)
	}
	if len(store.grants) != 0 || len(store.codes) != 0 {
		t.Fatalf("associated state remained: grants=%#v codes=%#v", store.grants, store.codes)
	}
}

func TestOAuthClientUseRefreshesLastUsedAtAtMostDaily(t *testing.T) {
	store := NewOAuthStore()
	clientID, err := store.RegisterClient("client", []string{"https://client.example/callback"}, []string{"authorization_code"})
	if err != nil {
		t.Fatal(err)
	}
	store.mu.Lock()
	registration := store.clients[clientID]
	registration.LastUsedAt = time.Now().Add(-oauthClientTouchInterval - time.Hour).Unix()
	store.clients[clientID] = registration
	store.mu.Unlock()
	before := registration.LastUsedAt
	if !store.ValidateClientID(clientID) {
		t.Fatal("active client was rejected")
	}
	after := store.clients[clientID].LastUsedAt
	if after <= before {
		t.Fatalf("last_used_at = %d, want > %d", after, before)
	}
	if !store.ValidateClientID(clientID) {
		t.Fatal("client was rejected on second validation")
	}
	if got := store.clients[clientID].LastUsedAt; got != after {
		t.Fatalf("second validation rewrote last_used_at: got %d want %d", got, after)
	}
}

func TestPersistentOAuthStoreMigratesLegacyClientLastUse(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "oauth", "state-v1.json")
	rawID, err := RandomToken(24)
	if err != nil {
		t.Fatal(err)
	}
	clientID := shortClientPrefix + rawID
	now := time.Now().Unix()
	state := oauthState{
		Version: oauthStateVersion,
		Grants:  map[string]OAuthGrant{},
		Clients: map[string]OAuthClientRegistration{
			clientID: {
				ClientName:   "legacy",
				RedirectURIs: []string{"https://client.example/callback"},
				GrantTypes:   []string{"authorization_code"},
				IssuedAt:     now - int64((oauthClientIdleTTL+24*time.Hour)/time.Second),
			},
		},
	}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := NewPersistentOAuthStore(path, "test-refresh-signing-key-32-bytes-long")
	if err != nil {
		t.Fatal(err)
	}
	registration, ok := store.ClientRegistration(clientID)
	if !ok || registration.LastUsedAt == 0 {
		t.Fatalf("legacy registration = %#v, ok=%v", registration, ok)
	}
}

func TestOAuthClientLookupRestoresPrunedStateWhenPersistenceFails(t *testing.T) {
	store := NewOAuthStore()
	store.statePath = t.TempDir() // A directory cannot be replaced by the state file.
	now := time.Now()
	expiredAt := now.Add(-oauthClientIdleTTL - time.Hour).Unix()
	store.clients["expired"] = OAuthClientRegistration{IssuedAt: expiredAt, LastUsedAt: expiredAt}
	store.clients["active"] = OAuthClientRegistration{IssuedAt: now.Unix(), LastUsedAt: now.Unix()}
	store.grants["grant"] = OAuthGrant{ClientID: "expired"}
	store.codes["code"] = OAuthCode{ClientID: "expired"}

	if !store.ValidateClientID("active") {
		t.Fatal("active client was rejected after cleanup persistence failure")
	}
	if _, ok := store.clients["expired"]; !ok {
		t.Fatal("expired client was not restored after persistence failure")
	}
	if _, ok := store.grants["grant"]; !ok {
		t.Fatal("associated grant was not restored after persistence failure")
	}
	if _, ok := store.codes["code"]; !ok {
		t.Fatal("associated code was not restored after persistence failure")
	}
}

func TestRegisterClientRestoresPrunedCodesWhenPersistenceFails(t *testing.T) {
	store := NewOAuthStore()
	store.statePath = t.TempDir()
	expiredAt := time.Now().Add(-oauthClientIdleTTL - time.Hour).Unix()
	store.clients["expired"] = OAuthClientRegistration{IssuedAt: expiredAt, LastUsedAt: expiredAt}
	store.codes["code"] = OAuthCode{ClientID: "expired"}

	if _, err := store.RegisterClient("new", []string{"https://client.example/callback"}, []string{"authorization_code"}); err == nil {
		t.Fatal("RegisterClient() succeeded despite persistence failure")
	}
	if len(store.clients) != 1 {
		t.Fatalf("client count = %d, want original state", len(store.clients))
	}
	if _, ok := store.clients["expired"]; !ok {
		t.Fatal("expired client was not restored")
	}
	if _, ok := store.codes["code"]; !ok {
		t.Fatal("authorization code was not restored")
	}
}

func TestPersistentOAuthStoreRejectsOversizedState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oauth", "state-v1.json")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Truncate(maxOAuthStateSize + 1); err != nil {
		_ = file.Close()
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := NewPersistentOAuthStore(path, "test-refresh-signing-key-32-bytes-long"); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("NewPersistentOAuthStore() error = %v, want size limit", err)
	}
}
