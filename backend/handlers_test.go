package main

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
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
