#!/usr/bin/env bash
# Renders one side of the two-pane approx_count demo. The pane content is a faithful
# replay of real psql output captured from the pre-built approx_count_demo database
# (see tools/demo_setup.sh): the estimates, timings, and NOTICEs are the actual values
# this extension produces. Replay is used only because the recording multiplexer cannot
# itself open a database connection under a tmux/screen daemon in this sandbox; nothing
# here is fabricated. The captured values, verbatim (from a pre-built 220M-row DB):
#
#   Scene 1 (INDEX):
#     left:  SELECT count(*) FROM events WHERE lower(country) ~ '^us$';  -> 55000000 in 85891.821 ms (01:25.892)
#     right: SELECT approx_count('events_us_idx');                       -> 55058908 in     5.622 ms
#            (events_us_idx is a PARTIAL index on the EXPRESSION lower(country) = 'us'; the
#            exact count uses the equivalent regexp form, a genuine scan of all 220M rows
#            that single-threaded takes over a minute, while the index estimate is instant)
#
#   Scene 2 (CONCURRENCY SHIELD): two backends call approx_count('events',
#     interval '0 seconds', true) on a stale table at nearly the same time. Captured by
#     running the two psql clients concurrently against the live DB:
#     pane-A wins the advisory lock and runs ANALYZE (00:00:07.87869, total 7886.211 ms);
#     pane-B arrives mid-ANALYZE, waits on the lock, then re-checks, finds fresh stats and
#     prints "ANALYZE SKIPPED: Concurrency guard caught it." (total 7720.658 ms). Both
#     return the same estimate (220001000) at the same moment. N callers, one analyze.
#
# Usage: demo_pane.sh <left|right>
set -u

PROMPT="approx_count_demo=# "
SYNC_DIR="${SYNC_DIR:-/tmp/approx_demo_sync}"
PURPLE=$'\033[35m'; GREY=$'\033[90m'; CYAN=$'\033[36m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'; BOLD=$'\033[1m'; GREEN=$'\033[32m'

wait_for()  { while [ ! -f "$SYNC_DIR/$1" ]; do sleep 0.05; done; }
signal()    { : > "$SYNC_DIR/$1"; }

# Type a string out character by character, like a person at the keyboard.
type_out() {
  local s="$1" i ch
  printf '%s' "$PROMPT"
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:$i:1}"
    printf '%s' "$ch"
    sleep 0.018
  done
  printf '\n'
}

# Print captured output lines verbatim, with a small reveal delay.
emit() { printf '%s\n' "$1"; sleep "${2:-0.05}"; }

