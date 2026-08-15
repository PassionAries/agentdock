package app

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/uvwt/agentdock/internal/evolution"
)

func (r *Runtime) evolve(ctx context.Context, args map[string]any) (Result, error) {
	request, err := decodeEvolutionRequest(args)
	if err != nil {
		return nil, toolError("INVALID_EVOLVE_REQUEST", err.Error(), "validation")
	}
	switch request.Intent {
	case "propose", "bind", "supersede", "retract":
	default:
		return nil, toolError("INVALID_EVOLVE_INTENT", "model-facing evolve only accepts propose, bind, supersede or retract", "validation")
	}
	result, err := r.evolution.Manage(ctx, request)
	if err != nil {
		if errors.Is(err, evolution.ErrSelfProof) {
			return nil, toolError("REJECTED_SELF_PROOF", "guided experience cannot support itself from the same task", "validation")
		}
		return nil, toolErrorCause("EVOLVE_FAILED", err.Error(), "runtime", nil, err)
	}
	return evolutionResult(result), nil
}

// RuntimeEvolve 给 Nexus Stage 3 复用同一个 EvolutionService；不复制 lifecycle policy。
// Stage 3 只有候选提案权：来源由 AgentDock 强制标记，不能借 Runtime API 投票或改生命周期。
func (r *Runtime) RuntimeEvolve(ctx context.Context, args map[string]any) (Result, error) {
	request, err := decodeEvolutionRequest(args)
	if err != nil {
		return nil, toolError("INVALID_EVOLVE_REQUEST", err.Error(), "validation")
	}
	if request.Intent != "propose" || request.Candidate == nil {
		return nil, toolError("STAGE3_PROPOSAL_ONLY", "Nexus Stage 3 may only propose evolution candidates", "validation")
	}
	request.Candidate.Source = "nexus-stage3"
	result, err := r.evolution.Manage(ctx, request)
	if err != nil {
		return nil, toolErrorCause("EVOLVE_FAILED", err.Error(), "runtime", nil, err)
	}
	return evolutionResult(result), nil
}

func decodeEvolutionRequest(args map[string]any) (evolution.Request, error) {
	data, err := json.Marshal(args)
	if err != nil {
		return evolution.Request{}, err
	}
	var request evolution.Request
	if err := json.Unmarshal(data, &request); err != nil {
		return evolution.Request{}, err
	}
	if request.Intent == "" {
		return evolution.Request{}, errors.New("intent is required")
	}
	return request, nil
}

func evolutionResult(result evolution.Result) Result {
	out := Result{
		"intent":  result.Intent,
		"changed": result.Changed,
	}
	if result.Record != nil {
		out["evolution_id"] = result.Record.EvolutionID
		out["status"] = result.Record.Status
		out["revision"] = result.Record.Revision
		out["policy_version"] = result.Record.PolicyVersion
		out["support_count"] = result.Record.SupportCount
		out["contradict_count"] = result.Record.ContradictCount
	}
	if result.Relation != "" {
		out["relation"] = result.Relation
	}
	if result.Idempotent {
		out["idempotent"] = true
	}
	if result.Message != "" {
		out["message"] = result.Message
	}
	return out
}
