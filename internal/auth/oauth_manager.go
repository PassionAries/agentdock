package auth

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	gooauth2 "github.com/go-oauth2/oauth2/v4"
	oautherrors "github.com/go-oauth2/oauth2/v4/errors"
	"github.com/go-oauth2/oauth2/v4/manage"
)

const oauthResourceExtension = "resource"

// NewOAuthManager 使用 go-oauth2 自带的 Manager 承担授权码签发、PKCE 校验、
// Access Token 签发、Refresh Token 轮换和 TokenStore 生命周期。AgentDock 只保留
// 动态客户端注册、MCP resource 约束以及持久化安全策略。
func NewOAuthManager(
	store *OAuthStore,
	signingKey string,
	accessTTL, refreshTTL time.Duration,
) *manage.Manager {
	store.configureOAuthFramework(signingKey, accessTTL, refreshTTL)

	manager := manage.NewDefaultManager()
	manager.MapClientStorage(oauthClientStore{store: store})
	manager.MapTokenStorage(store)
	manager.MapAuthorizeGenerate(oauthAuthorizeGenerator{})
	manager.MapAccessGenerate(oauthAccessGenerator{store: store})
	manager.SetAuthorizeCodeExp(5 * time.Minute)
	manager.SetAuthorizeCodeTokenCfg(&manage.Config{
		AccessTokenExp:    accessTTL,
		RefreshTokenExp:   refreshTTL,
		IsGenerateRefresh: true,
	})
	manager.SetRefreshTokenCfg(&manage.RefreshingConfig{
		AccessTokenExp:     accessTTL,
		RefreshTokenExp:    refreshTTL,
		IsGenerateRefresh:  true,
		IsResetRefreshTime: true,
		IsRemoveAccess:     false,
		IsRemoveRefreshing: false,
	})
	manager.SetValidateURIHandler(func(clientID, redirectURI string) error {
		if !store.ValidateClientRedirect(clientID, redirectURI) {
			return oautherrors.ErrInvalidAuthorizeCode
		}
		return nil
	})
	manager.SetExtractExtensionHandler(func(request *gooauth2.TokenGenerateRequest, info gooauth2.ExtendableTokenInfo) {
		if request == nil || request.Request == nil || request.Request.FormValue("grant_type") != "" {
			return
		}
		resource := strings.TrimSpace(request.Request.FormValue("resource"))
		info.SetExtension(url.Values{oauthResourceExtension: []string{resource}})
	})
	return manager
}

type oauthClientStore struct {
	store *OAuthStore
}

func (s oauthClientStore) GetByID(_ context.Context, clientID string) (gooauth2.ClientInfo, error) {
	_, ok := s.store.ClientRegistration(clientID)
	if !ok {
		return nil, oautherrors.ErrInvalidClient
	}
	return oauthClient{id: strings.TrimSpace(clientID)}, nil
}

type oauthClient struct {
	id string
}

func (c oauthClient) GetID() string     { return c.id }
func (c oauthClient) GetSecret() string { return "" }
func (c oauthClient) GetDomain() string { return c.id }
func (c oauthClient) IsPublic() bool    { return true }
func (c oauthClient) GetUserID() string { return "" }

type oauthAuthorizeGenerator struct{}

func (oauthAuthorizeGenerator) Token(_ context.Context, data *gooauth2.GenerateBasic) (string, error) {
	if data == nil || data.TokenInfo == nil {
		return "", errors.New("OAuth authorization token data is missing")
	}
	grantID, err := RandomToken(24)
	if err != nil {
		return "", fmt.Errorf("generate OAuth grant ID: %w", err)
	}
	code, err := RandomToken(32)
	if err != nil {
		return "", fmt.Errorf("generate OAuth authorization code: %w", err)
	}
	data.TokenInfo.SetUserID(grantID)
	return code, nil
}

type oauthAccessGenerator struct {
	store *OAuthStore
}

func (g oauthAccessGenerator) Token(_ context.Context, data *gooauth2.GenerateBasic, generateRefresh bool) (string, string, error) {
	if data == nil || data.TokenInfo == nil || data.Client == nil {
		return "", "", errors.New("OAuth access token data is missing")
	}
	access, err := RandomToken(32)
	if err != nil {
		return "", "", fmt.Errorf("generate OAuth access token: %w", err)
	}
	if !generateRefresh || !g.store.ClientAllowsGrant(data.Client.GetID(), gooauth2.Refreshing.String()) {
		return access, "", nil
	}

	generation := uint64(1)
	if previous := strings.TrimSpace(data.TokenInfo.GetRefresh()); previous != "" {
		claims, ok := g.store.verifyRefreshToken(previous)
		if !ok || claims.GrantID != data.TokenInfo.GetUserID() {
			return "", "", oautherrors.ErrInvalidRefreshToken
		}
		generation = claims.Generation + 1
	}
	refresh, err := g.store.signRefreshToken(refreshTokenClaims{
		GrantID:    data.TokenInfo.GetUserID(),
		Generation: generation,
	})
	if err != nil {
		return "", "", err
	}
	return access, refresh, nil
}

var _ gooauth2.ClientStore = oauthClientStore{}
var _ gooauth2.AuthorizeGenerate = oauthAuthorizeGenerator{}
var _ gooauth2.AccessGenerate = oauthAccessGenerator{}
