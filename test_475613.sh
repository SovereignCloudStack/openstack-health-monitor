#!/bin/bash
# test_475613.sh
# Testcase trying to reproduce the issue of bug 475613.sh (allowed addr pair disables SG)
# Allowing address pairs should only have an effect on egress, but does not
#
# (c) Kurt Garloff <kurt.garloff@t-systems.com>, 2/2017
# License: CC-BY-SA (2.0)
#
# General approach:
# - create router (VPC), net, subnet
# - create security group
# - boot VM and wait for it
# - bind publicip
# - ping & connect forbidden port
# - allow address pair
# - ping & connect forbidden port again
# - after everything is complete, we wait
# - and clean up ev'thing in reverse order as soon as user confirms
#

# User settings

# Prefix for test resources
RPRE=Test475613_
# Number of VMs and networks

# Images, flavors, disk sizes
IMG="${IMG:-Standard_openSUSE_42_JeOS_latest}"
IMGFILT="--property-filter __platform=OpenSUSE"
FLAVOR="computev1-1"

DATE=`date +%s`
LOGFILE=$RPRE$DATE.log

# Nothing to change below here
BOLD="\e[0;1m"
NORM="\e[0;0m"

if test -z "$OS_USERNAME"; then
  echo "source OS_ settings file before running this test"
  exit 1
fi

usage()
{
  echo "Usage: test_475613.sh [-l LOGFILE] CLEANUP|DEPLOY"
  echo " CLEANUP cleans up all resources with prefix $RPRE"
  exit 0
}
if test "$1" = "-l"; then LOGFILE=$2; shift; shift; fi
if test "$1" = "help" -o "$1" = "-h"; then usage; fi


getid() { FIELD=${1:-id}; grep "^| $FIELD " | sed -e 's/^|[^|]*| \([^|]*\) |.*$/\1/' -e 's/ *$//'; }
listid() { grep $1 | tail -n1 | sed 's/^| \([0-9a-f-]*\) .*$/\1/'; }

# Command wrapper for openstack commands
# Collecting timing, logging, and extracting id
# $1 = id to extract
# $2-oo => command
ostackcmd_id()
{
  IDNM=$1; shift
  RESP=$($@ 2>&1)
  RC=$?
  if test "$IDNM" = "DELETE"; then
    ID=$(echo "$RESP" | grep "^| *status *|" | sed -e "s/^| *status *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$ID: $@ => $RC $RESP" >> $LOGFILE
  else
    ID=$(echo "$RESP" | grep "^| *$IDNM *|" | sed -e "s/^| *$IDNM *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$ID: $@ => $RC $RESP" >> $LOGFILE
    if test "$RC" != "0"; then echo "ERROR: $@ => $RC $RESP" 1>&2; return $RC; fi
  fi
  echo "$ID"
  return $RC
}


createNet()
{
  echo -n "Router: "
  ROUTER=$(ostackcmd_id id neutron router-create ${RPRE}Router) || return 1
  echo -ne "$ROUTER\nNet: "
  NET=$(ostackcmd_id id neutron net-create ${RPRE}Net) || return 1
  echo -ne "$NET\nSubnet: "
  SUBNET=$(ostackcmd_id id neutron subnet-create --dns-nameserver 100.125.4.25 --dns-nameserver 8.8.8.8 --name ${RPRE}Subnet $NET 192.168.250.0/24) || return 1
  echo -e "$SUBNET"
  RIFACE=$(ostackcmd_id id neutron router-interface-add $ROUTER $SUBNET) || return 1
}

# The commands that create and delete resources ...

deleteNet()
{
  [ -n "$SUBNET" ] && neutron router-interface-delete $ROUTER $SUBNET
  [ -n "$SUBNET" ] && neutron subnet-delete $SUBNET
  [ -n "$NET" ] && neutron net-delete $NET
  [ -n "$ROUTER" ] && neutron router-delete $ROUTER
}

createSGroup()
{
  echo -n "SGroup: "
  SGID=$(ostackcmd_id id neutron security-group-create ${RPRE}SG) || return 1
  echo -en "$SGID\nRules: "
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SGID $SGID)
  echo -n "."
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction egress  --ethertype IPv4 --remote-ip-prefix 0/0  $SGID)
  echo -n "."
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix 0/0 $SGID)
  echo -n "."
  #ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix 0/0 $SGID)
  echo 
}


deleteSGroup()
{
  neutron security-group-delete $SGID
}


createKeypair()
{
  UMASK=$(umask)
  umask 0077
  OSTACKRESP=$(nova keypair-add ${RPRE}Keypair) || return 1
  echo "$OSTACKRESP" > ${RPRE}Keypair.pem
  umask $UMASK
}

