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
  echo "Usage: test_475613.sh CLEANUP|DEPLOY"
  echo " CLEANUP cleans up all resources with prefix $RPRE"
  exit 0
}
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
    echo "$@ => $RC $ID" 1>&2
  else
    ID=$(echo "$RESP" | grep "^| *$IDNM *|" | sed -e "s/^| *$IDNM *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$@ => $RC $ID" 1>&2
    if test "$RC" != "0"; then echo "ERROR: $@ => $RC $RESP" 1>&2; return $RC; fi
  fi
  echo "$ID"
  return $RC
}

ostackcmd()
{
  RESP=$($@ 2>&1)
  RC=$?
  echo "$@ => $RC" 1>&2
  echo "$RESP"
  return $RC
}

createNet()
{
  ROUTER=$(ostackcmd_id id neutron router-create ${RPRE}Router) || return 1
  NET=$(ostackcmd_id id neutron net-create ${RPRE}Net) || return 1
  SUBNET=$(ostackcmd_id id neutron subnet-create --dns-nameserver 100.125.4.25 --dns-nameserver 8.8.8.8 --name ${RPRE}Subnet $NET 192.168.250.0/24) || return 1
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
  SGID=$(ostackcmd_id id neutron security-group-create ${RPRE}SG) || return 1
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SGID $SGID)
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction egress  --ethertype IPv4 --remote-ip-prefix 0/0  $SGID)
  ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix 0/0 $SGID)
  #ID=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix 0/0 $SGID)
}


deleteSGroup()
{
  neutron security-group-delete $SGID
}


createKeypair()
{
  UMASK=$(umask)
  umask 0077
  OSTACKRESP=$(ostackcmd nova keypair-add ${RPRE}Keypair) || return 1
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
  echo -n "FIP ($EXTNET): "
  FIP=$(ostackcmd_id id neutron floatingip-create --port-id $PORTID $EXTNET)
  echo -n "$FIP "
  OSTACKRESP=$(neutron floatingip-list) || return 1
  FLOAT=$(echo "$OSTACKRESP" | grep $FIP | sed 's/^|[^|]*|[^|]*| \([0-9:.]*\).*$/\1/')
  echo "$FLOAT"
}

deleteFIP()
{
  ostackcmd neutron floatingip-delete $FIP
}

createVM()
{
  # of course nova boot --image ... --nic net-id ... would be easier
  echo -n "Boot VM: "
  VMID=$(ostackcmd_id id nova boot --flavor $FLAVOR --image $IMGID --key-name ${RPRE}Keypair --availability-zone eu-de-01 --security-groups $SGID --nic net-id=$NET ${RPRE}VM) || return 1
  echo -en "$VMID\nWait for IP: "
  while true; do
    sleep 5
    RESP=$(nova show $VMID | grep "${RPRE}Net network")
    IP=$(echo "$RESP" | sed 's@|[^|]*| \([0-9\.]*\).*$@\1@')
    if test -n "$IP"; then break; fi
    echo -n "."
  done
  echo "$IP"
  PORTID=$(ostackcmd neutron port-list | grep $IP | listid $SUBNET)
}

waitVM()
{
  echo -n "Waiting for VM "
  while true; do
    nova list | grep $VMID | grep ACTIVE >/dev/null 2>&1 && { echo; sleep 15; return 0; }
    echo -n "."
    sleep 2
  done
}

deleteVM()
{
  nova delete $VMID
  # FIXME: We should just wait ...
  sleep 15
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
 echo -e "$BOLD *** Start deployment *** $NORM"
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
      while true; do
        echo "quit" | nc -w2 $FLOAT 22 && break
        sleep 2
      done
      ssh -o "StrictHostKeyChecking=no" -i ${RPRE}Keypair.pem linux@$FLOAT sudo dmesg | tail -n4
      #ping (should fail, SG not open)
      sudo ping -c2 -i1 $FLOAT
      # allow-address-pair
      ostackcmd neutron port-update $PORTID --allowed-address-pairs type=dict list=true ip_address=0.0.0.0/1 ip_address=128.0.0.0/1
      #telnet forbidden port
      sleep 2
      echo "quit" | nc -w2 $FLOAT 100 && break
      #ping again
      sudo ping -c2 -i1 $FLOAT
      ssh -o "StrictHostKeyChecking=no" -i ${RPRE}Keypair.pem linux@$FLOAT sudo dmesg | tail -n4
      echo -en "$BOLD *** TEST DONE, HIT ENTER TO CLEANUP $NORM"
      read ans
     fi; deleteFIP
    fi; deleteVM
   fi; deleteKeypair
  fi; deleteSGroup
 fi; deleteNet
 deleteSGroup
 echo "Overall: $(($(date +%s)-$MSTART))s"
else
  usage
fi
