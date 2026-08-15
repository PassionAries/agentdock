package taskstate

import "testing"

func TestGuidanceSeenPersistsAcrossRefreshes(t *testing.T) {
	store, err := New(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	task, err := store.Create("test", "test guidance history", []string{"done"}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.SetGuidanceContext(task.ID, []EvolutionContextItem{{EvolutionID: "evo_a"}}); err != nil {
		t.Fatal(err)
	}
	task, err = store.SetGuidanceContext(task.ID, []EvolutionContextItem{{EvolutionID: "evo_b"}})
	if err != nil {
		t.Fatal(err)
	}
	if len(task.GuidanceContext) != 1 || task.GuidanceContext[0].EvolutionID != "evo_b" {
		t.Fatalf("current guidance=%#v", task.GuidanceContext)
	}
	if len(task.EvolutionGuidanceSeen) != 2 || task.EvolutionGuidanceSeen[0] != "evo_a" || task.EvolutionGuidanceSeen[1] != "evo_b" {
		t.Fatalf("guidance history=%#v", task.EvolutionGuidanceSeen)
	}
}
