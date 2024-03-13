#!/bin/bash
echo "oshealthmon session going down" | wall
session="oshealthmon"
tmux select-window -t $session:0
# Tell master loop to exit
cd ~/openstack-health-monitor
touch stop-os-hm
# Send two ^C to the api_monitor for immediate cleanup
# Sidenote: If we are patient, we could just leave it with the touched stop file
tmux send-keys C-c
sleep 1
tmux send-keys C-c
tmux select-window -t $session:2
tmux send-keys C-c
sleep 1
tmux send-keys C-c
tmux select-window -t $session:4
tmux send-keys C-c
sleep 1
tmux send-keys C-c
tmux select-window -t $session:6
tmux send-keys C-c
sleep 1
tmux send-keys C-c
sync
tmux select-window -t $session:0
# Give it max 4min to cleanup and exit, so we don't delay a reboot by more than 5 mins
MAXW=242
let -i ctr=0
while test $ctr -lt $MAXW; do
	if test -z "$(ps a | grep run_in_loop_pluspco | grep -v grep)"; then break; fi
	sleep 1
	let ctr+=1
done
if test $ctr = $MAXW; then killall run_in_loop_pluspco.sh; killall run_in_loop_pluspco2.sh; killall run_in_loop_pluspco3.sh; sleep 1; fi
tmux kill-session -t $session
