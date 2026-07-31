package main

import (
	"fmt"
	"regexp"
	"strings"
)

// Inkling is the wire and front-matter shape. Keep it minimal - see
// docs/api-contract.md for what's deliberately not here.
type Inkling struct {
	ID       string `json:"id"`
	Created  string `json:"created"`
	Updated  string `json:"updated"`
	Text     string `json:"text"`
	HasAudio bool   `json:"hasAudio"`
}

var nonWord = regexp.MustCompile(`[^a-z0-9]+`)

// uuidPattern is the id shape docs/api-contract.md declares. Enforcing it at
// the edge is what keeps `id` - which becomes part of a filename - from ever
// carrying a path separator or `..` into the storage directory.
var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func isValidID(id string) bool {
	return uuidPattern.MatchString(id)
}

// slugify turns the transcript into a short, human-readable filename
// fragment. It never changes for a given inkling once written - the id
// prefix appended by the caller is what keeps it unique.
func slugify(text string) string {
	lower := strings.ToLower(strings.TrimSpace(text))
	dashed := nonWord.ReplaceAllString(lower, "-")
	dashed = strings.Trim(dashed, "-")
	if dashed == "" {
		return "inkling"
	}

	const maxLen = 40
	if len(dashed) <= maxLen {
		return dashed
	}
	cut := dashed[:maxLen]
	if i := strings.LastIndex(cut, "-"); i > 0 {
		cut = cut[:i]
	}
	return strings.Trim(cut, "-")
}

func idPrefix(id string) string {
	clean := strings.ToLower(id)
	if len(clean) > 8 {
		clean = clean[:8]
	}
	return clean
}

func filenameBase(id, text string) string {
	return fmt.Sprintf("%s-%s", slugify(text), idPrefix(id))
}
