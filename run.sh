#!/bin/bash

# Specify image names, JumpHost ideally has sfw2-snat
# Options for the images: my openSUSE 15.2 (linux), Ubuntu 20.04 (ubuntu),
#  openSUSE Leap 15.2 (opensuse), CentOS 8 (centos)
# You can freely mix ...
#export JHIMG="Ubuntu 20.04"
export JHIMG="openSUSE 15.2"
#export ADDJHVOLSIZE=2
#export IMG="Ubuntu 20.04"
export IMG="openSUSE 15.2"
#export IMG="CentOS 8"
#export DEFLTUSER=ubuntu
#export JHDEFLTUSER=ubuntu
# You can use a filter when listing images (because your catalog is huge)
#export JHIMGFILT="--property-filter os_version=openSUSE-15.0"
#export IMGFILT="--property-filter os_version=openSUSE-15.0"
# ECP flavors
#if test $OS_REGION_NAME == Kna1; then
#export JHFLAVOR=1C-1GB
#export FLAVOR=1C-1GB
#else
#export JHFLAVOR=1C-1GB-10GB
#export FLAVOR=1C-1GB-10GB
#fi
# EMail notifications sender address
#export FROM=sender@domain.org
# Only use one AZ
#export AZS="nova"

# Assume OS_ parameters have already been sourced from some .openrc file
# or just set OS_CLOUD (using clouds.yaml/secure.yaml)
#export OS_CLOUD=cloudname

export EMAIL_PARAM=${EMAIL_PARAM:-"sender@domain.org"}

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
  bash ./api_monitor.sh -q -o -c CLEANUP $ENV
  echo "******************************"
done

#bash ./api_monitor.sh -c -x -d -n 8 -l last.log -e $EMAIL_PARAM -S -i 9
#exec api_monitor.sh -o -C -D -N 2 -n 8 -s -e sender@domain.org "$@"
exec api_monitor.sh -O -C -D -N 2 -n 8 -s -e sender@domain.org "$@"

