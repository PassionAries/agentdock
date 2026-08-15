package task

import (
	"context"

	"github.com/uvwt/agentdock/internal/taskstate"
)

// Evolution 是 Task 的旁路学习能力。召回或候选生成失败不能阻塞 Task 本身。
func (s *Service) refreshGuidanceBestEffort(ctx context.Context, task taskstate.Task) (taskstate.Task, string) {
	if s.evolution == nil || s.config().NexusEndpoint == "" {
		return task, ""
	}
	items, err := s.evolution.Guidance(ctx, task)
	if err != nil {
		return task, err.Error()
	}
	updated, err := s.tasks.SetGuidanceContext(task.ID, items)
	if err != nil {
		return task, err.Error()
	}
	return updated, ""
}

func (s *Service) refreshCandidatesBestEffort(ctx context.Context, task taskstate.Task) (taskstate.Task, string) {
	if s.evolution == nil || s.config().NexusEndpoint == "" || task.FinalReview == nil {
		return task, ""
	}
	items, err := s.evolution.Candidates(ctx, task)
	if err != nil {
		return task, err.Error()
	}
	updated, err := s.tasks.SetEvolutionCandidates(task.ID, task.FinalReview.ReviewRevision, items)
	if err != nil {
		return task, err.Error()
	}
	return updated, ""
}

func (s *Service) resolveBindingsBestEffort(ctx context.Context, task taskstate.Task) string {
	if s.evolution == nil || s.config().NexusEndpoint == "" || task.FinalReview == nil || len(task.EvolutionBindings) == 0 {
		return ""
	}
	if err := s.evolution.ResolveBindings(ctx, task); err != nil {
		return err.Error()
	}
	return ""
}
