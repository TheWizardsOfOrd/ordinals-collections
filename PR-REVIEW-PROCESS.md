# PR Review Process

## Quick Start

```bash
cp .env.example .env
# Fill in SATFLOW_API_KEY

./scripts/review-pr.sh 13 14 15
# or with URLs:
./scripts/review-pr.sh https://github.com/TheWizardsOfOrd/ordinals-collections/pull/13
```

## Prerequisites

- `gh` CLI authenticated with repo access
- `curl`, `python3`
- Local ord server running at `http://0.0.0.0` (or set `ORD_BASE` in `.env`)
- Satflow API key in `.env` (see `.env.example`)

## What the Script Checks

For each PR, the script validates:

### Blocking (will prevent merge)

1. **PR must be open**
2. **CI checks** — both `validate` and `check-slugs` must pass
3. **New entries must exist** — the diff must contain parseable collection entries

### Informational (shown but won't block)

4. **Files changed** — warns if non-`collections.json` files are modified (they will be ignored at merge time)
5. **Inscription validity** — each inscription ID is checked against the local ord:
   - Gallery type: inscription must exist and have a `properties.gallery` field
   - Parent type: inscription must exist and have children
6. **ME cross-reference** — if the slug exists on Magic Eden (`api-mainnet.magiceden.us`):
   - Shows collection name and supply
   - Warns if the PR name doesn't match ME name
   - Spot-checks 3 ME items against the gallery inscription to verify they reference the same collection
7. **Satflow cross-reference** — if the slug exists on Satflow (`api.satflow.com`):
   - Shows collection name and supply
   - Warns on name mismatches
8. **Legacy verification** — if the slug exists in `legacy/collections.json`:
   - Loads the full item list from `legacy/collections/{slug}.json`
   - Gallery type: compares all legacy item IDs against the gallery inscription's items (full set comparison, reports match %)
   - Parent type: samples 5 random legacy items and verifies they are children of the submitted parent inscription(s) via ord

### Merge

After reviewing all PRs, the script lists eligible PRs and prompts `[y/N]` for each.

**Only `collections.json` entries are ever merged.** The script extracts new collection entries from the PR diff, applies them to main's current `collections.json` (sorted, formatted), and commits directly to main via the GitHub API. All other file changes in the PR are ignored. The PR is then closed with a comment linking the commit.

This means merge conflicts and non-data file changes never block — they're simply irrelevant.

## Manual Review Notes

Things the script cannot catch that require human judgment:

- **Unauthorized gallery inscriptions** — anyone can create a gallery inscription referencing existing items. For major collections, verify the inscription comes from the official team (check the inscription address against known creator addresses on ME).
- **Name choices** — a PR may use a shorter/different name than ME/Satflow. Decide if this is intentional or an error.
- **Bot/spam accounts** — check the PR author's GitHub profile if unfamiliar.
- **New collections (not on ME/Satflow)** — the script can only verify the inscription is valid. Legitimacy is up to you.

## API Reference

| Service | Endpoint | Auth |
|---------|----------|------|
| ME metadata | `GET /v2/ord/btc/collections/{slug}` | None |
| ME items | `GET /v2/ord/btc/tokens?collectionSymbol={slug}&limit=20&offset=0&sortBy=inscriptionNumberAsc&showAll=true` | None |
| Satflow | `GET /v1/collection?collection_id={slug}` | `x-api-key` header |
| Local ord | `GET /inscription/{id}` | None |
| Local ord children | `GET /children/{parentId}/{page}` | None |
