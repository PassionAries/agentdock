package skill

import (
	"strings"
	"testing"
)

func TestParseSkillDocumentRequiresNameDescriptionVersionAndBody(t *testing.T) {
	doc, err := ParseSkillDocument([]byte(`---
name: demo-skill
description: Use this Skill for a demo workflow.
version: 1.2.3
---

# Demo Skill

Use existing tools to complete the workflow.
`))
	if err != nil {
		t.Fatal(err)
	}
	if doc.Name != "demo-skill" || doc.Version != "1.2.3" || !strings.Contains(doc.Body, "Demo Skill") {
		t.Fatalf("unexpected document: %#v", doc)
	}
}

func TestParseSkillDocumentRejectsMissingVersion(t *testing.T) {
	_, err := ParseSkillDocument([]byte(`---
name: demo-skill
description: Demo.
---

# Demo
`))
	if err == nil || !strings.Contains(err.Error(), "version is required") {
		t.Fatalf("expected version error, got %v", err)
	}
}

func TestParseSkillDocumentSupportsFoldedDescription(t *testing.T) {
	doc, err := ParseSkillDocument([]byte(`---
name: folded-skill
description: >
  First sentence.
  Second sentence.
version: 1.0.0
---

# Folded
`))
	if err != nil {
		t.Fatal(err)
	}
	if doc.Description != "First sentence. Second sentence." {
		t.Fatalf("description = %q", doc.Description)
	}
}

func TestParseSkillDocumentRejectsEmptyBlockDescription(t *testing.T) {
	_, err := ParseSkillDocument([]byte(`---
name: empty-description
description: |
version: 1.0.0
---

# Empty
`))
	if err == nil || !strings.Contains(err.Error(), "description is required") {
		t.Fatalf("expected empty description error, got %v", err)
	}
}

func TestParseFullSkillFrontmatterPreservesAllEntries(t *testing.T) {
	frontmatter, err := parseFullSkillFrontmatter([]byte(`---
name: demo-skill
description: Demo workflow.
version: 1.2.3
license: MIT
tags:
  - demo
  - gpt
metadata:
  owner: dock
---

# Demo
`))
	if err != nil {
		t.Fatal(err)
	}
	if frontmatter["license"] != "MIT" {
		t.Fatalf("license = %#v", frontmatter["license"])
	}
	tags, ok := frontmatter["tags"].([]any)
	if !ok || len(tags) != 2 || tags[0] != "demo" || tags[1] != "gpt" {
		t.Fatalf("tags = %#v", frontmatter["tags"])
	}
	metadata, ok := frontmatter["metadata"].(map[string]any)
	if !ok || metadata["owner"] != "dock" {
		t.Fatalf("metadata = %#v", frontmatter["metadata"])
	}
}
