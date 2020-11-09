api_monitor.sh
==============

This is a test script for testing the reliability and performance of OpenStack API.
It works by doing a real scenario test: Setting up a real environment
With routers, nets, jumphosts, disks, VMs, ...

We collect statistics on API call performance as well as on resource creation times.
Failures are noted and alarms are generated.

Status
------
- Errors not yet handled everywhere
- Live Volume and NIC attachment not yet implemented
- Log too verbose for permament operation ...
- Script allows to create multiple nets/subnets independent from no of AZs, which may need more testing.
- Done: Convert from neutron/cinder/nova/... to openstack (-o / -O)

TODO
----
- Align sendalarm with Grafana database entries

Copyright
---------
(c) Kurt Garloff <kurt.garloff@t-systems.com>, 2/2017-7/2017

License: CC-BY-SA (2.0)

Description of the flow
-----------------------
- create router (VPC)
- create 1+$NONETS (1+2) nets -- $NONETS is normally the # of AZs
- create 1+$NONETS subnets
- create security groups
- create virtual IP (for outbound SNAT via JumpHosts)
- create SSH keys
- create $NOAZS JumpHost VMs by
   a) creating disks (from image)
   b) creating ports
   c) creating VMs
- associating a floating IP to each Jumphost
- configuring the virtIP as default route
- JumpHosts do SNAT for outbound traffic and port forwarding for inbound
   (this requires SUSE images with SFW2-snat package to work)
- create N internal VMs striped over the nets and AZs by
   a) creating disks (from image) -- if option -d is not used
   b) creating a port -- if option -P is not used
   c) creating VM (from volume or from image, dep. on -d)
    (Steps a and c take long, so we do many in parallel and poll for progress)
   d) do some property changes to VMs
- after everything is complete, we wait for the VMs to be up
- we ping them, log in via ssh and see whether they can ping to the outside world (quad9)
- a full cross connectivity check (can each VM ping each other?) with -C
- we create a loadbalancer and check accessing all VMs as members (RR) with -L
- attach additional NICs and test (options -2, -3, -4)
- NOT YET: attach additional disks to running VMs
 
- Finally, we clean up ev'thing in reverse order
   (We have kept track of resources to clean up.
    We can also identify them by name, which helps if we got interrupted, or
    some cleanup action failed.)

Coverage
--------
So we end up testing: Router, incl. default route (for SNAT instance),
networks, subnets, and virtual IP, security groups and floating IPs,
volume creation from image, deletion after VM destruction,
VM creation from bootable volume (and from image if -d is given,)
Metadata service (without it ssh key injection fails of course),
Images (openSUSE OTC, upstream, CentOS and Ubuntu work),
Loadbalancer (-L),
Waiting for volumes and VMs,
Destroying all of these resources again

Alarming and reporting
----------------------
We do some statistics on the duration of the steps (min, avg, median, 95% quantile, max).
We of course also note any errors and timeouts and report these, optionally sending email of SMN alarms.

Runtime
-------
This takes rather long, as typical API calls take b/w 1 and 2s on OpenStack (including the round trip to keystone for the token).

Optimization possibilities:
Cache token and reuse when creating a large number of resources in a loop. 
Completed (use option -O (not used for volume create)).

Prerequisites
-------------
- Working python-XXXclient tools (openstack, glance, neutron, nova, cinder)
- `OS_` environment variables set to run openstack CLI commands (or OS_CLOUD with clouds.yaml/secure.yaml)
- otc.sh from otc-tools (only if using optional SMN -m and project creation -p)
- sendmail (only if email notification is requested)
- jq (for JSON processing)
- bc and python2 or 3 for math used to calc statistics
- Any image for the VMs that allows login as user DEFLTUSER (linux) with injected key
  (If we use -2/-3/-4, we also need a SUSE image to have the cloud-multiroute pkg in there.)

Usage
-----
Use `api_monitor.sh -h` to get a list of the command line options.

