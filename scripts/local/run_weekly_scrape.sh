#!/bin/bash
# Weekly PriceCharting scrape, run locally instead of in GitHub Actions.
#
# Why this runs here and not in CI: PriceCharting began returning 403 Forbidden
# to GitHub Actions runner IPs in October 2026. A residential IP still gets 200,
# so the scrape has to originate from a machine on a home connection. This box
# is meant to stay powered on for exactly that reason.
#
# Deliberately avoids git: it talks to GitHub through `gh api` (the Contents
# API) instead. That keeps the job working even when Apple's git is wedged
# behind an unaccepted Xcode licence after an OS update, which is what broke
# the laptop.
#
# Requires: python3, gh (authenticated with repo scope).

set -uo pipefail

REPO="hasonnguyen-oss/card-ledger"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/work"
LOG="$HERE/logs/scrape-$(date -u +%Y%m%d-%H%M%S).log"

# scrape_prices.py resolves data.json as <its dir>/../data.json, matching the
# repo's layout, so reproduce that shape here rather than patching the script.
mkdir -p "$WORK/scripts" "$HERE/logs"

{
  echo "=== weekly scrape $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

  if ! command -v gh >/dev/null 2>&1; then
    echo "FATAL: gh not found on PATH"; exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "FATAL: gh is not authenticated (run: gh auth login)"; exit 1
  fi

  cd "$WORK" || exit 1

  # data.json is the work list: it carries every item's id and priceUrl.
  echo "--- fetching data.json from $REPO"
  if ! gh api "repos/$REPO/contents/data.json" --jq '.content' | base64 -d > data.json; then
    echo "FATAL: could not fetch data.json"; exit 1
  fi
  python3 -I -c "import json;d=json.load(open('data.json'));print('   work list: %d lots, %d watch' % (len(d['lots']), len(d['watch'])))" || exit 1

  # Keep the scraper itself in step with the repo, so edits there take effect
  # here without anyone having to remember to copy a file across.
  echo "--- fetching scrape_prices.py from $REPO"
  if ! gh api "repos/$REPO/contents/scripts/scrape_prices.py" --jq '.content' | base64 -d > scripts/scrape_prices.py; then
    echo "FATAL: could not fetch scrape_prices.py"; exit 1
  fi

  echo "--- scraping"
  if ! python3 -I scripts/scrape_prices.py; then
    echo "FATAL: scrape failed; prices.json NOT updated"; exit 1
  fi

  # The scraper refuses to write the file when everything fails, so its absence
  # or staleness here means the run is not safe to publish.
  if [ ! -f prices.json ]; then
    echo "FATAL: prices.json missing after scrape"; exit 1
  fi

  PRICED=$(python3 -I -c "import json;print(json.load(open('prices.json'))['priced'])")
  FAILED=$(python3 -I -c "import json;print(json.load(open('prices.json'))['failed'])")
  GENAT=$(python3 -I -c "import json;print(json.load(open('prices.json'))['generatedAt'])")
  echo "--- scraped: priced=$PRICED failed=$FAILED generatedAt=$GENAT"

  if [ "$PRICED" -eq 0 ]; then
    echo "FATAL: nothing priced; refusing to upload"; exit 1
  fi

  echo "--- uploading prices.json via GitHub API"
  SHA=$(gh api "repos/$REPO/contents/prices.json" --jq '.sha' 2>/dev/null || true)
  B64=$(base64 < prices.json | tr -d '\n')

  if [ -n "$SHA" ]; then
    RESP=$(gh api --method PUT "repos/$REPO/contents/prices.json" \
      -f message="Scrape prices $(date -u +%Y-%m-%d) (local)" \
      -f content="$B64" \
      -f sha="$SHA" 2>&1)
    RC=$?
  else
    RESP=$(gh api --method PUT "repos/$REPO/contents/prices.json" \
      -f message="Scrape prices $(date -u +%Y-%m-%d) (local)" \
      -f content="$B64" 2>&1)
    RC=$?
  fi

  if [ "$RC" -ne 0 ]; then
    echo "FATAL: upload failed:"; echo "$RESP"; exit 1
  fi

  NEWSHA=$(printf '%s' "$RESP" | python3 -I -c "import sys,json;print(json.load(sys.stdin)['commit']['sha'][:7])" 2>/dev/null || echo "?")
  echo "--- uploaded OK, commit $NEWSHA"
  echo "=== done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
} 2>&1 | tee -a "$LOG"

# tee masks the pipeline's exit status, so recover the script's own result.
exit "${PIPESTATUS[0]}"