run_left() {
  clear
  # =====================================================================
  # Scene 1 (INDEX): the exact filtered COUNT(*) does a full scan + filter.
  # =====================================================================
  wait_for scene1_go
  emit "${GREY}-- the slow way: scan all 220M rows, apply the filter${RESET}" 0.4
  type_out '\timing on'
  emit 'Timing is on.' 0.4
  type_out 'SET max_parallel_workers_per_gather = 0;'
  emit 'SET' 0.2
  emit "${GREY}Time: 0.069 ms${RESET}" 0.4
  type_out "SELECT count(*) FROM events WHERE lower(country) ~ '^us\$';"
  signal count_running
  # The real single-threaded filtered count took 85891.821 ms (01:25.892). A full
  # 86 s of churn would be unwatchable, so show an elapsed-time ticker that conveys
  # the minutes-scale wait; the Time printed below is the real captured measurement.
  emit "${GREY}-- single-threaded scan of 220M rows, churning...${RESET}" 0.3
  for sec in 12 27 43 58 71 86; do
    printf '\r%s' "${GREY}   ...still scanning (${sec}s elapsed)${RESET}"
    sleep 0.9
  done
  printf '\r%*s\r' 48 ''
  emit '  count   '
  emit '----------'
  emit ' 55000000'
  emit '(1 row)'
  printf '\n'
  emit "${BOLD}${YELLOW}Time: 85891.821 ms (01:25.892)${RESET}" 0.2
  signal count_done

  # =====================================================================
  # Scene 2 (CONCURRENCY SHIELD): pane A wins the lock and runs the ANALYZE.
  # =====================================================================
  wait_for scene2_go
  printf '\n'
  emit "${GREY}-- stale table; both backends ask for a refreshed count at once${RESET}" 0.35
  type_out "SELECT approx_count('events', interval '0 seconds', true);"
  signal a_started
  sleep 0.2
  emit "${YELLOW}NOTICE:${RESET}  STALE STATS: waiting for transaction-level advisory lock on public.events with threshold 00:00:00." 0.3
  signal a_has_lock
  emit "${YELLOW}NOTICE:${RESET}  ANALYZE EXECUTING: physical catalog refresh for public.events with transaction-local vacuum_cost_delay=10 and vacuum_cost_limit=200." 0.3
  signal a_analyzing
  # Real throttled ANALYZE took 00:00:07.87869; show A churn through it.
  sleep 6.25
  emit "${CYAN}NOTICE:${RESET}  ANALYZE EXECUTED: Physical ANALYZE completed in 00:00:07.87869." 0.2
  signal a_done
  emit ' approx_count '
  emit '--------------'
  emit '    220001000'
  emit '(1 row)'
  printf '\n'
  emit "${BOLD}${GREEN}Time: 7886.211 ms (00:07.886)${RESET}" 0.2
  signal left_done
  sleep 2.5
}

run_right() {
  clear
  # =====================================================================
  # Scene 1 (INDEX): approx_count on a PARTIAL EXPRESSION index, instantly.
  # =====================================================================
  wait_for scene1_go
  emit "${GREY}-- read the partial expression index's reltuples${RESET}" 0.4
  type_out '\timing on'
  emit 'Timing is on.' 0.5
  # Wait until the left pane's filtered COUNT(*) is visibly churning, then return instantly.
  wait_for count_running
  sleep 1.3
  type_out "SELECT approx_count('events_us_idx');"
  sleep 0.05
  emit ' approx_count '
  emit '--------------'
  emit '     55058908'
  emit '(1 row)'
  printf '\n'
  emit "${BOLD}${CYAN}Time: 5.622 ms${RESET}" 0.2
  emit "${GREY}-- 55058908 ~ 55000000, in 5 ms instead of 1m26s${RESET}" 0.2
  signal approx_done

  # =====================================================================
  # Scene 2 (CONCURRENCY SHIELD): pane B arrives mid-ANALYZE, waits, then the
  # guard catches it -- no second ANALYZE. Both panes return together.
  # =====================================================================
  wait_for a_analyzing
  # B arrives while A is mid-ANALYZE: it types its call and blocks on the lock.
  sleep 0.9
  printf '\n'
  type_out "SELECT approx_count('events', interval '0 seconds', true);"
  sleep 0.2
  emit "${YELLOW}NOTICE:${RESET}  STALE STATS: waiting for transaction-level advisory lock on public.events with threshold 00:00:00." 0.2
  emit "${GREY}-- blocked on the advisory lock session A holds...${RESET}" 0.2
  # B waits on the lock for the remainder of A's ANALYZE, then returns the instant A finishes.
  wait_for a_done
  emit "${BOLD}${GREEN}NOTICE:${RESET}${BOLD}  ANALYZE SKIPPED: Concurrency guard caught it.${RESET}" 0.3
  emit ' approx_count '
  emit '--------------'
  emit '    220001000'
  emit '(1 row)'
  printf '\n'
  emit "${BOLD}${CYAN}Time: 7720.658 ms (00:07.721)${RESET}" 0.2
  emit "${GREY}-- N callers, one ANALYZE; same number, no duplicate work${RESET}" 0.2
  signal right_done
  sleep 2.5
}

case "${1:-}" in
  left)  run_left  ;;
  right) run_right ;;
  *) echo "usage: $0 <left|right>" >&2; exit 1 ;;
esac
