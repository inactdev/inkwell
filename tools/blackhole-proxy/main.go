// Command blackhole-proxy is test-only infrastructure for
// OfflineSyncUITests (see ios/InkwellUITests/OfflineSyncUITests.swift and
// dev.sh's "ios test"): a raw TCP proxy that black-holes every connection
// accepted during a fixed window - accepted, then never read, written to,
// or closed - so the client's own request timeout is the only thing that
// can end it. Such a connection is never forwarded, not even once the
// window elapses: a dropped mobile connection doesn't resume mid-request
// when signal returns either, a fresh retry opens a new one. Connections
// accepted after the window are proxied straight through to the real
// backend. Standard library only, matching the rest of this repo.
//
// The window is measured from the *first connection accepted*, not from
// process start: dev.sh launches this before xcodebuild test, whose own
// build+install+launch time is highly variable (AGENTS.md: "tens of
// seconds is normal, over a minute is not unusual") and would otherwise
// eat into - or entirely consume - a fixed startup-relative window before
// the app ever makes its first request, letting it through by accident.
package main

import (
	"flag"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

func main() {
	listen := flag.String("listen", "", "address to listen on")
	upstream := flag.String("upstream", "", "address to forward to once the hold-for window elapses")
	holdFor := flag.Duration("hold-for", 20*time.Second, "how long to black-hole connections, measured from the first one accepted")
	flag.Parse()

	if *listen == "" || *upstream == "" {
		log.Fatal("-listen and -upstream are required")
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("blackhole-proxy listening on %s, forwarding to %s starting %s after the first connection", ln.Addr(), *upstream, *holdFor)

	var mu sync.Mutex
	var opensAt time.Time // zero until the first connection arrives

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Fatal(err)
		}

		mu.Lock()
		if opensAt.IsZero() {
			opensAt = time.Now().Add(*holdFor)
		}
		deadline := opensAt
		mu.Unlock()

		go handle(conn, *upstream, deadline)
	}
}

// A connection accepted before opensAt is held open and untouched - never
// read, never written to, never closed - so the client's own timeout is what
// ends it, not a refusal, an early close, or a late reply. One accepted
// after opensAt is proxied immediately, byte for byte, in both directions.
func handle(conn net.Conn, upstream string, opensAt time.Time) {
	if time.Now().Before(opensAt) {
		// Genuine black hole: never resolves this connection at all - the
		// client's own timeout is what has to end it. (A real dropped
		// connection doesn't resume mid-request either; a retry opens a
		// fresh one.) The proxy process is short-lived (one test run), so
		// parking the goroutine is fine.
		select {}
	}

	defer conn.Close()
	up, err := net.Dial("tcp", upstream)
	if err != nil {
		return
	}
	defer up.Close()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(up, conn) }()
	go func() { defer wg.Done(); io.Copy(conn, up) }()
	wg.Wait()
}
