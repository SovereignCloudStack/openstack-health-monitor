#!/bin/bash

export OS_DOMAIN=OTC00000000001000000449
export OS_USER_DOMAIN_NAME=OTC00000000001000000449
export OS_TENANT_NAME=eu-de
export OS_PROJECT_NAME=${OS_PROJECT_NAME:-"eu-de_APIMonitor2"}
export OS_AUTH_URL=https://iam.eu-de.otc.t-systems.com:443/v3
export OS_ENDPOINT_TYPE=publicURL
export NOVA_ENDPOINT_TYPE=publicURL
export CINDER_ENDPOINT_TYPE=publicURL
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export OS_VOLUME_API_VERSION=2

export EMAIL_PARAM=${EMAIL_PARAM:-"t-systems@garloff.de"}

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
  bash ./api_monitor.sh -q -c CLEANUP $ENV
  echo "******************************"
done

# Reduce API load during night hours for upgrade work
echo $TZ
YEAR=$(date +%Y)
MONTH=$(date +%m)
DAY=$(date +%d)
HOUR=$(date +%H)

# use Xen JumpHosts (ommputev1-1 aka c1.medium.1) until Mar 31, 2019, but not during
# L1TF reboot windows on Nov 3,4,5/17,18,19 2018.
unset JHFLAVOR
if test $YEAR == 2019 -a $MONTH -le 3; then export JHFLAVOR=computev1-1; fi
if test $YEAR -lt 2018; then export JHFLAVOR=computev1-1; fi
if test $YEAR == 2018; then
  if test $MONTH != 11; then JHFLAVOR=computev1-1
  else if test $DAY != 3 -a $DAY != 4 -a $DAY != 5 -a $DAY != 17 -a $DAY != 18 -a $DAY != 19; then JHFLAVOR=computev1-1
       else if test $DAY == 3 -o $DAY == 17 && test $HOUR -lt 19; then JHFLAVOR=computev1-1
            else if test $DAY == 5 -o $DAY == 19 && test $HOUR -gt 8; then JHFLAVOR=computev1-1
                 else if test $HOUR -gt 8 -a $HOUR -lt 19; then JHFLAVOR=computev1-1; fi
                 fi
            fi
       fi
  fi
fi
# Out of resources, see #985505
if test $YEAR == 2018 -a $DAY == 28; then unset JHFLAVOR; fi

mv last.log prev.log
export JHFLAVOR
if test $YEAR == 2018 -a $MONTH == 06 -a $DAY -ge 04 -a $DAY -le 10 && test $HOUR -ge 16 -o $HOUR -lt 7; then
  bash ./api_monitor.sh -c -x -d -n 8 -l last.log -e $EMAIL_PARAM -S -i 1
else
  bash ./api_monitor.sh -c -x -d -n 8 -l last.log -e $EMAIL_PARAM -S -i 9
fi

