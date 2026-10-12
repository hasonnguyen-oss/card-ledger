#!/bin/bash
# Install the weekly card-ledger price scrape on this Mac.
#
# Run this on the machine that should do the scraping - one that stays powered
# on and sits on a home internet connection. PriceCharting returns 403 to cloud
# and datacenter IPs, which is why this cannot live in GitHub Actions any more.
#
# Usage:
#   bash install.sh
#
# Needs: python3, and gh authenticated with repo scope (gh auth login).
# Installs to ~/card-ledger-scraper and registers a launchd agent that runs
# Mondays at 06:00 local.

set -uo pipefail

REPO="hasonnguyen-oss/card-ledger"
DEST="$HOME/card-ledger-scraper"
LABEL="com.hanguyen.card-ledger-scrape"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "=== installing card-ledger weekly scrape ==="

# --- preflight -------------------------------------------------------------
fail=0
if ! command -v python3 >/dev/null 2>&1; then
  echo "MISSING: python3"; fail=1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "MISSING: gh (install with: brew install gh)"; fail=1
elif ! gh auth status >/dev/null 2>&1; then
  echo "MISSING: gh is installed but not authenticated (run: gh auth login)"; fail=1
fi
[ "$fail" -ne 0 ] && { echo "preflight failed, nothing installed"; exit 1; }

GH_BIN="$(command -v gh)"
echo "python3: $(command -v python3)"
echo "gh:      $GH_BIN"

# --- fetch the runner ------------------------------------------------------
mkdir -p "$DEST/logs"
echo "--- fetching run_weekly_scrape.sh into $DEST"
if ! gh api "repos/$REPO/contents/scripts/local/run_weekly_scrape.sh" --jq '.content' \
     | base64 -d > "$DEST/run_weekly_scrape.sh"; then
  echo "FATAL: could not fetch run_weekly_scrape.sh"; exit 1
fi
chmod +x "$DEST/run_weekly_scrape.sh"

# --- write the launchd agent ----------------------------------------------
# gh is usually under Homebrew, which is not on launchd's default PATH, so pin
# the PATH to include wherever gh actually lives on this machine.
GH_DIR="$(dirname "$GH_BIN")"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DEST/run_weekly_scrape.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>1</integer>
        <key>Hour</key>
        <integer>6</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$GH_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$DEST/logs/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$DEST/logs/launchd.err.log</string>
</dict>
</plist>
PLISTEOF

echo "--- wrote $PLIST"

# Re-registering is normal on reinstall, so clear any existing copy first.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST"; then
  echo "FATAL: launchctl bootstrap failed"; exit 1
fi

echo "--- registered. Scheduled: Mondays 06:00 local."
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null \
  | grep -E "state|program|runs" | head -5

cat <<EOF

=== installed ===
  script:   $DEST/run_weekly_scrape.sh
  logs:     $DEST/logs/
  schedule: Mondays 06:00 local

Run it now to verify (takes ~4 minutes, 69 products):
  launchctl kickstart -p gui/\$(id -u)/$LABEL

Then check the result:
  tail -20 \$(ls -t $DEST/logs/scrape-*.log | head -1)

Remove it later with:
  launchctl bootout gui/\$(id -u)/$LABEL && rm $PLIST
EOF
