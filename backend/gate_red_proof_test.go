package main

import "testing"

// SCRATCH - deliberately failing test, used once to prove the shipping gate
// actually blocks. This branch is thrown away immediately afterwards; if you
// are reading this on any branch that is not fm/gate-red-proof, delete it.
func TestGateRedProofDeliberateFailure(t *testing.T) {
	t.Fatal("deliberate failure: proving inspector-gate blocks a red pull request")
}
