#!/usr/bin/env bash
set -euo pipefail

# Review and merge ordinals-collections PRs
# Usage: ./scripts/review-pr.sh <PR number or URL> [<PR> ...]
#
# Requires: gh, curl, python3
# Config:   .env file in repo root (see .env.example) or env vars:
#           - SATFLOW_API_KEY  (required for Satflow checks)
#           - ORD_BASE         (default: http://0.0.0.0)
#
# Validates each PR:
#   1. CI checks pass
#   2. New entries have valid inscriptions on local ord
#   3. Slugs matching ME/Satflow have consistent data
#   4. Gallery items spot-checked against ME
#   5. Legacy item-level verification when available
# Then asks for confirmation before merging each PR.
#
# Merge strategy: only collections.json entries are applied to main.
# All other file changes in the PR are ignored. Merge conflicts are
# irrelevant since entries are applied directly. PRs are closed after.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="${SCRIPT_DIR}/../.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

REPO="TheWizardsOfOrd/ordinals-collections"
ORD_BASE="${ORD_BASE:-http://0.0.0.0}"
ME_API="https://api-mainnet.magiceden.us"
SATFLOW_API="https://api.satflow.com/v1"
SATFLOW_KEY="${SATFLOW_API_KEY:-}"
SPOT_CHECK_COUNT=3

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

pass() { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; }
info() { echo -e "  ${DIM}$1${RESET}"; }
header() { echo -e "\n${BOLD}${CYAN}── $1${RESET}"; }

