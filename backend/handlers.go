package main

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"path/filepath"
	"strings"
	"time"
)

type Server struct {
	store *Store
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /inklings", s.handleCreate)
	mux.HandleFunc("GET /inklings", s.handleList)
	return mux
}

// maxRequestBytes caps a single upload - a captured utterance plus its
// transcript, never anything close to this - so a hostile or broken client
// can't stream an unbounded body into memory, onto disk, and into git history.
const maxRequestBytes = 64 << 20

func (s *Server) handleCreate(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeError(w, http.StatusRequestEntityTooLarge, "request body too large")
			return
		}
		writeError(w, http.StatusBadRequest, "could not parse multipart form: "+err.Error())
		return
	}

	id := strings.TrimSpace(r.FormValue("id"))
	created := strings.TrimSpace(r.FormValue("created"))
	updated := strings.TrimSpace(r.FormValue("updated"))
	text := r.FormValue("text")

	if id == "" {
		writeError(w, http.StatusBadRequest, "id is required")
		return
	}
	if !isValidID(id) {
		writeError(w, http.StatusBadRequest, "id must be a UUID")
		return
	}
	if strings.TrimSpace(text) == "" {
		writeError(w, http.StatusBadRequest, "text is required")
		return
	}
	if _, err := time.Parse(time.RFC3339, created); err != nil {
		writeError(w, http.StatusBadRequest, "created must be RFC3339: "+err.Error())
		return
	}
	if _, err := time.Parse(time.RFC3339, updated); err != nil {
		writeError(w, http.StatusBadRequest, "updated must be RFC3339: "+err.Error())
		return
	}

	var audioBytes []byte
	var audioExt string
	if file, header, err := r.FormFile("audio"); err == nil {
		defer file.Close()
		audioBytes, err = io.ReadAll(file)
		if err != nil {
			writeError(w, http.StatusBadRequest, "could not read audio: "+err.Error())
			return
		}
		audioExt = filepath.Ext(header.Filename)
	}

	ink := Inkling{ID: id, Created: created, Updated: updated, Text: text}
	created2, err := s.store.Upsert(ink, audioBytes, audioExt)
	if err != nil {
		log.Printf("upsert %s: %v", id, err)
		writeError(w, http.StatusInternalServerError, "could not save inkling")
		return
	}

	status := http.StatusOK
	if created2 {
		status = http.StatusCreated
	}
	writeJSON(w, status, map[string]string{
		"id":       id,
		"syncedAt": time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	inklings, err := s.store.List()
	if err != nil {
		log.Printf("list: %v", err)
		writeError(w, http.StatusInternalServerError, "could not list inklings")
		return
	}
	if inklings == nil {
		inklings = []Inkling{}
	}
	writeJSON(w, http.StatusOK, inklings)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
