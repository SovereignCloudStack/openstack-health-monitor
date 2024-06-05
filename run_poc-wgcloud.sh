#!/bin/bash

# Specify image names, JumpHost ideally has sfw2-snat
# Options for the images: my openSUSE 15.2 (linux), Ubuntu 20.04 (ubuntu),
#  openSUSE Leap 15.2 (opensuse), CentOS 8 (centos)
# You can freely mix ...
export JHIMG="Debian 12"
export IMG="Debian 12"

# Terminate early on auth error
openstack server list >/dev/null || exit 1

# Find Floating IPs
FIPLIST=""
FIPS=$(openstack floating ip list -f value -c ID)
for fip in $FIPS; do
	FIP=$(openstack floating ip show $fip | grep -o "APIMonitor_[0-9]*")
	if test -n "$FIP"; then FIPLIST="${FIPLIST}${FIP}_
"; fi
done
FIPLIST=$(echo "$FIPLIST" | grep -v '^$' | sort -u)
# Cleanup previous interrupted runs
SERVERS=$(openstack server  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
KEYPAIR=$(openstack keypair list | grep -o "APIMonitor_[0-9]*_" | sort -u)
VOLUMES=$(openstack volume  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
NETWORK=$(openstack network list | grep -o "APIMonitor_[0-9]*_" | sort -u)
ROUTERS=$(openstack router  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
SECGRPS=$(openstack security group list | grep -o "APIMonitor_[0-9]*_" | sort -u)
echo CLEANUP: FIPs $FIPLIST Servers $SERVERS Keypairs $KEYPAIR Volumes $VOLUMES Networks $NETWORK LoadBalancers $LOADBAL Routers $ROUTERS SecGrps $SECGRPS
for ENV in $FIPLIST; do
  echo "******************************"
  echo "CLEAN $ENV"
  bash ./api_monitor.sh -o -T -q -c CLEANUP $ENV
  echo "******************************"
done
TOCLEAN=$(echo "$SERVERS
$KEYPAIR
$VOLUMES
$NETWORK
$ROUTERS
$SECGRPS
" | grep -v '^$' | sort -u)
for ENV in $TOCLEAN; do
  echo "******************************"
  echo "CLEAN $ENV"
  bash ./api_monitor.sh -o -q -c CLEANUP $ENV
  echo "******************************"
done

exec ./api_monitor.sh -O -C -D -n 6 -s -b -B -M -T -S poc-wgcloud "$@"
