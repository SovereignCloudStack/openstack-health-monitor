#!/bin/bash
echo "oshealthmon session going down" | wall
session="oshealthmon"
tmux select-window -t $session:0
# Tell master loop to exit
cd ~/openstack-health-monitor
touch stop-os-hm
# Send two ^C to the api_monitor for immediate cleanup
tmux send-keys C-c
sleep 1
tmux send-keys C-c
sync
# Give it max 4min to cleanup and exit, so we don't delay a reboot by more than 5 mins
MAXW=240
let -i ctr=0
while test $ctr -lt $MAXW; do
	if test -z "$(ps a | grep run_in_loop.sh | grep -v grep)"; then break; fi
	sleep 1
	let ctr+=1
done
if test $ctr = $MAXW; then killall run_in_loop.sh; sleep 1; fi
tmux kill-session -t $session
