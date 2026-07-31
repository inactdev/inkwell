// Command backend is Inkwell's local server: it receives a captured
// inkling as JSON+audio and writes it into a git repo as markdown. See
// docs/api-contract.md for the wire format and README.md for why Go.
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
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
	log.Printf("inkwell backend listening on %s, storage at %s", *addr, *storageDir)
	if err := http.ListenAndServe(*addr, server.routes()); err != nil {
		log.Fatal(err)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
