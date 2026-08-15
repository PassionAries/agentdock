package httpx

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"

	"github.com/uvwt/agentdock/internal/app"
)

type runtimeEvolutionCandidate struct {
	Type         string   `json:"type"`
	Statement    string   `json:"statement"`
	Scope        string   `json:"scope,omitempty"`
	Project      string   `json:"project,omitempty"`
	Device       string   `json:"device,omitempty"`
	CanonicalKey string   `json:"canonical_key,omitempty"`
	Source       string   `json:"source,omitempty"`
	Tags         []string `json:"tags,omitempty"`
}

type runtimeEvolutionRequest struct {
	Intent         string                     `json:"intent"`
	Candidate      *runtimeEvolutionCandidate `json:"candidate,omitempty"`
	EvolutionID    string                     `json:"evolution_id,omitempty"`
	TaskID         string                     `json:"task_id,omitempty"`
	ReviewRevision string                     `json:"review_revision,omitempty"`
	Relation       string                     `json:"relation,omitempty"`
	EvidenceRefs   []string                   `json:"evidence_refs,omitempty"`
	Rationale      string                     `json:"rationale,omitempty"`
	SupersededBy   string                     `json:"superseded_by,omitempty"`
}

func decodeRuntimeEvolutionRequest(r *http.Request) (map[string]any, error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 64*1024+1))
	if err != nil {
		return nil, runtimeEvolutionRequestError("failed to read evolve request body")
	}
	if len(body) > 64*1024 {
		return nil, runtimeEvolutionRequestError("evolve request body is too large")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var request runtimeEvolutionRequest
	if err := decoder.Decode(&request); err != nil {
		return nil, runtimeEvolutionRequestError("invalid evolve request body")
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, runtimeEvolutionRequestError("request body must contain exactly one JSON value")
	}
	data, err := json.Marshal(request)
	if err != nil {
		return nil, runtimeEvolutionRequestError("failed to normalize evolve request")
	}
	var args map[string]any
	if err := json.Unmarshal(data, &args); err != nil {
		return nil, runtimeEvolutionRequestError("failed to normalize evolve request")
	}
	return args, nil
}

func runtimeEvolutionRequestError(message string) error {
	return &app.ToolError{Code: "INVALID_EVOLVE_REQUEST", Message: message, Category: "validation"}
}
