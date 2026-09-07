package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func newTestServer(t *testing.T) *Server {
	t.Helper()
	requireGit(t)
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	return &Server{store: store}
}

func multipartRequest(t *testing.T, fields map[string]string, audio []byte) *http.Request {
	t.Helper()
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	for k, v := range fields {
		if err := w.WriteField(k, v); err != nil {
			t.Fatalf("WriteField: %v", err)
		}
	}
	if audio != nil {
		part, err := w.CreateFormFile("audio", "utterance.m4a")
		if err != nil {
			t.Fatalf("CreateFormFile: %v", err)
		}
		if _, err := part.Write(audio); err != nil {
			t.Fatalf("write audio part: %v", err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/inklings", &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	return req
}

func TestHealthEndpoint(t *testing.T) {
	handler := (&Server{}).routes()

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal health response: %v", err)
	}
	if body["status"] != "ok" {
		t.Errorf("expected status %q, got %q", "ok", body["status"])
	}
	if body["version"] != Version {
		t.Errorf("expected version %q, got %q", Version, body["version"])
	}
}

func TestPostThenGetRoundTrip(t *testing.T) {
	server := newTestServer(t)
	handler := server.routes()

	req := multipartRequest(t, map[string]string{
		"id":      "3f29f1de-6b3a-4b7e-9c9a-1a2b3c4d5e6f",
		"created": "2026-07-31T08:11:00Z",
		"updated": "2026-07-31T08:11:00Z",
		"text":    "Rig a tide-powered charger for the buoy sensors.",
	}, []byte("fake-audio"))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var created map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if created["id"] != "3f29f1de-6b3a-4b7e-9c9a-1a2b3c4d5e6f" || created["syncedAt"] == "" {
		t.Errorf("unexpected create response: %+v", created)
	}

	listReq := httptest.NewRequest(http.MethodGet, "/inklings", nil)
	listRec := httptest.NewRecorder()
	handler.ServeHTTP(listRec, listReq)

	if listRec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", listRec.Code)
	}
	var inklings []Inkling
	if err := json.Unmarshal(listRec.Body.Bytes(), &inklings); err != nil {
		t.Fatalf("unmarshal list: %v", err)
	}
	if len(inklings) != 1 {
		t.Fatalf("expected 1 inkling, got %d", len(inklings))
	}
	if !inklings[0].HasAudio {
		t.Errorf("expected hasAudio=true")
	}
	if inklings[0].Text != "Rig a tide-powered charger for the buoy sensors." {
		t.Errorf("unexpected text: %q", inklings[0].Text)
	}
}

func TestPostSameIDTwiceUpdatesNotDuplicates(t *testing.T) {
	server := newTestServer(t)
	handler := server.routes()

	fields := map[string]string{
		"id":      "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
		"created": "2026-07-31T08:11:00Z",
		"updated": "2026-07-31T08:11:00Z",
		"text":    "First version.",
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, multipartRequest(t, fields, nil))
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201 on first post, got %d", rec.Code)
	}

	fields["text"] = "Revised version."
	fields["updated"] = "2026-07-31T09:00:00Z"
	rec2 := httptest.NewRecorder()
	handler.ServeHTTP(rec2, multipartRequest(t, fields, nil))
	if rec2.Code != http.StatusOK {
		t.Fatalf("expected 200 (upsert) on retry with same id, got %d", rec2.Code)
	}

	listRec := httptest.NewRecorder()
	handler.ServeHTTP(listRec, httptest.NewRequest(http.MethodGet, "/inklings", nil))
	var inklings []Inkling
	if err := json.Unmarshal(listRec.Body.Bytes(), &inklings); err != nil {
		t.Fatalf("unmarshal list: %v", err)
	}
	if len(inklings) != 1 {
		t.Fatalf("expected exactly 1 inkling after retrying same id, got %d", len(inklings))
	}
	if inklings[0].Text != "Revised version." {
		t.Errorf("expected latest text to win, got %q", inklings[0].Text)
	}
}

