#!/bin/sh
# PowerGuard dry-run smoke test.
# Uses temporary paths and PG_DRY=1: never writes the RTC, never powers off.
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROOT=$(CDPATH= cd "$HERE/.." && pwd)
PG="$ROOT/powerguard.sh"
[ -f "$PG" ] || { echo "FAIL: $PG not found"; exit 1; }

T=
cleanup() { if [ -n "$T" ]; then rm -rf "$T"; fi; }
trap cleanup EXIT

new_case() {
  cleanup
  T=$(mktemp -d)
  mkdir -p "$T/bat" "$T/rtc"
  echo 100 > "$T/bat/capacity"
  echo 1 > "$T/ac"
  : > "$T/rtc/wakealarm"
  date +%s > "$T/rtc/since_epoch"
}

run() {
  env PG_DRY=1 PG_DB=0 PG_LOGGER=true \
      PG_AC="$T/ac" PG_BAT="$T/bat" PG_RTC="$T/rtc" PG_WA="$T/rtc/wakealarm" \
      PG_LOGF="$T/log" PG_CNT="$T/cnt" PG_FARE="$T/fare" \
      PG_LOCK="$T/lock" PG_OVR="$T/ovr" \
      sh "$PG" "$@"
}

fail() { echo "FAIL: $*"; [ -f "$T/log" ] && { echo "--- log ---"; cat "$T/log"; }; exit 1; }
expect() { grep -q "$1" "$T/log" 2>/dev/null || fail "missing log: $1"; }
reject() { ! grep -q "$1" "$T/log" 2>/dev/null || fail "unexpected log: $1"; }
ok() { echo "ok - $*"; }

# 1. wall-powered boot clears markers
new_case
: > "$T/cnt"; : > "$T/fare"; : > "$T/ovr"
run boot
expect "boot: wall power present"
{ [ ! -e "$T/cnt" ] && [ ! -e "$T/fare" ] && [ ! -e "$T/ovr" ]; } || fail "markers not cleared"
ok "wall-powered boot clears markers"

# 2. wall loss -> graceful shutdown
new_case
echo 0 > "$T/ac"
run
expect "wall power lost - graceful shutdown"
expect "DRYRUN: would poweroff"
ok "wall loss shuts down"

# 3. RTC probe boot -> probe miss + sleep
new_case
echo 0 > "$T/ac"
run boot
expect "probe miss #1"
expect "DRYRUN: would poweroff"
[ "$(cat "$T/cnt")" = 1 ] || fail "counter != 1"
ok "probe boot increments counter"

# 4. battery floor -> farewell probe
new_case
echo 0 > "$T/ac"; echo 15 > "$T/bat/capacity"
run boot
expect "farewell probe +7200s"
expect "DRYRUN: would poweroff"
[ -e "$T/fare" ] || fail "farewell marker missing"
ok "battery floor arms farewell"

# 5. farewell already used -> final shutdown
new_case
echo 0 > "$T/ac"; echo 15 > "$T/bat/capacity"; : > "$T/fare"
run boot
expect "final shutdown"
expect "DRYRUN: would poweroff"
ok "farewell used -> final shutdown"

# 6. unknown AC -> stay up
new_case
rm -f "$T/ac"
run boot
expect "AC sensor unknown - staying up"
reject "DRYRUN: would poweroff"
ok "unknown AC stays up"

# 7. maintenance override on boot -> stay up
new_case
echo 0 > "$T/ac"; : > "$T/ovr"
run boot
expect "maintenance override"
reject "DRYRUN: would poweroff"
ok "override honored at boot"

# 8. maintenance override on cron -> stay up silently
new_case
echo 0 > "$T/ac"; : > "$T/ovr"
run
reject "DRYRUN: would poweroff"
ok "override honored by cron"

# 9. pre-set override survives an AC-on cron run
new_case
: > "$T/ovr"
run
[ -e "$T/ovr" ] || fail "override removed while AC on"
ok "pre-set override survives AC-on cron"

# 10. human boot (future alarm) -> stay up
new_case
echo 0 > "$T/ac"
echo $(( $(cat "$T/rtc/since_epoch") + 600 )) > "$T/rtc/wakealarm"
run boot
expect "manual boot during outage"
reject "DRYRUN: would poweroff"
ok "future alarm = manual boot"

echo "PASS: 10/10"
