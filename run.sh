#!/bin/bash

# Specify image names, JumpHost ideally has sfw2-snat
#export JHIMG="openSUSE_15_1_CN_20191114"
#export IMG="openSUSE_15_1_CN_20191114"
#export JHIMGFILT=" "
#export IMGFILT=" "
##export JHIMGFILT="--property-filter os_version=openSUSE-15.0"
##export IMGFILT="--property-filter os_version=openSUSE-15.0"
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
#export OS_DOMAIN=XXXXX
#export OS_USER_DOMAIN_NAME=XXXXX
#export OS_TENANT_NAME=YYYYY
#export OS_PROJECT_NAME=${OS_PROJECT_NAME:-"eu-de_APIMonitor2"}
#export OS_AUTH_URL=https://...."
#export OS_ENDPOINT_TYPE=publicURL
#export NOVA_ENDPOINT_TYPE=publicURL
#export CINDER_ENDPOINT_TYPE=publicURL
#export OS_IDENTITY_API_VERSION=3
#export OS_IMAGE_API_VERSION=2
#export OS_VOLUME_API_VERSION=2
## or just (using clouds.yaml)
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
#exec api_monitor.sh -o -C -D -N 2 -n 8 -s -e sender@domain.org -l APIMon_$$.log "$@"
exec api_monitor.sh -O -C -D -N 2 -n 8 -s -e sender@domain.org -l APIMon_$$.log "$@"

