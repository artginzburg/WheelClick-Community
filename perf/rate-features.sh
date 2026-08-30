#!/bin/zsh
# Measures the marginal energy cost of each user-facing feature and writes
# WheelClick/Resources/EnergyRatings.json — the data behind the traffic-light
# dots in the menu. Run it after changing anything in the event path, then
# rebuild the app so the bundle picks up the fresh numbers.
#
# Method: for each feature alone (the other two off), restart the app and
# run the bench's 120 Hz gesture storm; the app's CPU per touch event is the
# feature's cost while a hand is on the trackpad, which is where all the
# energy goes (idle cost is shared and near zero). fn+Click keeps the touch
# tap suspended, so its storm reads ~0. Keep hands off the trackpad during
# the ~2 minute run — real touches inflate the numbers.
#
# Needs the bench's one-time Accessibility grant (perf/run.sh
# request-permissions). The bench runs via launchctl so the grant attaches
# to the bench binary itself, not to whichever terminal runs this script.
set -euo pipefail
cd "$(dirname "$0")/.."
source perf/lib.sh

# The prefs domain is addressed by file path, not by bundle id: a stale
# sandbox container from an early build still exists under
# ~/Library/Containers, and the defaults CLI silently routes the named
# domain there — while the (unsandboxed) app reads the host plist.
APP_ID=$HOME/Library/Preferences/art.ginzburg.WheelClick
# The scheme's Release configuration is Release-Direct, so this is derived
# rather than spelled out (see built_release_app in lib.sh).
APP=$(built_release_app)
BENCH=$PWD/perf/.build/energybench
OUT=WheelClick/Resources/EnergyRatings.json
# Every toggle a measurement flips. plugin.swipeAction is a string (off /
# volume / brightness), the rest are booleans. The four magicMouse.* keys
# must be zeroed too: threeFingerClick defaults to true there, and
# TapController's touchTapWanted ORs in magicMouse.wantsTouchStream — left
# alone, that keeps the touch tap alive throughout every measurement below,
# even the one (fn+Click) whose whole point is that it *doesn't* need it.
BOOL_KEYS=(threeFingerClick fnClick threeFingerTap forceClick plugin.middleDragTapHold
           magicMouse.centerClick magicMouse.twoFingerClick magicMouse.threeFingerClick magicMouse.threeFingerTap)
STRING_KEYS=(plugin.swipeAction plugin.autoScrollTrigger)
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

[[ -x $BENCH ]] || { echo "bench missing — run perf/run.sh first"; exit 2 }
[[ -d $APP ]] || { echo "Release app missing — run perf/run.sh --fresh first"; exit 2 }

# Remember the user's settings (or their absence) to restore afterwards.
# defaults prints booleans as 0/1 but only accepts true/false back.
typeset -A saved
for key in $BOOL_KEYS; do
    case $(defaults read $APP_ID $key 2>/dev/null || echo unset) in
        1) saved[$key]=true ;;
        0) saved[$key]=false ;;
        *) saved[$key]=unset ;;
    esac
done
for key in $STRING_KEYS; do
    saved[$key]=$(defaults read $APP_ID $key 2>/dev/null || echo unset)
done
restore() {
    for key in $BOOL_KEYS; do
        if [[ ${saved[$key]} == unset ]]; then
            defaults delete $APP_ID $key 2>/dev/null || true
        else
            defaults write $APP_ID $key -bool ${saved[$key]}
        fi
    done
    for key in $STRING_KEYS; do
        if [[ ${saved[$key]} == unset ]]; then
            defaults delete $APP_ID $key 2>/dev/null || true
        else
            defaults write $APP_ID $key -string ${saved[$key]}
        fi
    done
    pkill -9 -x WheelClick 2>/dev/null || true
    sleep 1
    open "$APP"
}
trap 'restore; rm -rf "$SCRATCH"' EXIT

# Blocks until the app has been near-idle for a 3 s window, so a storm
# measures the storm and not whatever the user was doing with the
# trackpad. (HIDIdleTime can't be the detector here: the bench's own
# posted events reset it.)
wait_for_quiet() {
    local pid=$(pgrep -x WheelClick | head -1)
    for _ in {1..40}; do
        local t0=$(ps -o cputime= -p $pid | tr -d ' ' | awk -F'[:.]' '{print ($1*60+$2)*100+$3}')
        sleep 3
        local t1=$(ps -o cputime= -p $pid | tr -d ' ' | awk -F'[:.]' '{print ($1*60+$2)*100+$3}')
        (( t1 - t0 <= 2 )) && return 0   # ≤20 ms CPU over 3 s
    done
    echo "  warning: machine never went quiet — numbers may be inflated"
}

