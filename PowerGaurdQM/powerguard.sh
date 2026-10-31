#!/bin/sh
# powerguard.sh v3.2 - battery-backed outage survival
# Policy: wall power = run + charge. Wall loss = quick graceful shutdown (battery = shutdown-UPS only).
# While off in S5, wake every 15 min to probe; AC back -> stay up, else sleep again.
# Coverage: constant 15-min probes -> ~16-20 h from 100% to BAT_FLOOR on an 18.8 Wh pack.
# Below the floor: one 2 h farewell probe (auto-recovery if wall returns), then true final shutdown.
# Safety: three-state AC sensing (on/off/unknown - never false-shutdown on a sensor error),
# alarm arming verified by read-back before probe/farewell poweroff, atomic mkdir lock, dry-run mode.
# Maintenance override: touch /root/.powerguard.off; survives reboot and keeps the machine up
# on battery until removed (or until a wall-powered boot clears it). v3.2 moved this out of /tmp.
PATH=/sbin:/bin:/usr/sbin:/usr/bin
PROBE_S=900            # probe every 15 min, constant
FAREWELL_S=7200        # one last 2 h probe at the battery floor
BAT_FLOOR=20           # stop probing below this % (protect the pack)
RTC=${PG_RTC:-/sys/class/rtc/rtc0}
WA=${PG_WA:-$RTC/wakealarm}
AC=${PG_AC:-/sys/class/power_supply/ADP1/online}
LOGF=${PG_LOGF:-/root/powerguard.log}
CNT=${PG_CNT:-/root/.powerguard.counter}
FARE=${PG_FARE:-/root/.powerguard.farewell}
LOCK=${PG_LOCK:-/tmp/powerguard.lock}
OVR=${PG_OVR:-/root/.powerguard.off}   # maintenance override (survives reboot)
LOGGER=${PG_LOGGER:-logger}
DRY=${PG_DRY:-0}          # 1 = dry-run (simulate, never touch RTC or poweroff)
DB_S=${PG_DB:-60}         # debounce seconds (override for tests)

LOG() {
  [ -f "$LOGF" ] && [ "$(wc -c < "$LOGF")" -gt 100000 ] && { tail -20 "$LOGF" > "$LOGF.tmp" 2>/dev/null && mv "$LOGF.tmp" "$LOGF"; }
  "$LOGGER" -t powerguard "$1"
  echo "$(date +%F_%T) $1" >> "$LOGF"
}

ac_state() { v=$(cat "$AC" 2>/dev/null); case "$v" in 1) echo on;; 0) echo off;; *) echo unknown;; esac; }
bump() { c=$(cat "$CNT" 2>/dev/null); c=${c:-0}; echo $((c + 1)) > "$CNT"; }
BAT=${PG_BAT:-$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)}
[ -n "$BAT" ] && [ -e "$WA" ] || exit 0

# Arm RTC alarm +$1 s (relative format, kernel-documented; works even with unsynced system clock).
# Returns 0 only if read-back confirms the absolute target within 1 s.
arm_alarm() {
  if [ "$DRY" = 1 ]; then LOG "DRYRUN: would arm alarm +${1}s"; return 0; fi
  echo 0 > "$WA" 2>/dev/null
  echo "+$1" > "$WA" 2>/dev/null
  cur=$(cat "$WA" 2>/dev/null); target=$(( $(cat "$RTC/since_epoch" 2>/dev/null) + $1 ))
  diff=$(( ${cur:-0} - target )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
  [ "$diff" -le 1 ]
}

# Alarm still pending in the future => a human/WoL woke us, not the RTC.
human_boot() {
  t=$(cat "$WA" 2>/dev/null)
  [ -n "$t" ] && [ "$t" -gt "$(cat "$RTC/since_epoch" 2>/dev/null)" ]
}

# Final AC re-check right before powering off (AC may return during setup/logging).
# AC on -> stay up and clear outage markers. Sensor unknown -> never power off on a guess.
poff() {
  case "$(ac_state)" in
    on)      rm -f "$CNT" "$FARE" "$OVR"; LOG "AC returned - staying up"; exit 0 ;;
    unknown) LOG "AC sensor unknown - not powering off"; exit 0 ;;
  esac
  if [ "$DRY" = 1 ]; then LOG "DRYRUN: would poweroff"; else sleep 2 && poweroff; fi
}

# ---- atomic lock, taken before mode selection (cron and rc.local may overlap at boot) ----
[ -e "$LOCK" ] && [ -n "$(find "$LOCK" -mmin +5 2>/dev/null)" ] && rm -rf "$LOCK"
mkdir "$LOCK" 2>/dev/null || exit 0
trap "rmdir \"$LOCK\" 2>/dev/null" 0

# ---- boot-time: woken by RTC probe, WoL, or power button ----
if [ "$1" = "boot" ]; then
  case "$(ac_state)" in
    on)
      [ "$DRY" = 1 ] || echo 0 > "$WA" 2>/dev/null
      rm -f "$CNT" "$FARE" "$OVR"
      LOG "boot: wall power present, staying up" ;;
    unknown)
      LOG "boot: AC sensor unknown - staying up; cron will re-evaluate" ;;
    off)
      if [ -e "$OVR" ]; then
        LOG "maintenance override ($OVR) - staying up on battery"
      elif human_boot; then
        LOG "manual boot during outage - staying up; cron will re-shutdown"
      else
        cap=$(cat "$BAT/capacity" 2>/dev/null)
        INVALID=0
        case "$cap" in ''|*[!0-9]*) INVALID=1;; *) [ "$cap" -gt 100 ] && INVALID=1;; esac
        if [ "$INVALID" = 1 ]; then
          MSG="battery capacity unknown (${cap:-?}) - farewell probe +${FAREWELL_S}s"
          if [ -e "$FARE" ]; then
            LOG "battery capacity unknown - final shutdown (farewell already used)"
            poff
          elif arm_alarm $FAREWELL_S; then
            touch "$FARE"; LOG "$MSG"; poff
          else
            LOG "FATAL: could not arm farewell alarm - staying up for manual shutdown"
          fi
        elif [ "$cap" -ge "$BAT_FLOOR" ]; then
          if arm_alarm $PROBE_S; then
            bump
            LOG "probe miss #$(cat "$CNT") (battery ${cap}%) - sleeping ${PROBE_S}s"
            poff
          else
            LOG "FATAL: could not arm RTC alarm - staying up for manual shutdown"
          fi
        else
          if [ -e "$FARE" ]; then
            LOG "battery at floor (${cap}%) - final shutdown (farewell already used)"
            poff
          elif arm_alarm $FAREWELL_S; then
            touch "$FARE"; LOG "battery too low (${cap}%) - farewell probe +${FAREWELL_S}s"; poff
          else
            LOG "FATAL: could not arm farewell alarm - staying up for manual shutdown"
          fi
        fi
      fi ;;
  esac
  exit 0
fi

# ---- running: detect wall loss (cron every minute) ----
[ -e "$OVR" ] && exit 0            # maintenance override: stay up on battery
if [ "$(ac_state)" = off ]; then
  sleep "$DB_S"                     # debounce: ignore flickers < DB_S s
  [ "$(ac_state)" != off ] && exit 0
  cap=$(cat "$BAT/capacity" 2>/dev/null)
  if arm_alarm $PROBE_S; then
    LOG "wall power lost - graceful shutdown (battery ${cap:-?}%)"
    poff
  else
    LOG "FATAL: could not arm RTC alarm - staying up; retry next cron run"
  fi
fi
