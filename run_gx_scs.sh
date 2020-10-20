#!/bin/bash

# Specify image names, JumpHost ideally has sfw2-snat
export JHIMG="openSUSE 15.2"
export IMG="openSUSE 15.2"
export JHIMGFILT=" "
export IMGFILT=" "
##export JHIMGFILT="--property-filter os_version=openSUSE-15.0"
##export IMGFILT="--property-filter os_version=openSUSE-15.0"
# ECP flavors
#if test $OS_REGION_NAME == Kna1; then
export JHFLAVOR=1C-2GB-20GB
export FLAVOR=1C-2GB-20GB
#else
#export JHFLAVOR=1C-1GB-10GB
#export FLAVOR=1C-1GB-10GB
#fi
# EMail notifications sender address
export FROM=kurt@garloff.de
# Only use one AZ
export AZS="nova"

# Assume OS_ parameters have already been sourced from some .openrc file

export EMAIL_PARAM=${EMAIL_PARAM:-"scs@garloff.de"}

# Terminate early on auth error
openstack server list >/dev/null

# Cleanup previous interrupted runs
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
  bash ./api_monitor.sh -o -q -c CLEANUP $ENV
  echo "******************************"
done

#bash ./api_monitor.sh -c -x -d -n 8 -l last.log -e $EMAIL_PARAM -S -i 9
#exec api_monitor.sh -O -C -D -N 2 -n 8 -s -e sender@domain.org -l APIMon_$$.log "$@"
exec ./api_monitor.sh -o -C -D -N 2 -n 8 -s -e scs@garloff.de -l APIMon_$$.log "$@"

