# Energy & performance tests

**This directory is mirrored into the public community repository**
(`scripts/publish-perf.sh`), so that the figures on
[the energy rating page](https://wheelclick.app/learn/software-energy-efficiency-rating/)
can be audited by reading the thing that produced them. It is not a general
instrument and does not pretend to be one: `rate-features.sh` compiles the app's
own `AppScope` sources, `lib.sh` unlocks the signing keychain, and `EnergyBench`
finds WheelClick by bundle path. What is portable is the method, not the code.

WheelClick is meant to run forever, so its energy profile is a feature.
These tests measure the **real app process** from the outside — no mocks, no
microbenchmarks. `EnergyBench` samples `proc_pid_rusage` (CPU time, package
idle / interrupt wakeups, billed CPU energy in nanojoules, memory footprint;
no sudo needed) around each scenario, and the load scenarios post synthetic
events into the same session event stream the app taps.

```sh
perf/run.sh                  # all scenarios against the running app
perf/run.sh idle             # the only scenario that needs no permissions
perf/run.sh --fresh all      # rebuild Release, relaunch, then measure
perf/run.sh request-permissions   # one-time grant, see below
```

## Scenarios and budgets

| Scenario | What it exercises | Budget |
| --- | --- | --- |
| `idle` | Hands off — the state the app spends its life in. 6 × 10 s buckets; buckets tainted by real user input (detected via `HIDIdleTime`) are discarded, and the quietest clean bucket is the idle floor. Needs at least one bucket with hands truly off. | ≤ 0.05 % CPU, ≤ 1 wakeup/s |
| `touchstorm` | Type-29 gesture events at 120 Hz — the listen-only touch tap's hot path (`NSEvent` bridging in `trackTouches`). This is what every scroll and swipe costs. | ≤ 100 µs CPU/event |
| `dragstorm` | `leftMouseDragged` at 120 Hz. The drag tap is enabled only while a remapped press is in flight, so at rest these must barely touch the app. | ≤ 5 µs CPU/event, ≤ 2 wakeups/s |
| `scrollcontrol` | Scroll events, which match no tap mask. Negative control: irrelevant HID traffic must not wake the app at all. | ≤ 0.05 % CPU, ≤ 2 wakeups/s |
| `latency` | Post → tail-tap round-trip of drag events — the delay WheelClick adds to everyone's input while its taps are in the path. | p95 ≤ 2 ms |
| `remap` | Functional end-to-end: an fn+left press posted into the session must come back as a middle press (down, drags, up — fn flag stripped), caught by the bench's own topmost window so nothing else reacts. | exactly 1 down/up, ≥ 1 drag, 0 wrong-button |

Storm budgets are for a **Release** build on Apple Silicon (`--fresh` builds
one); a Debug build will blow through them — that's expected, not a
regression. Exit code is non-zero when any budget fails, so the script works
in CI-ish loops.

## Magic Mouse acceptance (interactive)

The Magic Mouse path can't be tested synthetically — synthesized CGEvents
carry no NSTouch data, and the whole feature (the device split, finger
counts, the center band) lives on real touches. So its test scripts the
human instead:

```sh
perf/accept-magic-mouse.sh            # against the running app
perf/accept-magic-mouse.sh --fresh    # rebuild Release, relaunch, run
```

A floating window walks through nine checks — both surfaces classify
correctly (the `touch surface … -> magic mouse` log line), each of the four
gestures middle-clicks, an ordinary edge click and a switched-off gesture
stay left clicks, and the trackpad's three-finger click still works — then a
ten-second surface rub is rusage-sampled into µs CPU per gesture frame, the
first measured numbers for a future Magic Mouse energy rating. The harness
verdicts every step from a tail-appended listen-only tap plus the app's
debug log, saves/arms/restores your defaults around the run (Ctrl-C safe),
and exits non-zero if any check fails. Needs a paired Magic Mouse and the
same Accessibility grant as the scenarios above.

### How the 0.9 mW was arrived at

Written out because the script that produces it is not in the public mirror, and
a figure nobody can reproduce the procedure for is worth less than no figure.

Five phases, sampling `proc_pid_rusage` across **both** processes — the app and
the `WheelClickTouchHelper` that counts fingers:

1. **Baseline** — every Magic Mouse gesture off, hands off everything. The
   helper must not be running at all; if it is, that is a failure, not a
   measurement.
2. **Residency** — a gesture on and the mouse attached, hands still off. What
   the feature costs for merely existing.
3. **Load** — one finger rubbing the shell continuously, gesture on.
4. **Control** — the same rub, the same way, every gesture off. The difference
   between 3 and 4 is the feature; without this phase the number would also
   contain whatever the system does with a touched mouse.
5. **Return to rest**, which catches anything that fails to wind down.

A phase is discarded when `HIDIdleTime` shows real input arrived during a
hands-off window, so a stray touch cannot quietly inflate a floor. The published
0.9 mW is phase 3 minus phase 4, converted through the same 250.1 mJ per
CPU-second used everywhere else here.

## Permissions

`idle` needs nothing. Posting synthetic events and installing the latency
tap require the Accessibility grant for the *terminal* running the bench
(macOS attributes it to the host app). One-time setup:

```sh
perf/run.sh request-permissions
```

then allow the prompt (System Settings → Privacy & Security → Accessibility)
and re-run. Scenarios without their grant are skipped with a note, not
failed.

The drag/scroll storms are deliberately harmless: zero-delta events at the
current cursor position with no button actually down — nothing on screen
reacts to them.

## What rusage can't see

`ri_billed_energy` covers the app's own CPU only. The 5-second
Accessibility poll also wakes `tccd` via XPC — that cost lands on `tccd`'s
ledger, not ours. For the whole-system picture, run
`sudo powermetrics --show-process-energy -i 5000` and watch both processes.
