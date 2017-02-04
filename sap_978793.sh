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
  echo "$START/$END/$ID: $@ => $RESP" >> $LOGFILE
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

# NUMBER STATNM RSRCNM OTHRSRC IDNM COMMAND
createResources()
{
  declare -i ctr=0
  QUANT=$1
  STATNM=$2
  RNM=$3
  ORNM=$4
  IDNM=$5
  shift; shift; shift; shift; shift
  eval LIST=( \"\${${ORNM}S[@]}\" )
  for no in `seq 1 $QUANT`; do
    AZ=$((($no-1)%$NOAZS+1))
    VAL=${LIST[$ctr]}
    CMD=`eval echo $@ 2>&1`
    read TM ID < <(ostackcmd_id $IDNM $CMD)
    RC=$?
    eval ${STATNM}+="($TM)"
    let ctr+=1
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
  createResources 1 NETSTATS ROUTER NONE id neutron router-create VPC_SAPTEST
}

deleteRouters()
{
  deleteResources NETSTATS ROUTER neutron router-delete
}

NONETS=2

createNets()
{
  createResources $NONETS NETSTATS NET NONE id neutron net-create NET_SAPTEST_\$no
}

deleteNets()
{
  deleteResources NETSTATS NET neutron net-delete
}

createSubNets()
{
  createResources $NONETS NETSTATS SUBNET NET id neutron subnet-create --name SUBNET_SAPTEST_\$no \$VAL 10.128.\$no.0/24 
}

deleteSubNets()
{
  deleteResources NETSTATS SUBNET neutron subnet-delete
}

createRIfaces()
{
  createResources $NONETS NETSTATS NONE SUBNET id neutron router-interface-add ${ROUTERS[0]} \$VAL
}

deleteRIfaces()
{
  deleteResources NETSTATS SUBNET neutron router-interface-delete ${ROUTERS[0]}
}

createSGroups()
{
  createResources 2 NETSTATS SGROUP NONE id neutron security-group-create SG_SAP_\$no
}

deleteSGroups()
{
  deleteResources NETSTSTATS SGROUP neutron security-group-delete
}

stats()
{
  eval LIST=( \"\${${1}[@]}\" )
  IFS=$'\n' SLIST=($(sort <<<"${LIST[*]}"))
  #echo ${SLIST[*]}
  MIN=${SLIST[0]}
  MAX=${SLIST[-1]}
  NO=${#SLIST[@]}
  MID=$(($NO/2))
  if test $(($NO%2)) = 1; then MED=${SLIST[$MID]}; 
  else MED=`python -c "print \"%.3f\" % ((${SLIST[$MID]}+${SLIST[$(($MID-1))]})/2)"`
  fi
  AVGC="($(echo ${LIST[*]}|sed 's/ /+/g'))/$NO"
  #echo "$AVGC"
  AVG=`python -c "print \"%.3f\" % ($AVGC)"`
  echo "$1: Min $MIN Max $MAX Med $MED Avg $AVG Num $NO"
}

# Main 
if createRouters; then
 echo "Routers ${ROUTERS[*]}"
 if createNets; then
  echo "Nets ${NETS[*]}"
  if createSubNets; then
   echo "Subnets ${SUBNETS[*]}"
   if createRIfaces; then
    if createSGroups; then
     echo "SGroups ${SGROUPS[*]}"
     echo "SETUP DONE, SLEEP"
     sleep 1
    fi
    deleteSGroups
   fi
   deleteRIfaces
  fi
  deleteSubNets
 fi
 deleteNets
fi
deleteRouters
#echo "${NETSTATS[*]}"
stats NETSTATS