# Extract PR number from URL or plain number
parse_pr_number() {
  local input="$1"
  if [[ "$input" =~ /pull/([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$input" =~ ^[0-9]+$ ]]; then
    echo "$input"
  else
    echo ""
  fi
}

# Fetch JSON and cache it for the session
declare -A CACHE
cached_fetch() {
  local url="$1"
  if [[ -z "${CACHE[$url]+x}" ]]; then
    CACHE[$url]=$(curl -sf "$url" -H 'Accept: application/json' 2>/dev/null || echo "")
  fi
  echo "${CACHE[$url]}"
}

# Get new entries added by a PR compared to main
get_new_entries() {
  local pr_number="$1"
  local diff
  diff=$(gh pr diff "$pr_number" --repo "$REPO" 2>/dev/null)

  # Extract added JSON blocks from collections.json diff
  echo "$diff" | python3 -c "
import sys, json, re

diff = sys.stdin.read()
# Only look at collections.json changes
in_collections = False
added_lines = []

for line in diff.split('\n'):
    if line.startswith('diff --git'):
        in_collections = 'collections.json' in line
        continue
    if in_collections and line.startswith('+') and not line.startswith('+++'):
        added_lines.append(line[1:])

if not added_lines:
    sys.exit(0)

# Parse the added JSON fragments
text = '\n'.join(added_lines)
# Try to find complete JSON objects
objects = []
depth = 0
start = -1
for i, ch in enumerate(text):
    if ch == '{':
        if depth == 0:
            start = i
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0 and start >= 0:
            try:
                obj = json.loads(text[start:i+1])
                objects.append(obj)
            except json.JSONDecodeError:
                pass
            start = -1

print(json.dumps(objects))
" 2>/dev/null
}

# Check if PR only modifies collections.json
check_files_changed() {
  local pr_number="$1"
  local files
  files=$(gh pr view "$pr_number" --repo "$REPO" --json files -q '.files[].path' 2>/dev/null)
  local bad_files=""

  while IFS= read -r file; do
    if [[ "$file" != "collections.json" ]]; then
      bad_files="${bad_files}${file} "
    fi
  done <<< "$files"

  if [[ -n "$bad_files" ]]; then
    echo "$bad_files"
    return 1
  fi
  return 0
}

# Check ME for a slug
check_me() {
  local slug="$1"
  local data
  data=$(cached_fetch "${ME_API}/v2/ord/btc/collections/${slug}")
  if [[ -n "$data" ]] && echo "$data" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('symbol')" 2>/dev/null; then
    echo "$data"
    return 0
  fi
  return 1
}

# Check Satflow for a slug
check_satflow() {
  local slug="$1"
  if [[ -z "$SATFLOW_KEY" ]]; then
    return 1
  fi
  local data
  data=$(curl -sf "${SATFLOW_API}/collection?collection_id=${slug}" \
    -H "x-api-key: ${SATFLOW_KEY}" \
    -H 'Accept: application/json' 2>/dev/null || echo "")
  if [[ -n "$data" ]] && echo "$data" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('success') and d['data']['collection']" 2>/dev/null; then
    echo "$data"
    return 0
  fi
  return 1
}

# Check local ord for an inscription
check_ord() {
  local inscription_id="$1"
  cached_fetch "${ORD_BASE}/inscription/${inscription_id}"
}

# Get ME items for spot-checking
get_me_items() {
  local slug="$1"
  local count="${2:-$SPOT_CHECK_COUNT}"
  local data
  data=$(cached_fetch "${ME_API}/v2/ord/btc/tokens?collectionSymbol=${slug}&limit=20&offset=0&sortBy=inscriptionNumberAsc&showAll=true")
  if [[ -n "$data" ]]; then
    echo "$data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tokens = data.get('tokens', data) if isinstance(data, dict) else data
if isinstance(tokens, list):
    for t in tokens[:${count}]:
        print(t['id'])
" 2>/dev/null
  fi
}

# Spot-check gallery items against ME
spot_check_gallery() {
  local inscription_id="$1"
  local slug="$2"
  local ord_data me_items matched total

  ord_data=$(check_ord "$inscription_id")
  if [[ -z "$ord_data" ]]; then
    fail "Could not fetch inscription from ord"
    return 1
  fi

  me_items=$(get_me_items "$slug" "$SPOT_CHECK_COUNT")
  if [[ -z "$me_items" ]]; then
    info "No ME items to spot-check (collection may not be on ME)"
    return 0
  fi

  matched=0
  total=0
  while IFS= read -r item_id; do
    [[ -z "$item_id" ]] && continue
    total=$((total + 1))
    if echo "$ord_data" | grep -q "$item_id"; then
      matched=$((matched + 1))
    fi
  done <<< "$me_items"

  if [[ "$total" -eq 0 ]]; then
    info "No ME items to spot-check"
    return 0
  fi

  if [[ "$matched" -eq "$total" ]]; then
    pass "Gallery spot-check: ${matched}/${total} ME items found in gallery"
    return 0
  else
    fail "Gallery spot-check: only ${matched}/${total} ME items found in gallery"
    return 1
  fi
}

# Check legacy collections for a slug
check_legacy() {
  local slug="$1"
  local legacy_index="${SCRIPT_DIR}/../legacy/collections.json"

  if [[ -f "$legacy_index" ]] && grep -q "\"symbol\": \"${slug}\"" "$legacy_index" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Verify submitted inscription data against legacy item file
# For gallery: compare legacy IDs against gallery inscription items
# For parent: sample legacy IDs and verify they are children of the parent(s)
verify_legacy() {
  local slug="$1"
  local entry_type="$2"
  local entry_id="$3"       # gallery inscription id
  local entry_ids="$4"      # comma-separated parent ids

  local legacy_items="${SCRIPT_DIR}/../legacy/collections/${slug}.json"
  if [[ ! -f "$legacy_items" ]]; then
    warn "Legacy index has slug but no item file at legacy/collections/${slug}.json"
    return 0
  fi

  if [[ "$entry_type" == "gallery" ]]; then
    verify_legacy_gallery "$slug" "$entry_id" "$legacy_items"
  elif [[ "$entry_type" == "parent" ]]; then
    verify_legacy_parent "$slug" "$entry_ids" "$legacy_items"
  fi
}

verify_legacy_gallery() {
  local slug="$1"
  local inscription_id="$2"
  local legacy_file="$3"

  local ord_url="${ORD_BASE}/inscription/${inscription_id}"

  python3 -c "
import json, sys, urllib.request

legacy_file = '${legacy_file}'
ord_url = '${ord_url}'

# Load legacy IDs
with open(legacy_file) as f:
    legacy_items = json.load(f)
legacy_ids = set(item['id'] for item in legacy_items)

# Fetch gallery inscription from ord
req = urllib.request.Request(ord_url, headers={'Accept': 'application/json'})
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        ord_data = json.load(resp)
except Exception as e:
    print(f'ERROR|Could not fetch inscription from ord: {e}')
    sys.exit(0)

gallery = ord_data.get('properties', {}).get('gallery', [])
gallery_ids = set(item['id'] for item in gallery)

if not gallery_ids:
    print('ERROR|Gallery inscription has no items')
    sys.exit(0)

matched = legacy_ids & gallery_ids
in_legacy_not_gallery = legacy_ids - gallery_ids
in_gallery_not_legacy = gallery_ids - legacy_ids

pct = len(matched) / len(legacy_ids) * 100 if legacy_ids else 0

if in_legacy_not_gallery:
    if pct >= 95:
        print(f'WARN|Legacy match: {len(matched)}/{len(legacy_ids)} items ({pct:.0f}%), {len(in_legacy_not_gallery)} legacy items not in gallery')
    else:
        print(f'FAIL|Legacy mismatch: only {len(matched)}/{len(legacy_ids)} items ({pct:.0f}%), {len(in_legacy_not_gallery)} legacy items not in gallery')
else:
    if in_gallery_not_legacy:
        print(f'WARN|Legacy match: {len(matched)}/{len(legacy_ids)} items (100%), but gallery has {len(in_gallery_not_legacy)} extra items not in legacy')
    else:
        print(f'PASS|Legacy match: {len(matched)}/{len(legacy_ids)} items (100%)')
" 2>/dev/null
}

_print_legacy_result() {
  local level="$1" msg="$2"
  case "$level" in
    PASS) pass "$msg" ;;
    WARN) warn "$msg" ;;
    FAIL) fail "$msg" ;;
    ERROR) fail "$msg" ;;
  esac
}

verify_legacy_parent() {
  local slug="$1"
  local entry_ids="$2"
  local legacy_file="$3"
  local sample_size=5

  python3 -c "
import json, sys, urllib.request, random

legacy_file = '${legacy_file}'
ord_base = '${ORD_BASE}'
parent_ids = '${entry_ids}'.split(',')
sample_size = ${sample_size}

with open(legacy_file) as f:
    legacy_items = json.load(f)
legacy_ids = [item['id'] for item in legacy_items]

sample = random.sample(legacy_ids, min(sample_size, len(legacy_ids)))
matched = 0

for item_id in sample:
    url = f'{ord_base}/inscription/{item_id}'
    req = urllib.request.Request(url, headers={'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.load(resp)
        item_parents = set(data.get('parents', []))
        if item_parents & set(parent_ids):
            matched += 1
    except Exception:
        pass

total = len(sample)
if matched == total:
    print(f'PASS|Legacy sample: {matched}/{total} items confirmed as children (of {len(legacy_ids)} total)')
elif matched > 0:
    print(f'WARN|Legacy sample: {matched}/{total} items are children, {total - matched} are not')
else:
    print(f'FAIL|Legacy sample: 0/{total} items are children of the submitted parents')
" 2>/dev/null | while IFS='|' read -r level msg; do
    case "$level" in
      PASS) pass "$msg" ;;
      WARN) warn "$msg" ;;
      FAIL) fail "$msg" ;;
    esac
  done
}

