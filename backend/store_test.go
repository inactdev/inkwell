package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func requireGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
}

func TestSlugify(t *testing.T) {
	cases := map[string]string{
		"Rig a tide-powered charger for the buoy sensors": "rig-a-tide-powered-charger-for-the-buoy",
		"   ":               "inkling",
		"Hello, World! 123": "hello-world-123",
	}
	for input, want := range cases {
		got := slugify(input)
		if got != want {
			t.Errorf("slugify(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestFrontMatterRoundTrip(t *testing.T) {
	ink := Inkling{
		ID:      "3f29f1de-6b3a-4b7e-9c9a-1a2b3c4d5e6f",
		Created: "2026-07-31T08:11:00Z",
		Updated: "2026-07-31T08:11:00Z",
		Text:    "Rig a tide-powered charger for the buoy sensors.",
	}
	raw := renderMarkdown(ink)
	parsed, err := parseMarkdown(raw)
	if err != nil {
		t.Fatalf("parseMarkdown: %v", err)
	}
	if parsed.ID != ink.ID || parsed.Created != ink.Created || parsed.Updated != ink.Updated || parsed.Text != ink.Text {
		t.Errorf("round trip mismatch: got %+v, want %+v", parsed, ink)
	}
}

func TestUpsertCreatesThenUpdatesSameFile(t *testing.T) {
	requireGit(t)
	dir := t.TempDir()
	store, err := NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	id := "3f29f1de-6b3a-4b7e-9c9a-1a2b3c4d5e6f"
	first := Inkling{ID: id, Created: "2026-07-31T08:11:00Z", Updated: "2026-07-31T08:11:00Z", Text: "Rig a tide-powered charger."}
	created, err := store.Upsert(first, nil, "")
	if err != nil {
		t.Fatalf("Upsert (create): %v", err)
	}
	if !created {
		t.Errorf("expected created=true on first upsert")
	}

	entries, _ := os.ReadDir(dir)
	mdFiles := countMarkdown(entries)
	if mdFiles != 1 {
		t.Fatalf("expected 1 markdown file after create, got %d", mdFiles)
	}

	second := Inkling{ID: id, Created: first.Created, Updated: "2026-07-31T09:00:00Z", Text: "Rig a tide-powered charger for the buoy sensors, revised."}
	created, err = store.Upsert(second, nil, "")
	if err != nil {
		t.Fatalf("Upsert (update): %v", err)
	}
	if created {
		t.Errorf("expected created=false on second upsert (same id)")
	}

	entries, _ = os.ReadDir(dir)
	mdFiles = countMarkdown(entries)
	if mdFiles != 1 {
		t.Fatalf("expected still 1 markdown file after update (same filename reused), got %d", mdFiles)
	}

	list, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("expected 1 inkling in list, got %d", len(list))
	}
	if list[0].Text != second.Text {
		t.Errorf("expected updated text, got %q", list[0].Text)
	}
	if list[0].Updated != second.Updated {
		t.Errorf("expected updated timestamp to change, got %q", list[0].Updated)
	}

	// Two commits: one for the create, one for the update.
	out, err := exec.Command("git", "-C", dir, "log", "--oneline").CombinedOutput()
	if err != nil {
		t.Fatalf("git log: %v", err)
	}
	commitCount := len(strings.Split(strings.TrimSpace(string(out)), "\n"))
	if commitCount != 2 {
		t.Errorf("expected 2 commits, got %d:\n%s", commitCount, out)
	}
}

func TestUpsertWithAudioMarksHasAudio(t *testing.T) {
	requireGit(t)
	dir := t.TempDir()
	store, err := NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	ink := Inkling{ID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", Created: "2026-07-31T08:11:00Z", Updated: "2026-07-31T08:11:00Z", Text: "Idea with audio."}
	if _, err := store.Upsert(ink, []byte("fake audio bytes"), ".m4a"); err != nil {
		t.Fatalf("Upsert: %v", err)
	}

	list, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 || !list[0].HasAudio {
		t.Errorf("expected exactly one inkling with hasAudio=true, got %+v", list)
	}

	audioPath := filepath.Join(dir, "idea-with-audio-aaaaaaaa.m4a")
	if _, err := os.Stat(audioPath); err != nil {
		t.Errorf("expected audio file at %s: %v", audioPath, err)
	}
}

func TestUpsertConstrainsAudioExtensionToTheAllowlist(t *testing.T) {
	requireGit(t)
	dir := t.TempDir()
	store, err := NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	ink := Inkling{ID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", Created: "2026-07-31T08:11:00Z", Updated: "2026-07-31T08:11:00Z", Text: "Idea with audio."}
	if _, err := store.Upsert(ink, []byte("fake audio bytes"), "/../../escaped.sh"); err != nil {
		t.Fatalf("Upsert: %v", err)
	}

	entries, err := os.ReadDir(filepath.Dir(dir))
	if err != nil {
		t.Fatalf("read parent of storage dir: %v", err)
	}
	for _, e := range entries {
		if e.Name() != filepath.Base(dir) {
			t.Errorf("unexpected entry written outside the storage dir: %s", e.Name())
		}
	}

	audioPath := filepath.Join(dir, "idea-with-audio-aaaaaaaa.m4a")
	if _, err := os.Stat(audioPath); err != nil {
		t.Errorf("expected audio stored under an allowlisted extension at %s: %v", audioPath, err)
	}

	list, err := store.List()
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(list) != 1 || !list[0].HasAudio {
		t.Errorf("expected exactly one inkling with hasAudio=true, got %+v", list)
	}
}

func countMarkdown(entries []os.DirEntry) int {
	n := 0
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".md") {
			n++
		}
	}
	return n
}