# Turn every gesture off, then enable just the one under test — so each
# number is that feature's cost in isolation (the touch tap it needs, plus its
# own per-event work), not muddied by another feature sharing the hot path.
configure() { # $1 = feature id
    for k in $BOOL_KEYS; do defaults write $APP_ID $k -bool false; done
    defaults write $APP_ID plugin.swipeAction -string off
    defaults write $APP_ID plugin.autoScrollTrigger -string off
    case $1 in
        threeFingerClick) defaults write $APP_ID threeFingerClick -bool true ;;
        fnClick)          defaults write $APP_ID fnClick -bool true ;;
        threeFingerTap)   defaults write $APP_ID threeFingerTap -bool true ;;
        forceClick)       defaults write $APP_ID forceClick -bool true ;;
        pluginMiddleDrag) defaults write $APP_ID plugin.middleDragTapHold -bool true ;;
        pluginSwipe)      defaults write $APP_ID plugin.swipeAction -string volume ;;
    esac
}

# One measurement: isolate the feature, restart the app, storm it.
measure() { # $1 = feature id -> prints µs/event
    configure $1
    pkill -9 -x WheelClick 2>/dev/null || true
    sleep 1
    open "$APP"
    sleep 3
    wait_for_quiet >&2
    local label=com.wheelclick.eb.rate log=$SCRATCH/storm.log
    launchctl remove $label 2>/dev/null || true
    rm -f $log
    launchctl submit -l $label -o $log -e /dev/null -- $BENCH touchstorm
    for _ in {1..40}; do
        grep -q "µs CPU per event" $log 2>/dev/null && break
        sleep 1
    done
    launchctl remove $label 2>/dev/null || true
    grep -oE "[0-9]+\.[0-9]+ µs CPU per event" $log | cut -d' ' -f1
}

# Autoscroll can't be stormed — it's a self-driven timer, not a per-event cost.
# Configure the app to enter it on fn+click, restart, and run the bench's
# `autoscroll` scenario, which drives a real session and reports mW while it
# actively scrolls. Prints mW, or nothing if the session never started.
measure_autoscroll() { # -> prints mW while active
    for k in $BOOL_KEYS; do defaults write $APP_ID $k -bool false; done
    defaults write $APP_ID plugin.swipeAction -string off
    defaults write $APP_ID fnClick -bool true
    defaults write $APP_ID plugin.autoScrollTrigger -string fnClick
    pkill -9 -x WheelClick 2>/dev/null || true
    sleep 1
    open "$APP"
    sleep 3
    wait_for_quiet >&2
    local label=com.wheelclick.eb.autoscroll log=$SCRATCH/autoscroll.log
    launchctl remove $label 2>/dev/null || true
    rm -f $log
    launchctl submit -l $label -o $log -e /dev/null -- $BENCH autoscroll
    for _ in {1..40}; do
        grep -qE "mW while scrolling|skipped:" $log 2>/dev/null && break
        sleep 1
    done
    launchctl remove $label 2>/dev/null || true
    grep -oE "[0-9]+\.[0-9]+ mW while scrolling" $log | cut -d' ' -f1
}

# One yardstick for every feature: milliwatts while the thing is in use.
#
# There used to be two, and they disagreed by two orders of magnitude — µs per
# event called 10 µs the edge of "negligible" (0.23 mW at 90 events a second),
# while the milliwatt rule put that edge at 25 mW. Nothing had fallen between
# them until the Magic Mouse did, at 0.9 mW: green by one rule, yellow by the
# other, in a menu where it sits directly beneath its trackpad twin. The
# boundaries below are the µs ones converted through this machine's own
# references, so every rating already shipped keeps exactly the verdict a human
# reviewed — fnClick and autoscroll stay negligible, the trackpad gestures stay
# moderate — and the two scales can no longer contradict each other.
milliwatts_from_micros() { # µs/event -> mW while a hand is on the trackpad
    # 90 touch events a second is the same figure the JSON publishes as
    # touchEventsPerSecond; mj_cpu is measured by the reference probe below and
    # falls back to its default until then.
    python3 -c "print($1 / 1e6 * 90 * ${mj_cpu:-250.1})"
}

tier_mw() { # mW while in use -> rating tier
    python3 -c "
mw = $1
print('negligible' if mw < 0.225 else 'moderate' if mw < 11.25 else 'heavy')"
}

tier() { # µs/event -> rating tier, through the shared milliwatt scale
    tier_mw "$(milliwatts_from_micros "$1")"
}