# Apply only the collections.json entries from a PR directly to main.
# This is the sole merge mechanism — it never touches other files.
# Returns 0 on success, 1 on failure. Outputs the commit URL on success.
apply_collection_entries() {
  local pr_number="$1"
  local new_entries="$2"
  local commit_msg="$3"

  # Get main's current collections.json and its SHA
  local file_meta main_content file_sha
  file_meta=$(gh api "repos/${REPO}/contents/collections.json" 2>/dev/null)
  main_content=$(echo "$file_meta" | python3 -c "import sys,json,base64; print(base64.b64decode(json.load(sys.stdin)['content']).decode())")
  file_sha=$(echo "$file_meta" | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])")

  if [[ -z "$file_sha" ]]; then
    return 1
  fi

  local tmp_main tmp_new tmp_out
  tmp_main=$(mktemp)
  tmp_new=$(mktemp)
  tmp_out=$(mktemp)
  echo "$main_content" > "$tmp_main"
  echo "$new_entries" > "$tmp_new"

  node -e "
const fs = require('fs');
const main = JSON.parse(fs.readFileSync('${tmp_main}', 'utf8'));
const added = JSON.parse(fs.readFileSync('${tmp_new}', 'utf8'));
const slugs = new Set(main.map(e => e.slug));
let count = 0;
for (const entry of added) {
  if (!slugs.has(entry.slug)) { main.push(entry); count++; }
}
if (count === 0) { process.exit(1); }
for (const e of main) { e.name = e.name.trim(); }
main.sort((a, b) => a.name.localeCompare(b.name));
fs.writeFileSync('${tmp_out}', JSON.stringify(main, null, 2) + '\n');
"

  if [[ $? -ne 0 ]]; then
    rm -f "$tmp_main" "$tmp_new" "$tmp_out"
    return 1
  fi

  local encoded
  if [[ "$(uname)" == "Darwin" ]]; then
    encoded=$(base64 -b 0 < "$tmp_out")
  else
    encoded=$(base64 -w 0 < "$tmp_out")
  fi
  rm -f "$tmp_main" "$tmp_new" "$tmp_out"

  # Commit directly to main
  local result
  result=$(gh api "repos/${REPO}/contents/collections.json" \
    -X PUT \
    -f message="${commit_msg}" \
    -f content="$encoded" \
    -f sha="$file_sha" \
    -f branch="main" 2>&1)

  if [[ $? -ne 0 ]]; then
    return 1
  fi

  # Output the commit URL
  echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['commit']['html_url'])" 2>/dev/null
  return 0
}

