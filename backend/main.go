// Command backend is Inkwell's local server: it receives a captured
// inkling as JSON+audio and writes it into a git repo as markdown. See
// docs/api-contract.md for the wire format and README.md for why Go.
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	addr := flag.String("addr", envOr("INKWELL_ADDR", "127.0.0.1:8080"), "listen address")
	storageDir := flag.String("storage-dir", envOr("INKWELL_STORAGE_DIR", "./data"), "directory for the markdown git repo")
	flag.Parse()

	store, err := NewStore(*storageDir)
	if err != nil {
		log.Fatalf("could not open storage at %s: %v", *storageDir, err)
	}

	server := &Server{store: store}
	// Explicit timeouts rather than the zero-value server: the listen
	// address is configurable, so this can be reachable off-host and must
	// not let a stalled connection hold a request open indefinitely.
	httpServer := &http.Server{
		Addr:              *addr,
		Handler:           server.routes(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute,
		WriteTimeout:      1 * time.Minute,
		IdleTimeout:       2 * time.Minute,
	}

	log.Printf("inkwell backend listening on %s, storage at %s", *addr, *storageDir)
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
