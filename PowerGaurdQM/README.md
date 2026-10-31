<div align="center">

# PowerGuard

**Battery-backed outage survival for OpenWrt laptops and mini-PCs.**

[![OpenWrt](https://img.shields.io/badge/OpenWrt-25.12.5-00A8E8)](https://openwrt.org)
[![Shell](https://img.shields.io/badge/shell-POSIX-4EAA25)](powerguard.sh)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

PowerGuard turns the internal battery of a laptop or mini-PC into an emergency
shutdown-UPS. When wall power disappears it shuts the machine down cleanly,
then uses the RTC to wake every 15 minutes, check whether AC is back, and either
stay up or go back to sleep. It is built for boards that do **not** auto-power-on
when AC returns — the Toshiba Portégé M500 used for development is one of them.

> **Battery policy:** the battery is emergency-only. Normal operation is 100%
> wall power; the battery exists to buy a clean shutdown and a few hours of
> wake-and-check probes, not to run the server.

This is not a replacement for NUT or apcupsd. Those need a UPS with a data
cable. PowerGuard is for machines that already have a battery and an RTC but no
clean way to come back after an outage.

## Features

- Clean shutdown on AC loss after a 60-second debounce (plus up to one cron
  interval of detection latency).
- RTC wake every 15 minutes; automatic recovery when wall power returns.
- Three-state AC sensing: `on`, `off`, `unknown`. Unknown never powers off.
- RTC alarm arming verified by read-back before every probe or farewell
  poweroff. If the alarm cannot be armed, the machine stays up and logs `FATAL`
  instead of going dark. (The intentional final shutdown at the battery floor
  does not arm an alarm.)
- One farewell probe at the battery floor (2 hours), then true final shutdown.
- Maintenance override for planned outages: `/root/.powerguard.off` survives an
  outage reboot on battery.
- Atomic `mkdir` lock with 5-minute stale-lock cleanup, so the cron watchdog
  and the boot hook cannot race.
- Dry-run mode plus `PG_*` path overrides for safe testing.
- Automatic log rotation (100 KB, keeps the last 20 lines).
- No daemon, no database, no extra services. BusyBox `ash` is enough.

## How it works

| Situation | What PowerGuard does |
|-----------|----------------------|
| Wall power present | Runs from wall power, charges the battery, stays idle. |
| Wall power lost | Re-reads AC after `DB_S` seconds, arms the RTC for `+PROBE_S`, logs, and powers off gracefully. |
| RTC wake, AC back | Clears the alarm and outage markers, stays up, resumes charging. |
| RTC wake, AC still off, battery ≥ floor | Counts the probe, arms another `+PROBE_S`, powers off. |
| RTC wake, AC still off, battery < floor, no farewell yet | Arms one `+FAREWELL_S` (2 h) probe and powers off. |
| RTC wake, AC still off, farewell already used | Final shutdown. Only WoL or the power button can bring it back. |
| Battery capacity unreadable | Uses the same one-shot farewell path, then final shutdown. |
| AC sensor missing / unreadable | Reports `unknown` and stays up. It never guesses its way into a shutdown. |
| Human boot during an outage | Detected by a still-pending future RTC alarm; stays up briefly, then the cron watchdog re-evaluates. Set the maintenance override to keep it up. |

The safety rule is simple: **an unreadable AC sensor is not an outage.** An AC
sensor error, a missing AC file, or a failed RTC arming all keep the machine
running. The only thing that powers it off is a confirmed `off` reading.

## Requirements

- Linux with sysfs `power_supply` and `rtc` interfaces. OpenWrt 25.12.5 x86_64
  is the tested platform; other Linux systems with BusyBox `ash` should work.
- A battery and an AC adapter visible under `/sys/class/power_supply/`.
- An RTC that can wake the machine from S5 (`/sys/class/rtc/rtc0/wakealarm`).
  Test this **before** relying on PowerGuard.
- Cron (BusyBox cron is fine).
- Root access.
- Optional: `ethtool` for Wake-on-LAN and `pciutils` for `lspci` diagnostics.

### Check your hardware first

```sh
# Find the AC adapter and battery
ls /sys/class/power_supply/
cat /sys/class/power_supply/ADP1/online   # 1 = wall, 0 = battery
cat /sys/class/power_supply/BAT1/capacity # 0-100

# RTC wake support
ls /sys/class/rtc/rtc0/wakealarm
cat /sys/class/rtc/rtc0/name

# Optional: WoL support
ethtool eth0 | grep -i wake
```

Adapter names vary (`ADP1`, `AC`, `ACAD`, ...), as do battery names (`BAT0`,
`BAT1`, ...) and RTC names (`rtc0`, `rtc1`, ...). The script auto-detects the
first `BAT*` and defaults to `rtc0`; edit the top of the script or use the
`PG_AC`, `PG_BAT`, `PG_RTC`, and `PG_WA` overrides for anything else.

## Install

### 1. Copy the script

```sh
# OpenSSH 9+ needs -O for OpenWrt/Dropbear (no sftp-server)
scp -O powerguard.sh root@router:/root/
# Unix fallback:
# cat powerguard.sh | ssh root@router 'cat > /root/powerguard.sh'

ssh root@router 'chmod +x /root/powerguard.sh'
```

The `-O` flag forces the legacy SCP protocol. Older OpenSSH versions use it by
default, so you can omit `-O` there.

### 2. Configure the paths

Edit the top of `/root/powerguard.sh`:

```sh
AC=${PG_AC:-/sys/class/power_supply/ADP1/online}
RTC=${PG_RTC:-/sys/class/rtc/rtc0}
WA=${PG_WA:-$RTC/wakealarm}
PROBE_S=900
FAREWELL_S=7200
BAT_FLOOR=20
```

Edit the default value after `:-` (or set the matching `PG_*` variable).
`BAT` is auto-detected from `/sys/class/power_supply/BAT*`; if you have more
than one battery, set `BAT` (or `PG_BAT`) explicitly.

### 3. Add the boot hook

Append the PowerGuard line to `/etc/rc.local` **before** `exit 0`:

```sh
/root/powerguard.sh boot
```

[`examples/rc.local`](examples/rc.local) shows the complete file used on the
test unit, including the optional laptop LCD-off lines and WoL re-arm. **Do not
replace an existing `/etc/rc.local`** — merge these lines into it before
`exit 0`. Remove the LCD lines if your hardware does not expose those paths,
and change `eth0` if your NIC has a different name.

### 4. Add the cron watchdog

Append this line to `/etc/crontabs/root`:

```cron
* * * * * /root/powerguard.sh
```

Then restart cron:

```sh
/etc/init.d/cron restart
```

[`examples/crontab`](examples/crontab) is a one-line sample. **Do not replace
the whole crontab** — append the PowerGuard line and keep your other jobs.

### 5. Test before trusting it

From the repository checkout, run the dry-run suite:

```sh
sh tests/smoke.sh
```

It uses temporary paths and `PG_DRY=1`, so it never writes the RTC and never
powers off. Then do the real RTC wake test in a maintenance window:

```sh
echo 0 > /sys/class/rtc/rtc0/wakealarm
echo +240 > /sys/class/rtc/rtc0/wakealarm   # relative format
poweroff
```

The machine must self-boot about 4 minutes later. If it does not, stop and fix
the RTC/BIOS side before relying on PowerGuard. This command **powers the
server off**.

Watch the event log while testing:

```sh
tail -f /root/powerguard.log
```

## Configuration

All knobs live at the top of `powerguard.sh`.

| Knob | Default | Env override | Purpose |
|------|---------|--------------|---------|
| `PROBE_S` | `900` | — | Probe interval (15 min) |
| `FAREWELL_S` | `7200` | — | One final probe at the floor (2 h) |
| `BAT_FLOOR` | `20` | — | Stop regular probes below this percentage |
| `DB_S` | `60` | `PG_DB` | AC debounce in seconds |
| `RTC` | `/sys/class/rtc/rtc0` | `PG_RTC` | RTC device |
| `WA` | `$RTC/wakealarm` | `PG_WA` | RTC alarm file |
| `AC` | `/sys/class/power_supply/ADP1/online` | `PG_AC` | AC online file |
| `BAT` | first `BAT*` | `PG_BAT` | Battery directory |
| `LOGF` | `/root/powerguard.log` | `PG_LOGF` | Event log |
| `CNT` | `/root/.powerguard.counter` | `PG_CNT` | Probe-miss counter |
| `FARE` | `/root/.powerguard.farewell` | `PG_FARE` | Farewell-used marker |
| `LOCK` | `/tmp/powerguard.lock` | `PG_LOCK` | Atomic lock directory |
| `OVR` | `/root/.powerguard.off` | `PG_OVR` | Maintenance override |
| `DRY` | `0` | `PG_DRY` | `1` = dry-run; never touches the RTC or powers off |
| `LOGGER` | `logger` | `PG_LOGGER` | Syslog command (tests use `true`) |

### Maintenance override

For planned work during an outage, set the flag before the outage (it survives
the shutdown/boot) and keep the machine up on battery:

```sh
touch /root/.powerguard.off
```

The flag survives an outage reboot (it lives in `/root`, not `/tmp`) and is
honored by both the boot hook and the minute cron watchdog. It is cleared
automatically on the next wall-powered boot, and if AC returns while the script
is preparing to power off. Otherwise, remove it to resume automatic shutdown:

```sh
rm /root/.powerguard.off
```

> While the flag exists, PowerGuard will not shut down on battery. Do not
> forget it, or the pack will run flat.

## Verification

Tested on a Toshiba Portégé M500 running OpenWrt 25.12.5 x86_64 (Linux 6.12.94)
with a worn 18.8 Wh effective battery (50.8 Wh design) and `rtc_cmos`.

| Test | Status |
|------|--------|
| RTC wake from S5 (240 s test) | ✅ Live |
| RTC wake every 15 min during an outage | ✅ Live — 43 probe cycles |
| Wall loss → shutdown → probe → auto-recovery | ✅ Live — 9 outages, Aug–Oct 2026 |
| Alarm arming read-back before probe/farewell poweroff | ✅ Live — no `FATAL` entries |
| Stale alarm / marker cleanup on wall boot | ✅ Live |
| AC sensor unknown → stay up | 🟡 Dry-run |
| Manual boot during outage → stay up, then watchdog | 🟡 Dry-run |
| Battery floor → 2 h farewell → final shutdown | 🟡 Dry-run |
| WoL from S5 | ⚪ Configured (`Wake-on: g`), not end-to-end tested |
| EC auto-power-on when AC returns | ❌ Fails on this board |

The live numbers come from the test unit's log: 9 real wall-loss events and
43 real 15-minute probe wakes between August and October 2026, all recovered
when wall power returned. The dry-run cases are covered by `tests/smoke.sh`
(10/10 on the test unit). The live data was collected on v3.1; v3.2 changes the
maintenance override and adds testability, not the outage state machine.

## Coverage

Measured on the 18.8 Wh test pack:

| Metric | Value |
|--------|-------|
| Probe interval | 15 minutes |
| Drain in probe mode | ~4–5 %/h (7 cycles: 100% → 92% in 1 h 48 m) |
| Per 15-minute shutdown/wake cycle | ~1 % (coarse gauge) |
| 100% → 20% floor | ~16–20 hours |
| At the floor | one 2 h farewell probe, then final shutdown |
| Normal runtime | wall power only; battery is emergency-only |

Your runtime depends on battery health, standby drain, and `PROBE_S`. Measure
your own pack before trusting an estimate.

## Files

| Repo file | Installed path | Purpose |
|-----------|----------------|---------|
| [`powerguard.sh`](powerguard.sh) | `/root/powerguard.sh` | Main script (v3.2) |
| [`examples/rc.local`](examples/rc.local) | `/etc/rc.local` | Boot hook sample |
| [`examples/crontab`](examples/crontab) | `/etc/crontabs/root` | Cron line sample |
| [`tests/smoke.sh`](tests/smoke.sh) | — | Dry-run regression test |
| [`README.md`](README.md) | — | This file |
| [`LICENSE`](LICENSE) | — | MIT license |

Runtime files created on the router:

| Path | Purpose |
|------|---------|
| `/root/powerguard.log` | Event log, auto-truncated at 100 KB (last 20 lines kept) |
| `/root/.powerguard.counter` | Probe-miss counter, deleted on recovery |
| `/root/.powerguard.farewell` | Marks the one farewell probe as used |
| `/root/.powerguard.off` | Maintenance override (v3.2) |
| `/tmp/powerguard.lock` | Atomic lock, cleared on reboot |

## Troubleshooting

| Symptom | Check |
|---------|-------|
| No log entries, no action | `chmod +x /root/powerguard.sh`; cron line exists; `/etc/init.d/cron restart`; `ls /sys/class/power_supply/BAT*`; `[ -e /sys/class/rtc/rtc0/wakealarm ]` |
| `FATAL: could not arm RTC alarm` | Test `echo +60 > /sys/class/rtc/rtc0/wakealarm`; check RTC driver/BIOS. The machine stays up by design. |
| `AC sensor unknown` | Check the `AC` path and `cat` value. The machine stays up by design. |
| `battery capacity unknown` | Check that `BAT/capacity` exists and reads 0–100. The script uses the farewell path. |
| Does not wake from S5 | Run the 240 s test. Some boards cut RTC power in S5; check BIOS. |
| WoL does not wake it | `ethtool eth0 \| grep -i wake`; enable WoL in BIOS; `ethtool -s eth0 wol g`; some NICs lose WoL on full power loss. |
| Clock wrong after wake | The relative RTC alarm works without NTP; configure NTP for correct logs/TLS. |
| Shuts down too eagerly | Increase `DB_S`; verify the `AC` path; check the battery is above `BAT_FLOOR`. |
| Never shuts down on battery | Check whether `/root/.powerguard.off` exists; remove it. |

## Limitations & safety

- This is a **shutdown-UPS**, not a runtime UPS. The battery is not meant to
  keep the server running for hours.
- If the AC sensor is stuck in the `on` state, PowerGuard cannot detect the
  outage. The three-state logic protects against a missing or erroring sensor,
  not a sensor that lies.
- Some boards cannot wake from S5 or lose RTC power. Test the wake path first.
- WoL depends on the NIC, BIOS, and whether the NIC keeps power in S5.
- The script runs as root and powers off the machine. Test it on your hardware.
- The RTC alarm is owned by PowerGuard. Do not use `wakealarm` for unrelated
  scheduled wakeups on the same machine.
- The log is local and truncated. Ship it to a remote syslog if you need a
  long-term history.
- `PROBE_S` and `BAT_FLOOR` are tuned for the 18.8 Wh test pack. Adjust them for
  your battery.

## Uninstall

```sh
rm -f /root/powerguard.sh /root/powerguard.log \
      /root/.powerguard.counter /root/.powerguard.farewell \
      /root/.powerguard.off /tmp/powerguard.lock
```

Then:

1. Remove only the `/root/powerguard.sh` line from `/etc/crontabs/root` and
   restart cron:
   ```sh
   /etc/init.d/cron restart
   ```
2. Remove `/root/powerguard.sh boot` and the optional WoL/LCD lines from
   `/etc/rc.local`.
3. Optional: remove packages you added only for PowerGuard:
   ```sh
   apk del ethtool pciutils    # OpenWrt 24.10+
   # opkg remove ethtool pciutils   # older OpenWrt
   ```

## Changelog

- **v3.2** — Fixed the maintenance override: moved from `/tmp/powerguard.off`
  (tmpfs, cleared on reboot) to `/root/.powerguard.off`; the cron watchdog now
  honors it; it is cleared on the next wall-powered boot. Added `PG_*` path
  overrides and `tests/smoke.sh`.
- **v3.1** — Three-state AC sensing, read-back alarm verification, atomic lock,
  dry-run mode, farewell probe, and human-boot detection.

## Contributing

Issues and pull requests are welcome. When reporting a problem, include:

- your hardware model and OpenWrt version,
- `ls /sys/class/power_supply/` and `cat /sys/class/rtc/rtc0/name`,
- the relevant lines from `/root/powerguard.log`,
- whether the RTC wake test (240 s) works on your board.

Please test RTC wake on real hardware before submitting changes to shutdown
logic.

## License

MIT — see [LICENSE](LICENSE).

> PowerGuard powers off your machine. Test the RTC wake path before relying on
> it. The authors are not responsible for data loss or a flat battery.
