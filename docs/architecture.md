# Runtime and recovery

Photo Signal and Photo Signal Indexer are separate signed app bundles with separate macOS identities. They share `~/Library/Application Support/PhotoSignal`. The viewer never starts the historical coordinator. Closing the viewer does not stop an indexer request.

The indexer is a user-session menu-bar app, not a root daemon. PhotoKit requires an interactive macOS user's Photos permission; it cannot operate while logged out. It checks recent calendar months covering the last 90 days every 15 minutes while awake. Sleep suspends it. Backfill is explicit, newest month first, with a user-selected start year. After backfill it returns to watching recent months. Old edits outside the recent window need a backfill scan.

## Durable boundaries

- `history/settings.json`: desired watch/pause state, preserved across process restarts. Missing settings means paused. The earlier prototype's state is not permission to start charging.
- `history/state.json`: human-readable coordinator checkpoint. Month fingerprints include asset IDs, modification dates and favorite flags. A completed month is skipped only while its fingerprint agrees; an appended/edited asset reopens the month.
- `history/agent.lock`: lifetime singleton; `coordinator.lock`: export/coordinator ownership; `cloud-index/global-worker.lock`: one paid indexing worker across the whole catalog.
- Each monthly `run.sqlite`: job state and attempt ledger; SQLite WAL permits readers while indexing. Reuse requires compatible model/prompt/schema and unchanged asset version or verified preview bytes.
- Paid attempts reserve cost before dispatch. Interrupted/ambiguous requests become unknown and retain their reservation; they are never automatically charged again. User review is necessary to resolve them. Failed runs pause automatic scheduling rather than loop indefinitely.
- Pause stops scheduling and asks the monthly worker to drain. Normal Quit waits for the coordinator and its active request. A crash cannot guarantee a drain; unknown-request recovery covers that case.

## Limits

100 new requests per batch, concurrency one, a 2 GB free-disk floor, and the existing $35 cumulative estimated indexing ceiling. Historical spending counts toward that ceiling. Prices are configured estimates, not invoices. The optional viewer's search/curation usage is logged separately and is not part of that indexing ceiling. Videos are excluded. Unavailable previews and failed Apple People imports remain visible gaps; completing a range is not a guarantee of full coverage.

Python runs in the per-user runtime. Credentials are retrieved from Keychain, never written into app bundles or source. Photo pixels leave the Mac only for explicitly enabled Fireworks features. Existing Apple People associations are imported locally; no identities are inferred by the captioner. Personal files and generated reports never belong in Git.

The viewer opens a private cached snapshot and can refresh or switch to any indexed month. Rebuild reads the current SQLite state, verifies every displayed preview hash, excludes stale classifications, and replaces output files atomically. The webview reloads its asset allowlist only after a successful rebuild. Snapshot generation makes no model calls. A model cannot execute SQL or create a Photos album; album creation requires an explicit user action and allowlisted IDs.

## Distribution boundary

These are local developer builds, ad-hoc signed. macOS may ask again for Photos permission after rebuilding. Stable cross-machine distribution still needs an Apple Developer certificate, hardened runtime/notarization testing and a release signing process. The login launcher is optional and removable; no root service or network listener is installed.