# ── Main review logic for one PR ──

review_pr() {
  local pr_number="$1"
  local pr_ok=true
  local has_warnings=false
  local blocking_issues=""
  local serious_warnings=""

  header "PR #${pr_number}"

  # Fetch PR metadata
  local pr_json
  pr_json=$(gh pr view "$pr_number" --repo "$REPO" --json title,state,author 2>/dev/null)
  if [[ -z "$pr_json" ]]; then
    fail "Could not fetch PR #${pr_number}"
    return 1
  fi

  local title state author
  title=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['title'])")
  state=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
  author=$(echo "$pr_json" | python3 -c "import sys,json; print(json.load(sys.stdin)['author']['login'])")

  info "${title} (by ${author})"

  if [[ "$state" != "OPEN" ]]; then
    fail "PR is ${state}, not OPEN"
    return 1
  fi

  # 1. Check which files are changed (informational — we only merge collections.json regardless)
  local bad_files
  if bad_files=$(check_files_changed "$pr_number"); then
    pass "Only collections.json modified"
  else
    warn "Also modifies: ${bad_files}(only collections.json changes will be merged)"
  fi

  # 2. CI checks
  local checks_output checks_rc
  checks_rc=0
  checks_output=$(gh pr checks "$pr_number" --repo "$REPO" 2>&1) || checks_rc=$?
  if echo "$checks_output" | grep -q "no checks reported"; then
    warn "No CI checks reported (first-time contributor — may need manual approval)"
  elif [[ $checks_rc -ne 0 ]]; then
    local failed_checks
    failed_checks=$(echo "$checks_output" | grep -v "^$" | grep -v "pass" || true)
    fail "CI checks failing:"
    echo "$failed_checks" | while IFS= read -r line; do info "  $line"; done
    blocking_issues="${blocking_issues}\n  - CI check failure"
    pr_ok=false
  else
    pass "CI checks pass"
  fi

  # 4. Parse new entries
  local new_entries
  new_entries=$(get_new_entries "$pr_number")
  if [[ -z "$new_entries" || "$new_entries" == "[]" ]]; then
    warn "No new collection entries detected in diff"
    return 0
  fi

  local entry_count
  entry_count=$(echo "$new_entries" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
  info "Found ${entry_count} new collection entries"

  # 5. Validate each new entry
  while IFS=$'\t' read -r slug name entry_type entry_id entry_ids; do
    [[ "$entry_id" == "-" ]] && entry_id=""
    [[ "$entry_ids" == "-" ]] && entry_ids=""
    echo ""
    echo -e "  ${BOLD}${slug}${RESET} — \"${name}\" (${entry_type})"
    if [[ "$entry_type" == "gallery" ]]; then
      info "id: ${ORD_BASE}/inscription/${entry_id}"
    elif [[ "$entry_type" == "parent" ]]; then
      IFS=',' read -ra _pids <<< "$entry_ids"
      for _pid in "${_pids[@]}"; do
        info "parent: ${ORD_BASE}/inscription/${_pid}"
      done
    fi

    # Check inscription on local ord
    local gallery_count=0
    if [[ "$entry_type" == "gallery" ]]; then
      local ord_data
      ord_data=$(check_ord "$entry_id")
      if [[ -z "$ord_data" ]]; then
        fail "Inscription ${entry_id:0:16}... not found on local ord"
      else
        gallery_count=$(echo "$ord_data" | python3 -c "
import sys,json
d=json.load(sys.stdin)
g=d.get('properties',{}).get('gallery',[])
print(len(g) if isinstance(g,list) else 0)
" 2>/dev/null)
        if [[ "$gallery_count" -gt 0 ]]; then
          pass "Valid gallery inscription on chain (${gallery_count} items)"
        else
          fail "Inscription exists but has no gallery property"
        fi
      fi
    elif [[ "$entry_type" == "parent" ]]; then
      IFS=',' read -ra parent_ids <<< "$entry_ids"
      for pid in "${parent_ids[@]}"; do
        local ord_data
        ord_data=$(check_ord "$pid")
        if [[ -z "$ord_data" ]]; then
          fail "Parent ${pid:0:16}... not found on local ord"
        else
          local child_count
          child_count=$(echo "$ord_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('child_count',0))" 2>/dev/null)
          if [[ "$child_count" -gt 0 ]]; then
            pass "Parent ${pid:0:16}... has ${child_count} children"
          else
            warn "Parent ${pid:0:16}... has 0 children on local ord"
          fi
        fi
      done
    fi

    # Check ME
    local me_data
    if me_data=$(check_me "$slug"); then
      local me_name me_supply
      me_name=$(echo "$me_data" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
      me_supply=$(echo "$me_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('supply','?'))")
      pass "Found on ME: \"${me_name}\" (${me_supply} items)"

      if [[ "$me_name" != "$name" ]]; then
        warn "Name mismatch: PR=\"${name}\" vs ME=\"${me_name}\""
      fi

      # Compare gallery size vs ME supply
      if [[ "$entry_type" == "gallery" && "$gallery_count" -gt 0 && "$me_supply" != "?" ]]; then
        if [[ "$gallery_count" -gt "$me_supply" ]]; then
          local extra=$(( gallery_count - me_supply ))
          warn "Gallery has ${gallery_count} items but ME supply is ${me_supply} (${extra} extra items)"
          has_warnings=true
          serious_warnings="${serious_warnings}\n  - Gallery has ${extra} more items than ME supply"
        elif [[ "$gallery_count" -lt "$me_supply" ]]; then
          local missing=$(( me_supply - gallery_count ))
          warn "Gallery has ${gallery_count} items but ME supply is ${me_supply} (${missing} missing)"
          has_warnings=true
          serious_warnings="${serious_warnings}\n  - Gallery is missing ${missing} items vs ME supply"
        fi
      fi

      # Spot-check gallery items
      if [[ "$entry_type" == "gallery" ]]; then
        spot_check_gallery "$entry_id" "$slug"
      fi
    else
      info "Not found on ME"
    fi

    # Check Satflow
    local sf_data
    if sf_data=$(check_satflow "$slug"); then
      local sf_name sf_supply
      sf_name=$(echo "$sf_data" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['collection'][0]['name'])")
      sf_supply=$(echo "$sf_data" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['collection'][0].get('total_items','?'))")
      pass "Found on Satflow: \"${sf_name}\" (${sf_supply} items)"

      if [[ "$sf_name" != "$name" ]]; then
        warn "Name mismatch: PR=\"${name}\" vs Satflow=\"${sf_name}\""
      fi
    else
      info "Not found on Satflow"
    fi

    # Check legacy
    if check_legacy "$slug"; then
      info "Exists in legacy collections (migrating to new format)"
      local legacy_output
      legacy_output=$(verify_legacy "$slug" "$entry_type" "$entry_id" "$entry_ids")
      while IFS='|' read -r level msg; do
        _print_legacy_result "$level" "$msg"
        if [[ "$level" == "WARN" || "$level" == "FAIL" ]]; then
          has_warnings=true
          serious_warnings="${serious_warnings}\n  - ${msg}"
        fi
      done <<< "$legacy_output"
    fi
  done < <(echo "$new_entries" | python3 -c "
import sys, json
for entry in json.load(sys.stdin):
    slug = entry.get('slug', '')
    name = entry.get('name', '')
    entry_type = entry.get('type', '')
    entry_id = entry.get('id', '-')
    entry_ids = ','.join(entry.get('ids', [])) or '-'
    print(f'{slug}\t{name}\t{entry_type}\t{entry_id}\t{entry_ids}')
")

  echo ""

  # Final verdict
  if [[ "$pr_ok" == false ]]; then
    echo -e "  ${RED}${BOLD}BLOCKED${RESET} — cannot merge:${blocking_issues}"
    return 1
  fi

  if [[ "$has_warnings" == true ]]; then
    echo -e "  ${YELLOW}${BOLD}WARNINGS${RESET} — review carefully before merging:${serious_warnings}"
    return 2
  fi

  return 0
}

# ── Entry point ──

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <PR number or URL> [<PR> ...]"
  echo "Example: $0 13 14 https://github.com/TheWizardsOfOrd/ordinals-collections/pull/15"
  exit 1
fi

# Verify prerequisites
for cmd in gh curl python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: ${cmd} is required but not installed."
    exit 1
  fi
done

# Check local ord is reachable
if ! curl -sf "${ORD_BASE}/status" -H 'Accept: application/json' &>/dev/null; then
  echo -e "${YELLOW}Warning: Local ord at ${ORD_BASE} is not reachable. Inscription checks will fail.${RESET}"
fi

# Check Satflow API key
if [[ -z "$SATFLOW_KEY" ]]; then
  echo -e "${YELLOW}Warning: SATFLOW_API_KEY not set. Satflow checks will be skipped.${RESET}"
  echo -e "${DIM}Set it in .env or export SATFLOW_API_KEY=...${RESET}"
fi

pr_numbers=()
for arg in "$@"; do
  pr_num=$(parse_pr_number "$arg")
  if [[ -z "$pr_num" ]]; then
    echo "Error: Could not parse PR number from '${arg}'"
    exit 1
  fi
  pr_numbers+=("$pr_num")
done

echo -e "${BOLD}Reviewing ${#pr_numbers[@]} PR(s) for ${REPO}${RESET}"

declare -A pr_status  # "ok" or "warnings"
mergeable_prs=()
for pr_num in "${pr_numbers[@]}"; do
  rc=0
  review_pr "$pr_num" || rc=$?
  if [[ $rc -eq 0 ]]; then
    mergeable_prs+=("$pr_num")
    pr_status[$pr_num]="ok"
  elif [[ $rc -eq 2 ]]; then
    mergeable_prs+=("$pr_num")
    pr_status[$pr_num]="warnings"
  fi
done

echo ""
echo -e "${BOLD}═══════════════════════════════════${RESET}"

if [[ ${#mergeable_prs[@]} -eq 0 ]]; then
  echo -e "${RED}No PRs are eligible for merging.${RESET}"
  exit 1
fi

echo -e "${GREEN}${#mergeable_prs[@]} PR(s) eligible for merging: ${mergeable_prs[*]}${RESET}"
echo ""

for pr_num in "${mergeable_prs[@]}"; do
  local_title=$(gh pr view "$pr_num" --repo "$REPO" --json title -q '.title' 2>/dev/null)
  local_entries=$(get_new_entries "$pr_num")
  local_slugs=$(echo "$local_entries" | python3 -c "import sys,json; print(', '.join(e['slug'] for e in json.load(sys.stdin)))" 2>/dev/null)

  if [[ "${pr_status[$pr_num]}" == "warnings" ]]; then
    echo -e "${YELLOW}PR #${pr_num} has warnings!${RESET}"
    echo -ne "Action for PR #${pr_num} (${local_title})? [m]erge / [c]omment / [s]kip: "
  else
    echo -ne "Action for PR #${pr_num} (${local_title})? [m]erge / [c]omment / [s]kip: "
  fi
  read -r answer

  case "$answer" in
    m|M)
      echo -n "Applying collections.json entries from PR #${pr_num}... "
      commit_msg="Add ${local_slugs} (PR #${pr_num})"
      commit_url=""
      if commit_url=$(apply_collection_entries "$pr_num" "$local_entries" "$commit_msg"); then
        echo -e "${GREEN}done${RESET}"
        info "${commit_url}"
        gh pr close "$pr_num" --repo "$REPO" \
          --comment "Merged collections.json entries via [${commit_msg}](${commit_url}). Non-data file changes were excluded." \
          > /dev/null 2>&1
        info "PR #${pr_num} closed — https://github.com/${REPO}/pull/${pr_num}"
      else
        echo -e "${RED}failed${RESET}"
      fi
      ;;
    c|C)
      echo -ne "Enter comment for PR #${pr_num}: "
      read -r comment_text
      if [[ -n "$comment_text" ]]; then
        gh pr comment "$pr_num" --repo "$REPO" --body "$comment_text" > /dev/null 2>&1
        echo -e "${GREEN}Comment posted on PR #${pr_num}${RESET}"
      else
        echo "No comment entered, skipping."
      fi
      ;;
    *)
      echo "Skipped PR #${pr_num}"
      ;;
  esac
done
