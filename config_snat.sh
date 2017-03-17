#!/bin/bash
# config_snat.sh
# Helper to create SNAT instances and set routing via them
# (c) Kurt Garloff <t-systems@garloff.de>, 2/2017
# Copyright: CC-BY (4.0)

# Image
# Note that SNAT instance depends on SuSEfirewall2-snat package,
# only available in openSUSE_42_JeOS_latest (or _Docker_latest or SLES12_SP2_latest)
IMG="${IMG:-Standard_openSUSE_42_JeOS_latest}"
IMGFILT="${IMGFILT:- --property-filter __platform=OpenSUSE}"
# Flavor - smallest is really enough ... for this task
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
  ID=$(echo "$RESP" | grep "^| *$IDNM *|" | sed -e "s/^| *$IDNM *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
  echo "$@ => $RC $ID" 1>&2
  if test "$RC" != "0"; then echo "ERROR: $@ => $RC $RESP" 1>&2; return $RC; fi
  echo "$ID"
  return $RC
}

# Just output for debugging ...
ostackcmd()
{
  RESP=$($@ 2>&1)
  RC=$?
  if test $RC = 0; then echo "$@ => $RC" 1>&2; else echo "$@ => $RC $RESP" 1>&2; fi
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
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 222 --port-range-max 222 --remote-ip-prefix 0/0 $SNAT_SG) || return
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix 0/0 $SNAT_SG) || return
}


# Get fixed IP address from VM $1 in SNAT-NET network and report it back
SNATVMIP()
{
  RESP=$(nova show $1 | grep 'SNAT-NET network') || return
  IP=$(echo "$RESP" | sed 's@|[^|]*| \([0-9\.]*\).*$@\1@')
  test -n "$IP" && echo "$IP"
}

# Wait for VM $1 to have a port with a fixed IP in SNAT-NET network (and report it back)
waitIP()
{
  declare -i ctr=0
  echo -n "Waiting for VM $1 " 1>&2
  while test $ctr -le 72; do
    sleep 5
    IP=$(SNATVMIP $1)
    if test -n "$IP"; then break; fi
    echo -n "." 1>&2
    let ctr+=1
  done
  echo 1>&2
  echo "$IP"
}


# Main funtion to create a net, subnet with CIDR $2 connected to router $1
# and boot two instances (with key $3) configured to do SNAT for all local nets
# by assigning EIPs and settig a default route in router
# INPUT:
# $1 => Router name/ID
# $2 => SNAT CIDR
# $3 => Keyname to inject
create_snatinst()
{
   neutron router-show $1 >/dev/null 2>&1 || { echo "Router $1 does not exist."; return 1; }
   create_snatsg || return
   SNATNET=$(ostackcmd_id id neutron net-create SNAT-NET) || return
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
   movessh: 222
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
   ostackcmd neutron port-update $SNAT_INST1_PORT --allowed-address-pairs type=dict list=true ip_address=0.0.0.0/1 ip_address=128.0.0.0/1 || return
   ostackcmd neutron floatingip-create --port-id $SNAT_INST1_PORT admin_external_net || return
   SIP2=$(waitIP $SNAT2VM) || return
   SNAT_INST2_PORT=$(neutron port-list | grep $SIP2 | listid $SNATSUB) || return
   echo "$SNAT_INST2_PORT $SIP2"
   ostackcmd neutron port-update $SNAT_INST2_PORT --allowed-address-pairs type=dict list=true ip_address=0.0.0.0/1 ip_address=128.0.0.0/1 || return
   ostackcmd neutron floatingip-create --port-id $SNAT_INST2_PORT admin_external_net || return
   ostackcmd neutron router-update $1 --routes type=dict list=true destination=0.0.0.0/0,nexthop=$VIP || return
}

# CLEANUP functions

# Use an openstack list command and find resource IDs matching pattern
findres()
{
  FILT=${1:-SNAT}
  shift
  $@ | grep " $FILT" | sed 's/^| \([0-9a-f-]*\) .*$/\1/'
}

