package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// Store is the whole backend: a directory of markdown files in a git repo.
// No database - a directory scan is fast enough at this data's scale (see
// docs/api-contract.md), and the git repo doubling as the on-disk format
// keeps this legible to a person with no code, a decade from now.
type Store struct {
	dir string
	mu  sync.Mutex // serializes writes + git commits; single-user, tiny traffic
}

func NewStore(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("create storage dir: %w", err)
	}
	s := &Store{dir: dir}
	if err := s.ensureGitRepo(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) ensureGitRepo() error {
	if _, err := os.Stat(filepath.Join(s.dir, ".git")); err == nil {
		return nil
	}
	if err := s.git("init"); err != nil {
		return fmt.Errorf("git init: %w", err)
	}
	// A fresh machine may have no global git identity configured; scope
	// one to this repo alone so commits never fail on that.
	if err := s.git("config", "--local", "user.name", "Inkwell"); err != nil {
		return err
	}
	if err := s.git("config", "--local", "user.email", "inkwell@localhost"); err != nil {
		return err
	}
	return nil
}

func (s *Store) git(args ...string) error {
	cmd := exec.Command("git", append([]string{"-C", s.dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// hasStagedChanges reports whether `git add` staged anything new - lets us
// skip committing (and erroring on "nothing to commit") when a retried
// upload is byte-identical to what's already on disk.
func (s *Store) hasStagedChanges() bool {
	cmd := exec.Command("git", "-C", s.dir, "diff", "--cached", "--quiet")
	err := cmd.Run()
	return err != nil // non-zero exit means there IS a diff
}

// audioExtensions are the companion-file extensions the backend recognizes
// when checking whether an inkling has an utterance recording alongside it.
var audioExtensions = []string{".m4a", ".caf", ".wav"}

// normalizeAudioExt maps the client-supplied filename extension onto the
// allowlist above. The extension becomes part of a path, so it is never
// trusted verbatim; anything unrecognized is stored as .m4a, which is also
// what keeps findAudioFile (and therefore hasAudio) able to see it again.
func normalizeAudioExt(ext string) string {
	lower := strings.ToLower(strings.TrimSpace(ext))
	for _, allowed := range audioExtensions {
		if lower == allowed {
			return allowed
		}
	}
	return audioExtensions[0]
}

func (s *Store) findAudioFile(base string) string {
	for _, ext := range audioExtensions {
		if _, err := os.Stat(filepath.Join(s.dir, base+ext)); err == nil {
			return base + ext
		}
	}
	return ""
}

// findByID scans for an existing markdown file whose front matter id
// matches, since the filename is explicitly not identity. Returns the
// file's base name (no extension) and its currently stored front matter, or
// ok=false if no match exists.
func (s *Store) findByID(id string) (base string, existing Inkling, ok bool) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return "", Inkling{}, false
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(s.dir, e.Name()))
		if err != nil {
			continue
		}
		parsed, err := parseMarkdown(string(raw))
		if err != nil {
			continue
		}
		if strings.EqualFold(parsed.ID, id) {
			return strings.TrimSuffix(e.Name(), ".md"), parsed, true
		}
	}
	return "", Inkling{}, false
}

// Upsert writes the inkling's markdown (and audio, if provided) and commits.
// Returns whether this created a new file (vs. updating an existing one).
func (s *Store) Upsert(ink Inkling, audio []byte, audioExt string) (created bool, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	base, _, exists := s.findByID(ink.ID)
	if !exists {
		base = filenameBase(ink.ID, ink.Text)
	}

	mdPath := filepath.Join(s.dir, base+".md")
	if err := os.WriteFile(mdPath, []byte(renderMarkdown(ink)), 0o644); err != nil {
		return false, fmt.Errorf("write markdown: %w", err)
	}
	if err := s.git("add", base+".md"); err != nil {
		return false, err
	}

	if len(audio) > 0 {
		audioExt = normalizeAudioExt(audioExt)
		audioPath := filepath.Join(s.dir, base+audioExt)
		if err := os.WriteFile(audioPath, audio, 0o644); err != nil {
			return false, fmt.Errorf("write audio: %w", err)
		}
		if err := s.git("add", base+audioExt); err != nil {
			return false, err
		}
	}

	if s.hasStagedChanges() {
		verb := "update"
		if !exists {
			verb = "add"
		}
		msg := fmt.Sprintf("%s inkling: %s", verb, base)
		if err := s.git("commit", "-m", msg); err != nil {
			return false, err
		}
	}

	return !exists, nil
}

// List returns every inkling on disk, newest created first.
func (s *Store) List() ([]Inkling, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}

	var result []Inkling
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(s.dir, e.Name()))
		if err != nil {
			continue
		}
		ink, err := parseMarkdown(string(raw))
		if err != nil {
			continue
		}
		base := strings.TrimSuffix(e.Name(), ".md")
		ink.HasAudio = s.findAudioFile(base) != ""
		result = append(result, ink)
	}

	sort.Slice(result, func(i, j int) bool {
		return result[i].Created > result[j].Created
	})
	return result, nil
}
