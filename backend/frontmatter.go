package main

import (
	"fmt"
	"strings"
)

// The front matter is exactly three scalar fields with no characters that
// need YAML quoting (UUIDs, RFC 3339 timestamps), so a hand-rolled
// line-based format avoids pulling in a YAML library for a three-field
// schema. If the schema ever grows past plain scalars, switch to a real
// parser instead of extending this.

func renderMarkdown(ink Inkling) string {
	var b strings.Builder
	b.WriteString("---\n")
	fmt.Fprintf(&b, "id: %s\n", ink.ID)
	fmt.Fprintf(&b, "created: %s\n", ink.Created)
	fmt.Fprintf(&b, "updated: %s\n", ink.Updated)
	b.WriteString("---\n\n")
	b.WriteString(ink.Text)
	if !strings.HasSuffix(ink.Text, "\n") {
		b.WriteString("\n")
	}
	return b.String()
}

func parseMarkdown(raw string) (Inkling, error) {
	lines := strings.Split(raw, "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return Inkling{}, fmt.Errorf("missing front matter delimiter")
	}

	fields := map[string]string{}
	i := 1
	for ; i < len(lines); i++ {
		line := lines[i]
		if strings.TrimSpace(line) == "---" {
			break
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		fields[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	if i >= len(lines) {
		return Inkling{}, fmt.Errorf("unterminated front matter")
	}

	body := strings.Join(lines[i+1:], "\n")
	body = strings.TrimPrefix(body, "\n")
	body = strings.TrimRight(body, "\n")

	ink := Inkling{
		ID:      fields["id"],
		Created: fields["created"],
		Updated: fields["updated"],
		Text:    body,
	}
	if ink.ID == "" {
		return Inkling{}, fmt.Errorf("front matter missing id")
	}
	return ink, nil
}