# Reference points for the human-readable card in the menu: what the menu
# bar clock (Control Center draws it) averages on this machine, what a CPU
# second costs in energy here, and the battery's design capacity. Taken
# before the storms, while the long-running instances still carry clean
# lifetime averages.
# The Magic Mouse cannot be measured from here: its gestures need a real hand
# on real hardware, so perf/measure-magic-mouse.sh measures them and the figure
# is carried over rather than recomputed. Regenerating the ratings must not
# silently drop it -- and must not invent one either, hence the explicit
# fallback to null when there is nothing to carry.
magic_mouse_block=$(python3 - "$OUT" <<'CARRY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.dumps(json.load(f).get("magicMouse")))
except Exception:
    print("null")
CARRY
)

PROBE=perf/.build/rusageprobe
if [[ ! -x $PROBE || perf/EnergyBench/RusageProbe.swift -nt $PROBE ]]; then
    swiftc -O perf/EnergyBench/RusageProbe.swift -o $PROBE
fi
# Control Center supplies both the clock's average draw and the energy
# cost of a CPU second: it has been up for hours doing UI-class work, so
# its ledger is stable. WheelClick's own instances are seconds old at
# script time and their ratio swings 19-173 mJ/cpu-s with the launch
# burst; Control Center's reads consistently (and conservatively — it
# came out ~3x above a long-lived WheelClick session, so the energy
# claims round pessimistically, never optimistically).
cc_line=$($PROBE $(pgrep -x ControlCenter | head -1))
clock_mw=$(echo $cc_line | grep -oE 'avg_mw=[0-9.]+' | cut -d= -f2)
mj_cpu=$(echo $cc_line | grep -oE 'mj_per_cpu_s=[0-9.]+' | cut -d= -f2)
[[ ${mj_cpu%.*} -gt 0 ]] || mj_cpu=150
# Design capacity (mAh) at the 3-cell nominal 11.4 V.
battery_wh=$(ioreg -rn AppleSmartBattery | awk -F'= ' '/"DesignCapacity" =/ {printf "%.1f", $2 * 11.4 / 1000}')
echo "References: clock ${clock_mw} mW, ${mj_cpu} mJ/cpu-s, battery ${battery_wh} Wh"

# What the statistics ledger itself costs — the About window quotes this.
# Built from the app's own UsageStats.swift, so it measures the production
# code path. The bench CLI writes throwaway defaults under its own name.
STATS_DIR=$(mktemp -d)
cp WheelClick/Core/UsageStats.swift WheelClick/Helpers/SchemaMigration.swift perf/EnergyBench/StatsOverhead/main.swift "$STATS_DIR/"
swiftc -O "$STATS_DIR/main.swift" "$STATS_DIR/UsageStats.swift" "$STATS_DIR/SchemaMigration.swift" -o "$STATS_DIR/statsbench"
stats_line=$("$STATS_DIR/statsbench")
defaults delete statsbench 2>/dev/null || true
rm -rf "$STATS_DIR"
ns_per_record=$(echo $stats_line | grep -oE 'ns_per_record=[0-9.]+' | cut -d= -f2)
us_per_flush=$(echo $stats_line | grep -oE 'us_per_flush=[0-9.]+' | cut -d= -f2)
echo "Stats overhead: ${ns_per_record} ns/record, ${us_per_flush} µs/flush"

# What the per-app filter's gate costs on a candidate remap — the detection
# toggle's honesty. Built from the app's own AppScope/AppIdentity/AppInventory,
# so it measures the production path. The under-cursor figure is a real
# Accessibility hit-test only when the bench is trusted (ax_trusted=yes);
# untrusted it fast-fails, so treat it as unmeasured.
# Built to a stable path (not a temp dir) so its one-time Accessibility grant
# survives between runs — a fresh binary each time would drop the AX trust the
# under-cursor figure needs. Rebuilt only when a source is newer than it.
FILTERBENCH=perf/.build/filterbench
FILTER_SRCS=(WheelClick/Core/AppIdentity.swift WheelClick/Core/AppScope.swift
             WheelClick/Core/AppInventory.swift WheelClick/Core/EventTap.swift
             WheelClick/Helpers/SchemaMigration.swift perf/EnergyBench/FilterOverhead/main.swift)
filter_stale=0
[[ -x $FILTERBENCH ]] || filter_stale=1
for src in $FILTER_SRCS; do [[ $src -nt $FILTERBENCH ]] && filter_stale=1; done
if (( filter_stale )); then
    swiftc -O -default-isolation MainActor -enable-upcoming-feature ApproachableConcurrency \
        $FILTER_SRCS -o $FILTERBENCH
    sign_bench $FILTERBENCH filterbench
