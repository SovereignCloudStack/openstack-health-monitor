# How to enable autostart for OpenStack Health Monitor (aka apimon).

## Preparation
* Checkout a copy of openstack health monitor
  `git clone https://github.com/SovereignCloudStack/openstack-health-monitor`
* Install the python3-openstackclient tools
* Configure your cloud access in `~/.config/openstack/clouds.yaml` and
  `secure.yaml`
* Ensure your openstack client tools work:
  ```
  export OS_CLOUD=YOURCLOUD
  openstack image list
  ```
* Ensure that apimon works
  `./api_monitor.sh -O -C -D -N 2 -n 8 -L -b -B -T -i 1`
  This will run one iteration of the monitor, creating 10 VMs with default
  flavors (SCS-1V-2 and SCS-1L-1) and images (Ubuntu 22.04).
  This will take 5 to 10 minutes.
  The option `-L` enables the loadbalancer testing; you might have to remove
  it if your cloud does not support octavia/lbaasv2.
  See `./api_monitor.sh --help` for an overview over options.
* Create a run script by copying e.g. `run_wave.sh` and editing it according
  to your needs.
* Create a file `run_in_loop.sh` which runs `run_YOURCLOUD.sh` in a loop:
  ```
  #!/bin/bash
  rm stop-os-hm 2>/dev/null
  while true; do
    ./run_YOURCLOUD.sh -s -i 200
    if test -e stop-os-hm; then break; fi
    echo -n "Hit ^C to abort ..."
    sleep 15; echo
  done
  ```
  This will run 200 iterations in `api_monitor.sh` and then restart.

## System startup
* Edit the tmux startup script `run-apimon-in-tmux.sh` to set `OS_CLOUD`
  correctly for your cloud.
* If you are not using ~/openstack-health-monitor for the checked out git
  tree, you need to adjust the scripts and the systemd unit file here
  accordingly.
* Copy `apimon.service` to `~/.config/systemd/user`. (You might need to
  create that directory first.)
* Test that you can start the service by calling 
  `systemctl --user start apimon`
* This should create a tmux session in which the OpenStack Health Momitor
  is running.  Attach to the tmux session `tmux attach -t oshealthmon`.
* The apimon service uses `run-apimon-in-tmux.sh` and `kill-apimon-in-tmux.sh`
  scripts for startup and stopping. There are also scripts that open four
  pairs of windows to start 4 jobs and kill 4 jobs wiht `-plus` in the name.
* You can stop the service by hitting ^C (Control-c), possibly several times.
* Now enable the service: `systemctl --user enable apimon`
* And tell systemd that it should create a user session on startup:
  `sudo loginctl enable-linger $USER`
