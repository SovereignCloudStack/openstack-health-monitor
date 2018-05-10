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
  bash ./api_monitor.sh CLEANUP $ENV
  echo "******************************"
done

bash ./api_monitor.sh -c -d -n 8 -l last.log -e $EMAIL_PARAM -S -i 9