func TestPostRejectsIDsThatAreNotUUIDs(t *testing.T) {
	server := newTestServer(t)
	handler := server.routes()

	// The id becomes part of a filename, so anything that could steer a
	// write out of the storage directory must never reach the store.
	parent := filepath.Dir(server.store.dir)
	before, err := os.ReadDir(parent)
	if err != nil {
		t.Fatalf("read parent of storage dir: %v", err)
	}

	for _, id := range []string{"/../../escaped", "../escaped", "..", "not-a-uuid", "3f29f1de"} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, multipartRequest(t, map[string]string{
			"id":      id,
			"created": "2026-07-31T08:11:00Z",
			"updated": "2026-07-31T08:11:00Z",
			"text":    "Escape attempt.",
		}, []byte("fake-audio")))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("id %q: expected 400, got %d: %s", id, rec.Code, rec.Body.String())
		}
	}

	after, err := os.ReadDir(parent)
	if err != nil {
		t.Fatalf("re-read parent of storage dir: %v", err)
	}
	if len(after) != len(before) {
		t.Errorf("expected nothing written outside the storage dir, got %d new entries", len(after)-len(before))
	}
}

func TestDeleteExistingIDRemovesIt(t *testing.T) {
	server := newTestServer(t)
	handler := server.routes()

	id := "3f29f1de-6b3a-4b7e-9c9a-1a2b3c4d5e6f"
	postRec := httptest.NewRecorder()
	handler.ServeHTTP(postRec, multipartRequest(t, map[string]string{
		"id":      id,
		"created": "2026-07-31T08:11:00Z",
		"updated": "2026-07-31T08:11:00Z",
		"text":    "Rig a tide-powered charger for the buoy sensors.",
	}, nil))
	if postRec.Code != http.StatusCreated {
		t.Fatalf("expected 201 on create, got %d: %s", postRec.Code, postRec.Body.String())
	}

	delRec := httptest.NewRecorder()
	handler.ServeHTTP(delRec, httptest.NewRequest(http.MethodDelete, "/inklings/"+id, nil))
	if delRec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", delRec.Code, delRec.Body.String())
	}

	listRec := httptest.NewRecorder()
	handler.ServeHTTP(listRec, httptest.NewRequest(http.MethodGet, "/inklings", nil))
	var inklings []Inkling
	if err := json.Unmarshal(listRec.Body.Bytes(), &inklings); err != nil {
		t.Fatalf("unmarshal list: %v", err)
	}
	if len(inklings) != 0 {
		t.Fatalf("expected 0 inklings after delete, got %d", len(inklings))
	}
}

func TestDeleteUnknownIDReturns404(t *testing.T) {
	server := newTestServer(t)
	handler := server.routes()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodDelete, "/inklings/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDeleteRejectsNonUUIDID(t *testing.T) {
	server := newTestServer(t)
	handler := server.routes()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodDelete, "/inklings/not-a-uuid", nil))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDeleteWithAudioRemovesBothFiles(t *testing.T) {
	server := newTestServer(t)
	handler := server.routes()

	id := "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
	postRec := httptest.NewRecorder()
	handler.ServeHTTP(postRec, multipartRequest(t, map[string]string{
		"id":      id,
		"created": "2026-07-31T08:11:00Z",
		"updated": "2026-07-31T08:11:00Z",
		"text":    "Idea with audio.",
	}, []byte("fake-audio")))
	if postRec.Code != http.StatusCreated {
		t.Fatalf("expected 201 on create, got %d: %s", postRec.Code, postRec.Body.String())
	}

	audioPath := filepath.Join(server.store.dir, "idea-with-audio-aaaaaaaa.m4a")
	if _, err := os.Stat(audioPath); err != nil {
		t.Fatalf("expected audio file to exist before delete: %v", err)
	}
	mdPath := filepath.Join(server.store.dir, "idea-with-audio-aaaaaaaa.md")
	if _, err := os.Stat(mdPath); err != nil {
		t.Fatalf("expected markdown file to exist before delete: %v", err)
	}

	delRec := httptest.NewRecorder()
	handler.ServeHTTP(delRec, httptest.NewRequest(http.MethodDelete, "/inklings/"+id, nil))
	if delRec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", delRec.Code, delRec.Body.String())
	}

	if _, err := os.Stat(audioPath); !os.IsNotExist(err) {
		t.Errorf("expected audio file removed, stat err = %v", err)
	}
	if _, err := os.Stat(mdPath); !os.IsNotExist(err) {
		t.Errorf("expected markdown file removed, stat err = %v", err)
	}
}

func TestPostMissingFieldsRejected(t *testing.T) {
	server := newTestServer(t)
	handler := server.routes()

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, multipartRequest(t, map[string]string{
		"created": "2026-07-31T08:11:00Z",
		"updated": "2026-07-31T08:11:00Z",
		"text":    "Missing an id.",
	}, nil))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for missing id, got %d", rec.Code)
	}
}
