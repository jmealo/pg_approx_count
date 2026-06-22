#!/usr/bin/env bash
# Orchestrates the two-pane approx_count demo for VHS. Creates a side-by-side tmux
# split, runs tools/demo_pane.sh in each pane, and paces the two scenes by dropping
# sync markers. Invoked from demo.tape.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/demo_tmux.conf"
SYNC_DIR=/tmp/approx_demo_sync
SOCK=approxdemo

export SYNC_DIR
rm -rf "$SYNC_DIR"; mkdir -p "$SYNC_DIR"

tmux -L "$SOCK" -f "$CONF" kill-server 2>/dev/null || true
tmux -L "$SOCK" -f "$CONF" new-session -d -s d -x "${COLS:-204}" -y "${ROWS:-26}" "SYNC_DIR=$SYNC_DIR bash $HERE/demo_pane.sh left"
tmux -L "$SOCK" -f "$CONF" split-window -h -t d "SYNC_DIR=$SYNC_DIR bash $HERE/demo_pane.sh right"
tmux -L "$SOCK" -f "$CONF" select-pane -t d.0 -T 'exact COUNT(*)  .  session A'
tmux -L "$SOCK" -f "$CONF" select-pane -t d.1 -T 'approx_count  .  session B'
tmux -L "$SOCK" -f "$CONF" select-pane -t d.0

# Director: releases each scene once panes are ready, then waits for completion.
(
  sleep 1.2
  : > "$SYNC_DIR/scene1_go"
  # Scene 1 (INDEX) ends when both the slow filtered count and the instant index approx have printed.
  while [ ! -f "$SYNC_DIR/count_done" ] || [ ! -f "$SYNC_DIR/approx_done" ]; do sleep 0.05; done
  sleep 1.6
  : > "$SYNC_DIR/scene2_go"
  # Scene 2 (CONCURRENCY SHIELD) ends when both panes have returned.
  while [ ! -f "$SYNC_DIR/left_done" ] || [ ! -f "$SYNC_DIR/right_done" ]; do sleep 0.05; done
  sleep 3.0
  tmux -L "$SOCK" -f "$CONF" kill-server 2>/dev/null || true
) &

tmux -L "$SOCK" -f "$CONF" attach -t d
