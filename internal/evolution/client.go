package evolution

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/uvwt/agentdock/internal/config"
)

const maxNexusResponseBytes = 4 << 20

var ErrRevisionConflict = errors.New("evolution revision conflict")

type client struct {
	config func() config.Config
}

func (c client) query(ctx context.Context, query Query) ([]Record, error) {
	var out queryResult
	if err := c.post(ctx, "/internal/recall/lifecycle/query", query, &out); err != nil {
		return nil, err
	}
	return out.Records, nil
}

func (c client) transition(ctx context.Context, request transitionRequest) (transitionResult, error) {
	var out transitionResult
	if err := c.post(ctx, "/internal/recall/lifecycle/transition", request, &out); err != nil {
		return transitionResult{}, err
	}
	return out, nil
}

func (c client) post(ctx context.Context, path string, payload any, out any) error {
	cfg := c.config()
	endpoint := strings.TrimRight(strings.TrimSpace(cfg.NexusEndpoint), "/")
	if endpoint == "" {
		return errors.New("Nexus endpoint is not configured")
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	token := strings.TrimSpace(cfg.NexusEvolutionToken)
	if token == "" {
		return errors.New("AGENTDOCK_NEXUS_EVOLUTION_TOKEN is not configured")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	httpClient := &http.Client{
		Timeout:       8 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxNexusResponseBytes+1))
	if err != nil {
		return err
	}
	if len(data) > maxNexusResponseBytes {
		return errors.New("Nexus lifecycle response exceeds 4 MiB")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var failure struct {
			Code  string `json:"code"`
			Error string `json:"error"`
		}
		_ = json.Unmarshal(data, &failure)
		if resp.StatusCode == http.StatusConflict && failure.Code == "LIFECYCLE_REVISION_CONFLICT" {
			return ErrRevisionConflict
		}
		return fmt.Errorf("Nexus lifecycle request failed: %s", firstNonEmpty(failure.Error, resp.Status))
	}
	if err := json.Unmarshal(data, out); err != nil {
		return fmt.Errorf("decode Nexus lifecycle response: %w", err)
	}
	return nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return "unknown error"
}