fi
# Run through launchctl so the Accessibility grant attaches to the bench
# binary, not to the terminal — the under-cursor hit-test needs AX trust, and
# TCC otherwise credits the parent process (same reason measure() does below).
filter_log=$SCRATCH/filter.log
launchctl remove com.wheelclick.eb.filter 2>/dev/null || true
rm -f $filter_log
launchctl submit -l com.wheelclick.eb.filter -o $filter_log -e /dev/null -- $PWD/$FILTERBENCH
for _ in {1..20}; do grep -q 'ax_trusted=' $filter_log 2>/dev/null && break; sleep 1; done
launchctl remove com.wheelclick.eb.filter 2>/dev/null || true
filter_line=$(cat $filter_log 2>/dev/null)
defaults delete filterbench 2>/dev/null || true
ax_trusted=$(echo $filter_line | grep -oE 'ax_trusted=[a-z]+' | cut -d= -f2)
ns_all=$(echo $filter_line | grep -oE 'ns_all=[0-9.]+' | cut -d= -f2)
ns_frontmost=$(echo $filter_line | grep -oE 'ns_frontmost=[0-9.]+' | cut -d= -f2)
us_undercursor=$(echo $filter_line | grep -oE 'us_undercursor=[0-9.]+' | cut -d= -f2)
# Untrusted, the AX call fast-fails, so the number is meaningless — write null
# rather than a figure that would read as a real measurement.
if [[ $ax_trusted == yes ]]; then us_undercursor_json=$us_undercursor; else us_undercursor_json=null; fi
echo "Filter overhead: ${ns_all} ns/gate (all apps), ${ns_frontmost} ns/gate (frontmost); ${us_undercursor} µs/gate (under-cursor, ax_trusted=${ax_trusted})"

echo "Measuring Three-Finger Click alone..."
threeFinger=$(measure threeFingerClick)
echo "  ${threeFinger} µs/event"
echo "Measuring fn+Click alone..."
fn=$(measure fnClick)
echo "  ${fn} µs/event"
echo "Measuring Three-Finger Tap alone..."
tap=$(measure threeFingerTap)
echo "  ${tap} µs/event"
echo "Measuring Force Click alone..."
force=$(measure forceClick)
echo "  ${force} µs/event"
echo "Measuring Middle-Drag plugin alone..."
middleDrag=$(measure pluginMiddleDrag)
echo "  ${middleDrag} µs/event"
echo "Measuring Swipe plugin alone..."
swipe=$(measure pluginSwipe)
echo "  ${swipe} µs/event"
echo "Measuring Autoscroll plugin (active session)..."
autoscroll_mw=$(measure_autoscroll)
if [[ -n $autoscroll_mw ]]; then
    echo "  ${autoscroll_mw} mW while scrolling"
    autoscroll_json="{ \"milliwattsWhileActive\": $autoscroll_mw, \"tier\": \"$(tier_mw $autoscroll_mw)\" }"
else
    echo "  (session didn't start or no grant — writing null)"
    autoscroll_json=null
fi

mkdir -p "$(dirname $OUT)"
cat > $OUT <<EOF
{
  "comment": "Generated by perf/rate-features.sh from live measurements — do not edit by hand.",
  "generated": "$(date +%Y-%m-%d)",
  "machine": "$(sysctl -n hw.model)",
  "chip": "$(sysctl -n machdep.cpu.brand_string)",
  "metric": "app CPU microseconds per trackpad touch event, 120 Hz synthetic gesture storm, Release build, feature enabled alone",
  "references": {
    "menuBarClockMilliwatts": $clock_mw,
    "millijoulesPerCpuSecond": $mj_cpu,
    "batteryWattHours": $battery_wh,
    "touchEventsPerSecond": 90,
    "assumedTouchSecondsPerDay": 14400
  },
  "statsOverhead": {
    "nanosecondsPerRecord": $ns_per_record,
    "microsecondsPerFlush": $us_per_flush
  },
  "filterOverhead": {
    "nanosecondsPerGateAllApps": $ns_all,
    "nanosecondsPerGateFrontmost": $ns_frontmost,
    "microsecondsPerGateUnderCursor": $us_undercursor_json,
    "underCursorAxTrusted": "$ax_trusted"
  },
  "magicMouse": $magic_mouse_block,
  "autoScroll": $autoscroll_json,
  "features": {
    "threeFingerClick": { "microsPerEvent": $threeFinger, "tier": "$(tier $threeFinger)" },
    "fnClick": { "microsPerEvent": $fn, "tier": "$(tier $fn)" },
    "threeFingerTap": { "microsPerEvent": $tap, "tier": "$(tier $tap)" },
    "forceClick": { "microsPerEvent": $force, "tier": "$(tier $force)" },
    "pluginMiddleDrag": { "microsPerEvent": $middleDrag, "tier": "$(tier $middleDrag)" },
    "pluginSwipe": { "microsPerEvent": $swipe, "tier": "$(tier $swipe)" }
  }
}
EOF
echo "Wrote $OUT — rebuild the app to bundle it."
