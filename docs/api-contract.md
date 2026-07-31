# API contract

This is the interface between the iOS app and the local backend. Treat it as load-bearing:
later lanes depend on these shapes. Changing it means updating both sides and this doc together.

## Identity

`id` is a UUID (v4), generated once on the phone at capture time, and never changes. It's the
only identity that exists - the markdown filename is a human-readable slug, generated once at
first sync and never renamed afterward, even if the text is edited later. Nothing looks up an
inkling by filename; the backend finds files by scanning front matter for a matching `id`.

## The inkling JSON shape

Sent by the phone and returned by the backend in list responses:

```json
{
  "id": "3F29F1DE-6B3A-4B7E-9C9A-1A2B3C4D5E6F",
  "created": "2026-07-31T08:11:00Z",
  "updated": "2026-07-31T08:11:00Z",
  "text": "Rig a tide-powered charger for the buoy sensors so they never need a battery run.",
  "hasAudio": true
}
```

- `id` - UUID string, uppercase or lowercase accepted, stored as given. The backend rejects
  anything that isn't UUID-shaped with a `400`: the id becomes part of a filename, so it is never
  allowed to carry a path separator.
- `created` / `updated` - RFC 3339 / ISO 8601 UTC timestamps (`2026-07-31T08:11:00Z`).
- `text` - the full transcript, as edited on the phone. This is the inkling's body.
- `hasAudio` - whether an utterance recording accompanies this inkling. Response-only field;
  the request instead includes (or omits) the actual audio file, see below.

No other fields exist. In particular: no `title` (derived from `text` by whoever's displaying
it, never stored), no `building`/`shipped`/`cold`/tags/status - those are explicitly deferred to
later lanes and derived from other signals, never captured or stored here.

## Endpoints

### `POST /inklings` - create or update an inkling

`multipart/form-data` body:

| Part      | Required | Contents                                          |
|-----------|----------|----------------------------------------------------|
| `id`      | yes      | UUID string                                         |
| `created` | yes      | RFC 3339 timestamp                                  |
| `updated` | yes      | RFC 3339 timestamp                                  |
| `text`    | yes      | UTF-8 transcript                                    |
| `audio`   | no       | The utterance recording (`.m4a`/`.caf`), raw bytes  |

**Upsert by id, not create-only.** If an inkling with this `id` already exists on the backend,
this call overwrites its text/timestamps/audio in place (same file, same filename) rather than
creating a duplicate. This makes the call safe to retry: a phone that sent the request but never
saw the response (dropped connection, backend restarted mid-request) can just send it again.

Response: `200 OK` (updated) or `201 Created` (new), JSON body:

```json
{ "id": "3F29F1DE-6B3A-4B7E-9C9A-1A2B3C4D5E6F", "syncedAt": "2026-07-31T08:12:03Z" }
```

`syncedAt` is the backend's clock, not the phone's - the phone stores this as the local
"confirmed synced" timestamp for that inkling, which is what clears the "not yet synced"
indicator.

Errors: `400` for a malformed request (missing required part, unparseable timestamp, empty
`id`/`text`, an `id` that isn't a UUID). `413` if the body exceeds 64 MiB, far above any real
capture. `5xx` for anything on the backend's side (disk full, git failure, etc.) - the phone
treats both `5xx` and a failed connection identically: leave the inkling unsynced and retry later.

### `GET /inklings` - list everything the backend has

Response: `200 OK`, a JSON array of the inkling shape above, newest `created` first:

```json
[
  { "id": "...", "created": "...", "updated": "...", "text": "...", "hasAudio": true },
  { "id": "...", "created": "...", "updated": "...", "text": "...", "hasAudio": false }
]
```

No pagination, no filtering - this lane's list view and the skeleton's data volume don't need
it (the contract's own decade-ceiling measurement is 2.7MB / a few thousand files; a full
directory scan per request is fast enough not to need an index). A future lane building the real
browse experience may want to add query params here; that's additive, not a breaking change.

There's no dedicated health-check endpoint, and the sync engine never probes one. It learns
reachability two ways: `NWPathMonitor` tells it when the device has a network path at all, and
the outcome of each `POST /inklings` tells it whether the backend answered. A refused connection,
a timeout, and a `5xx` are all treated identically to being offline - leave the inkling unsynced
and try again on the next pass.

## Offline and retry semantics

**Capture never waits on any of this.** The phone writes the inkling to disk the instant "Done"
is tapped, fully offline, before any network call is attempted. Sync happens strictly after,
opportunistically, and is allowed to fail silently from the owner's perspective - the only
visible trace is the "not yet synced" indicator in the list, not an error or a retry prompt.

The phone's sync loop (see `ios/Inkwell/Sync/SyncCoordinator.swift`):

- Runs on app launch, on the app becoming active, on a 20-second timer while active, and
  immediately after each new capture is saved (best-effort - if there's no network, this attempt
  just fails quietly and the timer picks it up later).
- Also triggers on a network path change from unreachable to reachable (via `NWPathMonitor`), so
  a phone that regains signal doesn't have to wait for the next timer tick.
- For each unsynced inkling (`syncedAt == nil`), `POST`s it. On success, stores the returned
  `syncedAt` and re-saves the on-device record - this clears its "not yet synced" indicator. On
  failure, leaves it exactly as it was; the next sync pass tries again. No backoff, no retry
  limit, no error surfaced to the owner - "quiet count, never an alarm" per the product contract.
- This is foreground-only sync. The skeleton does not register a background task or request
  background network entitlements - if the app is fully backgrounded or killed, sync resumes the
  next time it's opened. This is a known limitation worth revisiting once background capture
  (the App Intent / widget "capture door") exists in a later lane.

## Markdown front matter

Exactly what the backend writes to `<storage-dir>/<slug>-<id-prefix>.md`:

```markdown
---
id: 3f29f1de-6b3a-4b7e-9c9a-1a2b3c4d5e6f
created: 2026-07-31T08:11:00Z
updated: 2026-07-31T08:11:00Z
---

Rig a tide-powered charger for the buoy sensors so they never need a battery run.
```

- Three front-matter fields, nothing else: `id`, `created`, `updated`. No `title` (the first
  line of the body is the title, if anyone needs one), no tags, no status. A person opening this
  file in ten years with none of this code should be able to read it as plainly as a text file
  with a date on it.
- `<slug>` is derived from `text` once, at first sync: lowercased, ASCII-only, hyphenated, first
  few words, capped around 40 characters. It never changes on later updates to the same `id`,
  even if the text does - the filename is a label, not a lookup key.
- `<id-prefix>` is the first 8 characters of `id`, appended so two inklings with a similar
  opening phrase don't collide on filename.
- If audio was sent, it's written alongside as `<slug>-<id-prefix>.m4a` in the same directory.
  The extension the phone sent is honored only if it's one the backend recognizes (`.m4a`,
  `.caf`, `.wav`); anything else is stored as `.m4a`, since the extension lands in a path.
- Every write is followed by a `git add` + `git commit` in the storage directory (which the
  backend `git init`s on first run if it isn't already a repo). One commit per `POST`.

## Configuration

Both the storage path and the listen address are configurable (flags or env vars - see
`backend/README.md`), never hardcoded, so moving from a local dev backend to a VPS is a config
change, not a code change, per the product contract.