# Wait until VMs in $@ are gone
WaitNoMore()
{
  if test -z "$*"; then return 0; fi
  echo -n " wait for VMs $@ to be gone: "
  declare -i ctr=0
  while test $ctr -le 100; do
    FOUND=0
    VMLIST=$(nova list)
    for arg in "$@"; do
      if echo "$VMLIST" | grep "$arg" >/dev/null 2>&1; then
        FOUND=1; break
      fi
    done
    if test $FOUND == 0; then echo " OK"; return 0; fi
    echo -n "."
    sleep 2
    let ctr+=1
  done
  echo " Timeout"
  echo " ERROR: VMs $@ still present" 1>&2
  return 1
}

remove_snatinst()
{
  SNATVIP=$(findres SNAT-VIP neutron port-list)
  SNAT1VM=$(findres SNAT-INST1 nova list) 
  if test -n "$SNAT1VM"; then 
    SNAT1VMIP=$(SNATVMIP $SNAT1VM)
    if test -n "$SNAT1VMIP"; then
      FIP1=$(neutron floatingip-list | grep "$SNAT1VMIP" | sed 's/^| *\([^ ]*\) *|.*$/\1/')
      if test -n "$FIP1"; then ostackcmd neutron floatingip-delete $FIP1; fi
    fi
    ostackcmd nova delete $SNAT1VM
  fi
  SNAT2VM=$(findres SNAT-INST2 nova list) 
  if test -n "$SNAT2VM"; then 
    SNAT2VMIP=$(SNATVMIP $SNAT2VM)
    if test -n "$SNAT2VMIP"; then
      FIP2=$(neutron floatingip-list | grep "$SNAT2VMIP" | sed 's/^| *\([^ ]*\) *|.*$/\1/')
      if test -n "$FIP2"; then ostackcmd neutron floatingip-delete $FIP2; fi
    fi
    ostackcmd nova delete $SNAT2VM
  fi
  if test -n "$SNATVIP"; then 
    ostackcmd neutron router-update $1 --no-routes
    ostackcmd neutron port-delete $SNATVIP
  fi
  WaitNoMore $SNAT1VM $SNAT2VM
  SNATSG=$(findres SNAT-SG neutron security-group-list)
  if test -n "$SNATSG"; then ostackcmd neutron security-group-delete $SNATSG; fi
  SNATSUB=$(findres SNAT-SUBNET neutron subnet-list)
  if test -n "$SNATSUB"; then 
    ostackcmd neutron router-interface-delete $1 $SNATSUB
    ostackcmd neutron subnet-delete $SNATSUB
  fi
  SNATNET=$(findres SNAT-NET neutron net-list)
  if test -n "$SNATNET"; then ostackcmd neutron net-delete $SNATNET; fi
}


# This assumes the usual OS_ variables have been configured, see https://slides/com/kgarloff

usage()
{
  echo "Usage: config_snat.sh <ROUTER> <SNATCIDR> <KEYNAME>"
  echo "            Sets up a pair of SNAT instances in SNAT-SUBNET with CIDR <SNATCIDR>"
  echo "            connected to the VPC <ROUTER> and injects keypair <KEYNAME> for ssh access"
  echo "Usage: config_snat.sh CLEANUP <ROUTER>"
  echo "            Tears down the SNAT instances again and removes them from <ROUTER> VPC"
#  echo "Usage: config_snat.sh CONNECT <ROUTER>"
#  echo "            Connect existing SNAT instaces to a secondary VPC <ROUTER>"
#  echo "Usage: config_snat.sh DISCONNECT <ROUTER>"
#  echo "            Disconnect existing SNAT instaces from a secondary VPC <ROUTER>"
  exit 1
}

test -z "$2" && usage
test -z "$3" -a "$1" != "CLEANUP" && usage

if test "$1" != "CLEANUP"; then
  create_snatinst "$@"
  if test $? != 0; then echo "Error. Cleanup ... "; remove_snatinst "$1"; fi
else
  remove_snatinst "$2"
fi
