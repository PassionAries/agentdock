package skill

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"mime"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	skills "github.com/uvwt/agentdock/internal/skill"
)

const (
	exportSkillMaxFiles      = 100
	exportSkillDocumentBytes = 256 * 1024
	exportSkillResourceBytes = 1 * 1024 * 1024
	exportSkillTotalBytes    = 5 * 1024 * 1024
)

type ExportResource struct {
	URI    string `json:"uri"`
	Digest string `json:"digest"`
}

type ExportManifest struct {
	URI         string           `json:"uri"`
	Frontmatter map[string]any   `json:"frontmatter"`
	Resources   []ExportResource `json:"resources"`
}

type ExportContent struct {
	URI      string
	MIMEType string
	Data     []byte
	IsText   bool
}

type ExportSnapshot struct {
	Manifest ExportManifest
	Contents map[string]ExportContent
}

// ExportSkillSnapshot 固定一次 active version 并同时读取 manifest 与资源内容，
// 避免扫描过程中切换 Skill 版本后出现 digest 与 resources/read 内容不一致。
func (s *Service) ExportSkillSnapshot(name string) (ExportSnapshot, error) {
	packageDir, _, err := s.runtimeSkillPackageDir(name)
	if err != nil {
		return ExportSnapshot{}, err
	}
	documentPath := filepath.Join(packageDir, "SKILL.md")
	documentInfo, err := os.Stat(documentPath)
	if err != nil || !documentInfo.Mode().IsRegular() {
		return ExportSnapshot{}, toolErrorDetails("SKILL_EXPORT_INVALID", "Skill export is missing SKILL.md", "validation", map[string]any{"skill": name})
	}
	if documentInfo.Size() > exportSkillDocumentBytes {
		return ExportSnapshot{}, toolErrorDetails(
			"SKILL_EXPORT_TOO_LARGE",
			"SKILL.md exceeds the export size limit",
			"validation",
			map[string]any{"skill": name, "size_bytes": documentInfo.Size(), "max_bytes": exportSkillDocumentBytes},
		)
	}
	document, err := skills.LoadSkillDocument(packageDir)
	if err != nil {
		return ExportSnapshot{}, skillToolError(err)
	}
	frontmatter, err := skills.LoadSkillFrontmatter(packageDir)
	if err != nil {
		return ExportSnapshot{}, skillToolError(err)
	}
	if document.Name != name {
		return ExportSnapshot{}, toolErrorDetails(
			"SKILL_EXPORT_NAME_MISMATCH",
			"active Skill document name does not match the selected Skill",
			"validation",
			map[string]any{"skill": name, "document_name": document.Name},
		)
	}

	files, err := collectRuntimeSkillFiles(packageDir)
	if err != nil {
		return ExportSnapshot{}, err
	}
	if len(files) == 0 || !strings.EqualFold(files[0].Path, "SKILL.md") {
		return ExportSnapshot{}, toolErrorDetails("SKILL_EXPORT_INVALID", "Skill export is missing SKILL.md", "validation", map[string]any{"skill": name})
	}
	if len(files) > exportSkillMaxFiles {
		return ExportSnapshot{}, toolErrorDetails(
			"SKILL_EXPORT_TOO_LARGE",
			"Skill export exceeds the maximum file count",
			"validation",
			map[string]any{"skill": name, "files": len(files), "max_files": exportSkillMaxFiles},
		)
	}

	resources := make([]ExportResource, 0, len(files))
	contents := make(map[string]ExportContent, len(files))
	var totalBytes int64
	for _, file := range files {
		limit := int64(exportSkillResourceBytes)
		if strings.EqualFold(file.Path, "SKILL.md") {
			limit = exportSkillDocumentBytes
		}
		if file.SizeBytes > limit {
			return ExportSnapshot{}, toolErrorDetails(
				"SKILL_EXPORT_TOO_LARGE",
				"Skill export resource exceeds the size limit",
				"validation",
				map[string]any{"skill": name, "path": file.Path, "size_bytes": file.SizeBytes, "max_bytes": limit},
			)
		}
		totalBytes += file.SizeBytes
		if totalBytes > exportSkillTotalBytes {
			return ExportSnapshot{}, toolErrorDetails(
				"SKILL_EXPORT_TOO_LARGE",
				"Skill export exceeds the total size limit",
				"validation",
				map[string]any{"skill": name, "size_bytes": totalBytes, "max_bytes": exportSkillTotalBytes},
			)
		}

		uri := skillResourceURI(name, filepath.ToSlash(file.Path))
		resolvedPath := filepath.Join(packageDir, filepath.FromSlash(file.Path))
		content, err := readExportContent(resolvedPath, uri)
		if err != nil {
			return ExportSnapshot{}, err
		}
		digest := fmt.Sprintf("sha256:%x", sha256.Sum256(content.Data))
		resources = append(resources, ExportResource{URI: content.URI, Digest: digest})
		contents[content.URI] = content
	}

	return ExportSnapshot{
		Manifest: ExportManifest{
			URI:         skillResourceURI(name, "SKILL.md"),
			Frontmatter: frontmatter,
			Resources:   resources,
		},
		Contents: contents,
	}, nil
}

func readExportContent(resolvedPath, displayURI string) (ExportContent, error) {
	info, err := os.Stat(resolvedPath)
	if err != nil || !info.Mode().IsRegular() {
		return ExportContent{}, toolErrorDetails("SKILL_RESOURCE_NOT_FOUND", "skill resource does not exist", "validation", map[string]any{"path": displayURI})
	}

	limit := int64(exportSkillResourceBytes)
	if strings.EqualFold(filepath.Base(resolvedPath), "SKILL.md") {
		limit = exportSkillDocumentBytes
	}
	if info.Size() > limit {
		return ExportContent{}, toolErrorDetails(
			"SKILL_EXPORT_TOO_LARGE",
			"Skill export resource exceeds the size limit",
			"validation",
			map[string]any{"path": displayURI, "size_bytes": info.Size(), "max_bytes": limit},
		)
	}

	file, err := os.Open(resolvedPath)
	if err != nil {
		return ExportContent{}, toolErrorCause("SKILL_FILE_READ_FAILED", "failed to read skill resource", "runtime", map[string]any{"path": displayURI}, err)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return ExportContent{}, toolErrorCause("SKILL_FILE_READ_FAILED", "failed to read skill resource", "runtime", map[string]any{"path": displayURI}, err)
	}
	if int64(len(data)) > limit {
		return ExportContent{}, toolErrorDetails("SKILL_EXPORT_TOO_LARGE", "Skill export resource exceeds the size limit", "validation", map[string]any{"path": displayURI, "max_bytes": limit})
	}

	mimeType := mime.TypeByExtension(strings.ToLower(filepath.Ext(resolvedPath)))
	isText := utf8.Valid(data) && !bytes.ContainsRune(data, '\x00')
	if isText && mimeType == "" {
		mimeType = "text/plain; charset=utf-8"
	}
	if !isText && mimeType == "" {
		mimeType = "application/octet-stream"
	}
	return ExportContent{URI: displayURI, MIMEType: mimeType, Data: data, IsText: isText}, nil
}
