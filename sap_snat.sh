#!/bin/bash
# Helper to create SNAT instances and set routing via them
# (c) Kurt Garloff <t-systems@garloff.de>, 2/2017
# Copyright: Artistic (v2)
#

# Images, flavors
IMG="${IMG:-Standard_openSUSE_42_JeOS_latest}"
IMGFILT="${IMGFILT:- --property-filter __platform=OpenSUSE}"
FLAVOR=${FLAVOR:-computev1-1}


# Helper
getid() { FIELD=${1:-id}; grep "^| $FIELD " | sed -e 's/^|[^|]*| \([^|]*\) |.*$/\1/' -e 's/ *$//'; }
listid() { grep $1 | tail -n1 | sed 's/^| \([0-9a-f-]*\) .*$/\1/'; }

# Command wrapper for openstack commands
# Logging, and extracting id
# $1 = id to extract
# $2-oo => command
ostackcmd_id()
{
  IDNM=$1; shift
  RESP=$($@ 2>&1)
  RC=$?
  if test "$IDNM" = "DELETE"; then
    ID=$(echo "$RESP" | grep "^| *status *|" | sed -e "s/^| *status *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$@ => $RC $ID" 1>&2
  else
    ID=$(echo "$RESP" | grep "^| *$IDNM *|" | sed -e "s/^| *$IDNM *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$@ => $RC $ID" 1>&2
    if test "$RC" != "0"; then echo "ERROR: $@ => $RC $RESP" 1>&2; return $RC; fi
  fi
  echo "$ID"
  return $RC
}

# Just output for debugging ...
ostackcmd()
{
  RESP=$($@ 2>&1)
  RC=$?
  echo "$@ => $RC" 1>&2
  echo "$RESP"
  return $RC
}

extract_ip()
{
  echo "$1" | grep '| fixed_ips ' | sed 's/^.*"ip_address": "\([0-9a-f:.]*\)".*$/\1/'
}

create_snatsg()
{
  SNAT_SG=$(ostackcmd_id id neutron security-group-create SNAT-SG) || return 1
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SNAT_SG $SNAT_SG) || return
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction egress  --ethertype IPv4 --remote-ip-prefix 0/0  $SNAT_SG) || return
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix 0/0 $SNAT_SG) || return
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix 0/0 $SNAT_SG) || return
}

waitIP()
{
  declare -i ctr=0
  echo -n "Waiting for VM $1 " 1>&2
  while test $ctr -le 72; do
    sleep 5
    RESP=$(nova show $1 | grep "SNAT-NET network")
    IP=$(echo "$RESP" | sed 's@|[^|]*| \([0-9\.]*\).*$@\1@')
    if test -n "$IP"; then break; fi
    echo -n "." 1>&2
    let ctr+=1
  done
  echo 1>&2
  echo "$IP"
}


# INPUT:
# $1 => Router name/ID
# $2 => SNAT CIDR
# $3 => Keyname to inject
create_snatinst()
{
   create_snatsg || return
   SNATNET=$(ostackcmd id neutron net-create SNAT-NET) || return
   SNATSUB=$(ostackcmd_id id neutron subnet-create --dns-nameserver 100.125.4.25 --dns-nameserver 8.8.8.8 --name SNAT-SUBNET SNAT-NET $2) || return
   ostackcmd neutron router-interface-add $1 $SNATSUB
   OUT=$(ostackcmd neutron port-create --name SNAT-VIP --security-group $SNAT_SG SNAT-NET) || return
   VIP=$(extract_ip "$OUT")
   echo $VIP
   cat > user_data.yaml <<EOT
#cloud-config
otc:
   internalnet:
      - 172.16/12
      - 10/8
      - 192.168/16
   snat:
      masq:
         - INTERNALNET
   addip:
      eth0: $VIP
otc:
   autoupdate:
      frequency: daily
      categories: security recommended
EOT
   IMGID=$(glance image-list $IMGFILT | listid $IMG) || return
   SNAT1VM=$(ostackcmd_id id nova boot --image $IMGID --flavor computev1-1 --key-name $3 --user_data user_data.yaml --availability_zone eu-de-01 --security-groups $SNAT_SG --nic net-id=$SNATNET SNAT-INST1) || return
   SNAT2VM=$(ostackcmd_id id nova boot --image $IMGID --flavor computev1-1 --key-name $3 --user_data user_data.yaml --availability_zone eu-de-02 --security-groups $SNAT_SG --nic net-id=$SNATNET SNAT-INST2) || return
   # Wait for IP_address
   SIP1=$(waitIP $SNAT1VM) || return
   SNAT_INST1_PORT=$(neutron port-list | grep $SIP1 | listid $SNATSUB) || return
   echo "$SNAT_INST1_PORT $SIP1"
   ostackcmd neutron floatingip-create --port-id $SNAT_INST1_PORT admin_external_net || return
   SIP2=$(waitIP $SNAT2VM) || return
   SNAT_INST2_PORT=$(neutron port-list | grep $SIP2 | listid $SNATSUB) || return
   echo "$SNAT_INST2_PORT $SIP2"
   ostackcmd neutron floatingip-create --port-id $SNAT_INST2_PORT admin_external_net || return
   ostackcmd neutron router-update VPC-ROUTER --routes type=dict list=true destination=0.0.0.0/0,nexthop=$VIP || return
}

usage()
{
  echo "Usage: sap_snat.sh ROUTER SNATCIDR KEYNAME"
  exit 1
}

test -z "$3" && usage

create_snatinst "$@"
