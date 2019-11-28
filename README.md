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
- NOT YET: attach an additional disk
- NOT YET: attach an additional NIC
- NOT YET: Load-Balancer
 
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
Images (we use openSUSE for the jumphost for SNAT/port-fwd and CentOS7 by dflt for VMs),
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
- otc.sh from otc-tools (only if using optional SMN -m and project creation -p)
- sendmail (only if email notification is requested)
- jq (for JSON processing)
- python2 or 3 for math used to calc statistics
- SUSE image with SNAT/port-fwd (SuSEfirewall2-snat pkg) for the JumpHosts
- Any image for the VMs that allows login as user DEFLTUSER (linux) with injected key
  (If we use -2/-3/-4, we also need a SUSE image to have the cloud-multiroute pkg in there.)

Example
-------
Run 100 loops deploying (and deleting) 2+8 VMs (including nets, volumes etc.),
with daily statistics sent to SMN...API-Notes and Alarms to SMN...APIMonitor

```shell
./api_monitor.sh -n 8 -s -m urn:smn:eu-de:0ee085d22f6a413293a2c37aaa1f96fe:APIMon-Notes -m urn:smn:eu-de:0ee085d22f6a413293a2c37aaa1f96fe:APIMonitor -i 100
```

The included file `run.sh` also demonstrates how to use `api_monitor.sh`.


