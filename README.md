# Photo Signal

A private photo catalog for finding meaningful moments, searching natural language, and proposing albums from Apple Photos.

Two macOS apps share one local SQLite catalog:

| Product | Purpose |
| --- | --- |
| **Photo Signal** | Browse indexed months, inspect previews and metadata, search, ask AI to curate highlights, and create reviewed Photos albums. |
| **Photo Signal Indexer** | Menu-bar agent for recent-photo watching, explicit history backfills, checkpoints, budget tracking, and graceful pause/quit. |

Hover the menu-bar **Index** icon for live phase, saved/waiting/review counts, and estimated spending plus reserved costs. Click it for controls.

The viewer can be closed while the indexer works. A new indexer installation starts **paused**. Watching scans recent months every 15 minutes while the Mac is awake; backfill runs newest first from a year you choose. Unchanged successful analysis is reused. Failed or ambiguous requests are not automatically charged again.

## Build and install locally

Requires macOS, Xcode Command Line Tools, and Python 3.10+.

```sh
zsh scripts/setup-runtime.sh
zsh scripts/build-products.sh
python3 scripts/install-products.py
open "$HOME/Applications/Photo Signal.app"
open "$HOME/Applications/Photo Signal Indexer.app" --args --status
```

To install user-login startup for the indexer:

```sh
python3 scripts/install-products.py --login-only
```

This preserves the current pause/watch preference. It does not enable paid indexing on a new install. To remove startup without removing your catalog:

```sh
python3 scripts/install-products.py --remove-login
```

Installation keeps the previous app bundles as `.previous` copies in `~/Applications`. Existing catalog files remain under `~/Library/Application Support/PhotoSignal`. The previous combined prototype may be quit before starting these products; it should not run alongside the indexer.

## First run

1. Open Photo Signal Indexer and choose **Watch latest photos**, or **Backfill history…** for older years.
2. Approve macOS Photos access for the indexer. The viewer needs its own Photos permission when creating albums.
3. The Fireworks API credential must exist in your login Keychain as generic-password service `photosignal-fireworks`. Use Keychain Access; do not paste credentials into the repo, terminal history or an issue.
4. Open Photo Signal to browse. Use the indexed-month picker and **Refresh snapshot** to see new results. On a brand-new catalog, complete the first indexed month and build its snapshot with the command below.

```sh
"$HOME/Library/Application Support/PhotoSignal/benchmark-venv/bin/python" scripts/build_october_viewer.py --month YYYY-MM
```

The app builds an initial snapshot from the newest available indexed month automatically; the command above is also available for diagnostics.

The script/folder retain their prototype names for compatibility; the viewer supports other indexed months. A sparse or partially indexed month shows its successfully saved, current photos only.

## AI and privacy

Photos, previews, imported names, locations, captions and search data are private local files. **Do not commit runtime data.** Fireworks indexing sends a rendered small preview and classification prompt. Apple People fields and GPS are not sent by the indexer. Photos can themselves contain identifying information or text.

AI search sends the query to Fireworks to produce validated filters. **Choose best photos** optionally sends up to 60 small candidate previews with captions, dates, quality and favorite flags to compare visually and propose up to 25 picks. The dialog discloses that transfer. Each pick has a reason; time and token usage are saved. The model reviews a shortlist, not the entire library.

Collections remain local. Creating an Apple Photos album requires selecting results and explicitly submitting an album name. It adds references to existing assets; it does not copy, delete or edit originals. Apple may sync that album through your existing iCloud setup. Imported People labels reflect Apple's existing associations and can be incomplete or wrong.

## Operational limits

- One inference request at a time, 100 new photos per batch.
- Existing $35 cumulative estimated indexing cap, including earlier spending and unknown-request reservations.
- At least 2 GB free disk space; videos excluded.
- Pause persists across relaunch. Quit drains active work; sleep suspends progress.
- The viewer's optional AI requests have separate usage logs from the indexing budget.
- These are local ad-hoc signed builds, not notarized public releases. The indexer needs a logged-in macOS user and Photos permission. It is not a root daemon.

[Architecture and recovery](docs/architecture.md) describes checkpoints, deduplication, failure states, and remaining distribution requirements.

## Checks

```sh
python3 -m unittest discover -s tests
zsh scripts/build-products.sh
```

Tests use synthetic fixtures and mocked network calls; CI never accesses a real photo library. The repository contains source and contracts only. Private benchmark runs, curated personal selections, SQLite databases, app bundles and credentials stay outside Git.
