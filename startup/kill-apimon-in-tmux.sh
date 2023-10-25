#!/bin/bash
session="oshealthmon"
tmux select-window -t $session:0
tmux send-keys C-c
sleep 30
killall run_in_loop.sh
sleep 5
tmux kill-session -t $session
