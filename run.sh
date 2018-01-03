#!/bin/bash

export OS_DOMAIN=OTC-EU-DE-00000000001000020825
export OS_USER_DOMAIN_NAME=OTC-EU-DE-00000000001000020825
export OS_TENANT_NAME=eu-de
export OS_PROJECT_NAME=eu-de
export OS_AUTH_URL=https://iam.eu-de.otc.t-systems.com:443/v3
export OS_ENDPOINT_TYPE=publicURL
export NOVA_ENDPOINT_TYPE=publicURL
export CINDER_ENDPOINT_TYPE=publicURL
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export OS_VOLUME_API_VERSION=2

# ./api_monitor.sh won't terminate on a auth error
openstack server list >/dev/null

# Cleanup previous interrupted runs
SERVERS=$(openstack server  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
VOLUMES=$(openstack volume  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
NETWORK=$(openstack network list | grep -o "APIMonitor_[0-9]*_" | sort -u)
TOCLEAN=$(echo "$SERVERS
$VOLUMES
$NETWORK" | sort -u)
for ENV in $TOCLEAN; do
  echo "******************************"
  echo "CLEAN $ENV"
  bash ./api_monitor.sh CLEANUP $ENV
  echo "******************************"
done

bash ./api_monitor.sh -d -n 30 -l last.log -e t-systems@garloff.de -i 4