```
Usage: api_monitor.sh [options]
 --debug Use set -x to print every line executed
 -n N   number of VMs to create (beyond #AZ JumpHosts, def: 12)
 -N N   number of networks/subnets/jumphosts to create (def: # AZs)
 -l LOGFILE record all command in LOGFILE
 -a N   send at most N alarms per iteration (first plus N-1 summarized)
 -R     send recovery email after a completely successful iteration and alarms before
 -e ADR sets eMail address for notes/alarms (assumes working MTA)
         second -e splits eMails; notes go to first, alarms to second eMail
 -E     exit on error (for CONNTEST)
 -m URN sets notes/alarms by SMN (pass URN of queue)
         second -m splits notifications; notes to first, alarms to second URN
 -s     sends stats as well once per day, not just alarms
 -S [NM] sends stats to grafana via local telegraf http_listener (def for NM=api-monitoring)
 -q     do not send any alarms
 -d     boot Directly from image (not via volume)
 -P     do not create Port before VM creation
 -D     create all VMs with one API call (implies -d -P)
 -i N   sets max number of iterations (def = -1 = inf)
 -r N   only recreate router after each Nth iteration
 -g N   increase VM volume size by N GB (ignored for -d/-D)
 -G N   increase JH volume size by N GB
 -w N   sets error wait (API, VM): 0-inf seconds or neg value for interactive wait
 -W N   sets error wait (VM only): 0-inf seconds or neg value for interactive wait
 -V N   set success wait: Stop for N seconds (neg val: interactive) before tearing down
 -p N   use a new project every N iterations
 -c     noColors: don't use bold/red/... ASCII sequences
 -C     full Connectivity check: Every VM pings every other
 -o     translate nova/cinder/neutron/glance into openstack client commands
 -O     like -o, but use token_endpoint auth (after getting token)
 -x     assume eXclusive project, clean all floating IPs found
 -I     dIsassociate floating IPs before deleting them
 -L     create Loadbalancer (LBaaSv2/octavia) and test it
 -b     run a simple compute benchmark
 -B     run iperf3
 -t     long Timeouts (2x, multiple times for 3x, 4x, ...)
 -2     Create 2ndary subnets and attach 2ndary NICs to VMs and test
 -3     Create 2ndary subnets, attach, test, reshuffle and retest
 -4     Create 2ndary subnets, reshuffle, attach, test, reshuffle and retest
 -R     Recreate 2ndary ports after detaching (OpenStack <= Mitaka bug)
Or: api_monitor.sh [-f] CLEANUP XXX to clean up all resources with prefix XXX
        Option -f forces the deletion
Or: api_monitor.sh [Options] CONNTEST XXX for full conn test for existing env XXX
        Options: [-2/3/4] [-o/O] [-i N] [-e ADR] [-E] [-w/W/V N] [-l LOGFILE]
You need to have the OS_ variables set to allow OpenStack CLI tools to work.
You can override defaults by exporting the environment variables AZS, VAZS, RPRE,
 PINGTARGET, PINGTARGET2, GRAFANANM, [JH]IMG, [JH]IMGFILT, [JH]FLAVOR, [JH]DEFLTUSER,
 ADDJHVOLSIZE, ADDVMVOLSIZE, SUCCWAIT, ALARMPRE, FROM, ALARM_/NOTE_EMAIL_ADDRESSES[],
 NAMESERVER.
Typically, you should configure [JH]IMG, [JH]FLAVOR, [JH]DEFLTUSER.
```


Examples
--------
Run 100 loops deploying (and deleting) 2+8 VMs (including nets, volumes etc.),
with daily statistics sent to SMN...API-Notes and Alarms to SMN...APIMonitor:

```shell
./api_monitor.sh -n 8 -s -m urn:smn:eu-de:0ee085d22f6a413293a2c37aaa1f96fe:APIMon-Notes -m urn:smn:eu-de:0ee085d22f6a413293a2c37aaa1f96fe:APIMonitor -i 100
```

The included file `run.sh` also demonstrates how to use `api_monitor.sh`.

The script has been used successfully on several OpenStack clouds with keystone v3 (OTC, ECP, CityCloud),
started manually or from Jenkins, partially with recording stats to a local Telegraf to report timings
and failures into a Grafana dashboard.
