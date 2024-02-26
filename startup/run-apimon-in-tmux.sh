#!/bin/bash
session="oshealthmon"
export OS_CLOUD=wave-hm
#export OS_CACERT=/etc/ca-cert-ciab.crt
tmux start-server
tmux new-session -d -s $session -n apimon
tmux new-window -t $session:1 -n shell
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
#tmux send-keys "export OS_CLOUD=$OS_CACERT" C-m
tmux select-window -t $session:0
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
#tmux send-keys "export OS_CLOUD=$OS_CACERT" C-m
tmux send-keys "./run_in_loop.sh" C-m