deleteKeypair()
{
  nova keypair-delete ${RPRE}Keypair
  #rm ${RPRE}Keypair.pem
}

extract_ip()
{
  echo "$1" | grep '| fixed_ips ' | sed 's/^.*"ip_address": "\([0-9a-f:.]*\)".*$/\1/'
}

createFIP()
{
  EXTNET=$(neutron net-external-list | listid external)
  #EXTNET=$(echo "$OSTACKRESP" | grep '^| [0-9a-f-]* |' | sed 's/^| [0-9a-f-]* | \([^ ]*\).*$/\1/')
  echo -n "FIP ($EXTET): "
  FIP=$(ostackcmd_id id neutron floatingip-create --port-id $PORTID $EXTNET)
  echo -n "$FIP "
  FLOAT=""
  OSTACKRESP=(neutron floatingip-list) || return 1
  for PORT in ${FIPS[*]}; do
    FLOAT+=" $(echo "$OSTACKRESP" | grep $FIP | sed 's/^|[^|]*|[^|]*| \([0-9:.]*\).*$/\1/')"
  done
  echo "$FLOAT"
}

deleteFIP()
{
  neutron floatingip-delete $FIP
}

createVM()
{
  # of course nova boot --image ... --nic net-id ... would be easier
  echo -n "Boot VM: "
  VMID=$(nova boot --flavor $FLAVOR --image $IMGID --key-name $KEYPAIRS --availability-zone eu-de-01 --security-groups --nic net-id=$NET ${RPRE}VM) || return 1
  echo -en "$VMID\nWait for IP: "
  while true; do
    sleep 5
    RESP=$(nova show $VMID | grep "$SUBNET network")
    IP=$(echo "$RESP" | sed 's@|[^|]*| \([0-9\.]*\).*$@\1@')
    if test -n "$IP"; then break; fi
    echo -n "."
  done
  echo "$IP"
  PORTID=$(neutron port-list | grep $IP | listid $SUBNET)
}

waitVM()
{
  echo -n "Waiting for VM "
  while true; do
    nova list | grep $VMID | grep ACTIVE >/dev/null 2>&1 && { echo; return 0; }
    echo -n "."
    sleep 2
  done
}

deleteVM()
{
  nova delete $VMID
}

findres()
{
  FILT=${1:-$RPRE}
  shift
  $@ | grep " $FILT" | sed 's/^| \([0-9a-f-]*\) .*$/\1/'
}

cleanup()
{
  VMID=$(findres ${RPRE}VM nova list)
  [ -n "$VMID" ] && deleteVM || echo "No VM To be cleaned"
  FIP=$(neutron floatingip-list | grep '192\.168\.250\.' | sed 's/^| *\([^ ]*\) *|.*$/\1/')
  [ -n "$FIP" ] && deleteFIP
  KEYPAIR=$(nova keypair-list | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/')
  [ -n "$LEYPAIR" ] && deleteKeypair
  SGID=$(findres "" neutron security-group-list)
  [ -n "$SGID" ] && deleteSGroup
  SUBNET=$(neutron subnet-list | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/')
  NET=$(neutron net-list | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/')
  ROUTER=$(neutron router-list | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/')
  echo "Sub: $SUBNET Net: $NET Router: $ROUTER"
  deleteNet
}

# Main
MSTART=$(date +%s)
# Debugging: Start with volume step
if test "$1" = "CLEANUP"; then
  echo -e "$BOLD *** Start cleanup *** $NORM"
  cleanup
  echo -e "$BOLD *** Cleanup complete *** $NORM"
elif test "$1" = "DEPLOY"; then
 # Complete setup
 echo -e "$BOLD *** Start deployment $NORM"
 # Image IDs
 IMGID=$(glance image-list $IMGFILT | grep "$IMG" | head -n1 | sed 's/| \([0-9a-f-]*\).*$/\1/')
 if test -z "$IMGID"; then echo "ERROR: No image $IMG found, aborting."; exit 1; fi
 #echo "Image $IMGID $JHIMGID"
 if createNet; then
  if createSGroup; then
   if createKeypair; then
    if createVM; then
     if createFIP; then
      waitVM
      #Now wait for ssh (should succeed)
      #ping (should fail, SG not open)
      # allow-address-pair
      #ping again
      #telnet forbidden port
      echo -en "$BOLD *** TEST DONE, HIT ENTER TO CLEANUP $NORM"
     fi; deleteFIP
    fi; deleteVM
   fi; deleteKeypair
  fi; deleteSGroup
 fi; deleteNet
 echo "Overall ($NOVMS + $NONETS) VMs: $(($(date +%s)-$MSTART))s"
else
  usage
fi