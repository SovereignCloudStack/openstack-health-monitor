#!/bin/bash
# Wrapper to setup env run api_monitor.sh on ECP
# Images: Note that we need an image with SuSEfirewall2-snat (obs Cloud:OTC:Tools)
# to do the NAT/port-forwarding tricks that are used to do network access testing
# without the need to allocate lots of floating IP addresses (and without the
# need to have the machine that runs the tests be connected to the same router).
export JHIMG="Standard_openSUSE_15_latest"
export IMG="Standard_openSUSE_15_latest"
export JHIMGFILT="--property-filter os_version=openSUSE-15.0"
export IMGFILT="--property-filter os_version=openSUSE-15.0"
# ECP flavors
export JHFLAVOR=m1.medsmall
export FLAVOR=m1.smaller
# EMail notifications sender address
export FROM=garloff@suse.de

# Terminate early on auth error
openstack server list >/dev/null

echo "Search for resources left over from previous runs ..."
# Cleanup previous interrupted runs (important for Jenkins)
SERVERS=$(openstack server  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
VOLUMES=$(openstack volume  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
NETWORK=$(openstack network list | grep -o "APIMonitor_[0-9]*_" | sort -u)
ROUTERS=$(openstack router  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
SECGRPS=$(openstack security group list | grep -o "APIMonitor_[0-9]*_" | sort -u)
TOCLEAN=$(echo "$SERVERS
$VOLUMES
$NETWORK
$ROUTERS
$SECGRPS
" | sort -u)
for ENV in $TOCLEAN; do
  echo "******************************"
  echo "CLEAN $ENV"
  bash ./api_monitor.sh -q -c CLEANUP $ENV
  echo "******************************"
done

# Call script with reasonable parameters ... 
# - Force 2 networks (despite 1 AZ only in ECP)
# - Send stats via mail to Kurt
# - Keep logfile; replace with -l APIMon_last.log for Jenkins to avoid collecting too much
# - Boot from image and create ports on the fly (-d -P) or do batch (-D) creation
#  (add -c for Jenkins, -x if run in separate project)
#  (add -S if you have a telegraf running to collect the data)
#  (use -i IT -w -1 if you want to run interactively until first error)
#exec ./api_monitor.sh -d -P -N 2 -n 8 -s -e garloff@suse.de -l APIMon_$$.log "$@"
#exec ./api_monitor.sh -D -N 3 -n 15 -s -e garloff@suse.de -l APIMon_$$.log "$@"
exec ./api_monitor.sh -O -C -D -N 3 -n 15 -s -e garloff@suse.de -l APIMon_$$.log "$@"
