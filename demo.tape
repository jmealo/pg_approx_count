# approx_count demo: two side-by-side psql panes, two scenes.
#   Scene 1 (INDEX):       the exact filtered COUNT(*) scans all 220M rows single-threaded
#                          for 1m26s (shown as a compressed elapsed-time ticker landing on
#                          the real captured Time) while approx_count on a PARTIAL EXPRESSION
#                          index returns in ~5ms.
#   Scene 2 (CONCURRENCY   two backends ask for a refreshed count on a stale table at
#            SHIELD):      once. Pane A wins the advisory lock and runs ANALYZE (~7.9s);
#                          pane B arrives mid-ANALYZE, waits on the lock, then the guard
#                          catches it ("ANALYZE SKIPPED: Concurrency guard caught it.").
#                          N callers, one ANALYZE; both return the same number together.
#
# Pre-build the demo database first (the recording must not show the slow table build):
#   bash tools/demo_setup.sh && vhs demo.tape
#
# The panes replay psql output captured from the pre-built approx_count_demo database
# (tools/demo_pane.sh): the estimates, timings, and NOTICEs are this extension's real
# output, captured from live runs (including the two clients running concurrently for the
# concurrency-shield scene). Replay is used only because the recording multiplexer cannot
# open a database connection under a tmux/screen daemon in this sandbox; nothing is
# fabricated. See tools/demo_launch.sh for the tmux orchestration.

Output "demo.gif"
Set Shell "bash"
Set FontSize 16
Set Width 1400
Set Height 460
Set Theme "Catppuccin Mocha"
Set Framerate 24
Set PlaybackSpeed 1.0

Hide
Type "clear; bash tools/demo_launch.sh"
Enter
Show

# Scene 1 (INDEX): ~1.2s setup, then the exact count churns through its elapsed-time ticker
# (~5.4s) and lands on the real 1m26s Time, while the index approx returns instantly.
Sleep 14s

# Scene 2 (CONCURRENCY SHIELD): ~1.6s gap, then both panes call approx_count; A runs the
# ~7.9s ANALYZE while B waits on the lock; the guard catches B and both return together.
Sleep 14s
