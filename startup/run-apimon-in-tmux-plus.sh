#!/bin/bash
session="oshealthmon"
export OS_CLOUD=plus-hm1
#export OS_CACERT=/etc/ca-cert-ciab.crt
tmux start-server
tmux new-session -d -s $session -n apimon1
tmux new-window -t $session:1 -n shell1
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
#tmux send-keys "export OS_CACERT=$OS_CACERT" C-m
tmux select-window -t $session:0
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
#tmux send-keys "export OS_CACERT=$OS_CACERT" C-m
tmux send-keys "./run_in_loop_pluspco.sh" C-m
export OS_CLOUD=plus-hm2
tmux new-window -t $session:2 -n apimon2
tmux new-window -t $session:3 -n shell2
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
tmux select-window -t $session:2
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
sleep 1
tmux send-keys "./run_in_loop_pluspco2.sh" C-m
export OS_CLOUD=plus-hm3
tmux new-window -t $session:4 -n apimon3
tmux new-window -t $session:5 -n shell3
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
tmux select-window -t $session:4
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
sleep 1
tmux send-keys "./run_in_loop_pluspco3.sh" C-m
export OS_CLOUD=plus-hm4
tmux new-window -t $session:6 -n apimon4
tmux new-window -t $session:7 -n shell4
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
tmux select-window -t $session:6
tmux send-keys "cd ~/openstack-health-monitor; export OS_CLOUD=$OS_CLOUD" C-m
sleep 1
tmux send-keys "./run_in_loop_pluspco4.sh" C-m
