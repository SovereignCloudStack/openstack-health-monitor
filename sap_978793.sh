#!/bin/bash
# sap_978793.sh
# Testcase trying to reproduce the issue of bug 978793
# Creating a large number (30) of VMs, SAP HCP team observes API call timeouts
# (c) Kurt Garloff <kurt.garloff@t-systems.com>, 2/2017
# License: CC-BY-SA (2.0)
#
# General approach:
# - create router (VPC)
# - create two nets
# - create two subnets
# - create security groups
# - create SSH key
# - create VMs by
#   a) creating disks (from image)
#   b) creating a port
#   c) creating VM
#   (Steps a and c take long, so we do many in parallel and poll for progress)
#   d) do some property changes to VMs
#
# We do some statistics on the duration of the steps (min, avg, median, max)
# We keep track of resources to clean up
#

if test -z "$OS_USERNAME"; then
  echo "source OS_ settings file before running this test"
  exit 1
fi

usage()
{
  echo "Usage: sap_978793.sh [-n NUMVM] [-l LOGFILE]"
  exit 0
}


DATE=`date +%s`
LOGFILE=sap_978793-$DATE.log
NUMVM=30
if test "$1" = "-n"; then NUMVM=$2; shift; shift; fi
if test "$1" = "-l"; then LOGFILE=$2; shift; shift; fi
if test "$1" = "help" -o "$1" = "-h"; then usage; fi


# Command wrapper for openstack commands
# Collecting timing, logging, and extracting id
# $1 = id to extract
# $2-oo => command
ostackcmd_id()
{
  IDNM=$1; shift
  START=$(date +%s.%N)
  RESP=$($@)
  RC=$?
  END=$(date +%s.%N)
  ID=$(echo "$RESP" | grep "^| *$IDNM *|" | sed "s/^| *$IDNM *| *\([0-9a-f-]*\).*\$/\1/")
  echo "$START/$END/$ID: $RESP" >> $LOGFILE
  if test "$RC" != "0"; then echo "ERROR: $@ => $RC $RESP" 1>&2; return $RC; fi
  TIM=$(python -c "print \"%.3f\" % ($END-$START)")
  echo "$TIM $ID"
}

# List of resources
declare -a ROUTERS
declare -a NETS
declare -a SUBNETS
declare -a SGROUPS
declare -a VOLUMES
declare -a SSHKEYS
declare -a VMS

# Statistics
declare -a NETSTATS
declare -a VOLSTATS
declare -a VOLCSTART
declare -a VOLCSTOP
declare -a NOVASTATS
declare -a VMCSTATS
declare -a VMCSTART
declare -a VMCSTOP

NOAZS=2

# NUMBER STATNM RSRCNM IDNM COMMAND
createResources()
{
  QUANT=$1
  STATNM=$2
  RNM=$3
  IDNM=$4
  shift; shift; shift; shift
  for no in `seq 1 $QUANT`; do
    AZ=$((($no-1)%$NOAZS+1))
    CMD=`eval echo $@`
    read TM ID < <(ostackcmd_id $IDNM $CMD)
    RC=$?
    eval ${STATNM}+="($TM)"
    if test $RC != 0; then echo "ERROR: $RNM creation failed" 1>&2; return 1; fi
    eval ${RNM}S+="($ID)"
  done
}

# STATNM RSRCNM COMMAND
deleteResources()
{
  STATNM=$1
  RNM=$2
  shift; shift
  #eval varAlias=( \"\${myvar${varname}[@]}\" ) 
  eval LIST=( \"\${${RNM}S[@]}\" )
  #echo $LIST
  echo -n "Del:"
  #for rsrc in $LIST; do
  while test ${#LIST[@]} -gt 0; do
    rsrc=${LIST[-1]}
    echo -n " $rsrc"
    read TM < <(ostackcmd_id id $@ $rsrc)
    eval ${STATNM}+="($TM)"
    unset LIST[-1]
  done
  echo
}

createRouters()
{
  createResources 1 NETSTATS ROUTER id neutron router-create VPC_SAPTEST
}

deleteRouters()
{
  deleteResources NETSTATS ROUTER neutron router-delete
}

NONETS=2

createNets()
{
  createResources $NONETS NETSTATS NET id neutron net-create NET_SAPTEST_\$no
}

deleteNets()
{
  deleteResources NETSTATS NET neutron net-delete
}

# Main 
if createRouters; then
 echo "Routers ${ROUTERS[*]}"
 if createNets; then
  echo "Nets ${NETS[*]}"
 fi
 deleteNets
fi
deleteRouters
echo "${NETSTATS[*]}"
