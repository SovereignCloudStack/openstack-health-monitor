#!/bin/bash
# test_978793.sh
# Testcase trying to reproduce the issue of bug 978793 (unreliable API)
# Creating a large number (30) of VMs, SAP HCP team observes API call timeouts
#
# (c) Kurt Garloff <kurt.garloff@t-systems.com>, 2/2017
# License: CC-BY-SA (2.0)
#
# General approach:
# - create router (VPC)
# - create two nets
# - create two subnets
# - create security groups
# - create virtual IP (for outbound SNAT via JumpHosts)
# - create SSH keys
# - create two JumpHost VMs by
#   a) creating disks (from image)
#   b) creating ports
#   c) creating VMs
# - create N internal VMs by
#   a) creating disks (from image)
#   b) creating a port
#   c) creating VM
#   (Steps a and c take long, so we do many in parallel and poll for progress)
#   d) do some property changes to VMs
# - after everything is complete, we wait
# - and clean up ev'thing in reverse order as soon as user confirms
#
# We do some statistics on the duration of the steps (min, avg, median, max)
# We keep track of resources to clean up.
#
# This takes rather long, as typical API calls take b/w 1 and 2s on OTC
# (including the round trip to keystone for the token) though no undue long
# response was observed in testing so far.
#
# Optimization possibilities:
# - Cache token and reuse when creating a large number of resources in a loop
# - Use cinder list and nova list for polling resource creation progress

# User settings

# Prefix for test resources
RPRE=Test978793_
# Number of VMs and networks
NOVMS=30
NONETS=2
NOAZS=2

# Images, flavors, disk sizes
JHIMG="${JHIMG:-Standard_openSUSE_42_JeOS_latest}"
JHIMGFILT="--property-filter __platform=OpenSUSE"
IMG="${IMG:-Standard_openSUSE_42_JeOS_latest}"
IMGFILT="--property-filter __platform=OpenSUSE"
JHFLAVOR="computev1-1"
FLAVOR="computev1-1"

JHVOLSIZE=4
VOLSIZE=10

DATE=`date +%s`
LOGFILE=$RPRE$DATE.log

# Nothing to change below here
BOLD="\e[0;1m"
NORM="\e[0;0m"
RED="\e[0;31m"
GREEN="\e[0;32m"

if test -z "$OS_USERNAME"; then
  echo "source OS_ settings file before running this test"
  exit 1
fi

usage()
{
  echo "Usage: test_978793.sh [-n NUMVM] [-l LOGFILE] [-p] CLEANUP|DEPLOY"
  echo " CLEANUP cleans up all resources with prefix $RPRE"
  echo " -p sets up ports manually"
  exit 0
}


if test "$1" = "-n"; then NOVMS=$2; shift; shift; fi
if test "${1:0:2}" = "-n"; then NOVMS=${1:2}; shift; fi
if test "$1" = "-l"; then LOGFILE=$2; shift; shift; fi
if test "$1" = "help" -o "$1" = "-h"; then usage; fi
if test "$1" = "-p"; then MANUALPORTSETUP=1; shift; fi

# Command wrapper for openstack commands
# Collecting timing, logging, and extracting id
# $1 = id to extract
# $2-oo => command
ostackcmd_id()
{
  IDNM=$1; shift
  LSTART=$(date +%s.%3N)
  RESP=$($@ 2>&1)
  RC=$?
  LEND=$(date +%s.%3N)
  if test "$IDNM" = "DELETE"; then
    ID=$(echo "$RESP" | grep "^| *status *|" | sed -e "s/^| *status *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$LSTART/$LEND/$ID: $@ => $RC $RESP" >> $LOGFILE
  else
    ID=$(echo "$RESP" | grep "^| *$IDNM *|" | sed -e "s/^| *$IDNM *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$LSTART/$LEND/$ID: $@ => $RC $RESP" >> $LOGFILE
    if test "$RC" != "0"; then echo "ERROR: $@ => $RC $RESP" 1>&2; return $RC; fi
  fi
  TIM=$(python -c "print \"%.2f\" % ($LEND-$LSTART)")
  echo "$TIM $ID"
  return $RC
}

# Another variant -- return results in global variable OSTACKRESP
# Append timing to $1 array
# DO NOT call this in a subshell
OSTACKRESP=""
ostackcmd_tm()
{
  STATNM=$1; shift
  LSTART=$(date +%s.%3N)
  OSTACKRESP=$($@)
  RC=$?
  LEND=$(date +%s.%3N)
  TIM=$(python -c "print \"%.2f\" % ($LEND-$LSTART)")
  eval "${STATNM}+=( $TIM )"
  echo "$LSTART/$LEND/: $@ => $OSTACKRESP" >> $LOGFILE
  return $RC
}

# List of resources - neutron
declare -a ROUTERS
declare -a NETS
declare -a SUBNETS
declare -a JHNETS
declare -a JHSUBNETS
declare -a SGROUPS
declare -a JHPORTS
declare -a PORTS
declare -a VIPS
declare -a FIPS
declare -a FLOATS
# cinder
declare -a JHVOLUMES
declare -a VOLUMES
# nova
declare -a KEYPAIRS
declare -a VMS
declare -a JHVMS
SNATROUTE=""

# Statistics
# API performance neutron, cinder, nova
declare -a NETSTATS
declare -a VOLSTATS
declare -a NOVASTATS
# Resource creation stats (creation/deletion)
declare -a VOLCSTATS
declare -a VOLDSTATS
declare -a VMCSTATS
declare -a VMCDTATS
# Arrays to store resource creation start times
declare -a VOLSTIME
declare -a JVOLSTIME
declare -a VMSTIME
declare -a JVMSTIME

# Create a number of resources and keep track of them
# $1 => quantity of resources
# $2 => name of timing statistics array
# $3 => name of resource list array ("S" appended)
# $4 => name of resource array ("S" appended, use \$VAL to ref) (optional)
# $5 => dito, use \$MVAL (optional, use NONE if unneeded)
# $6 => name of array where we store the timestamp of the operation (opt)
# $7 => id field from resource to be used for storing in $3
# $8- > openstack command to be called
#
# In the command you can reference \$AZ (1 or 2), \$no (running number)
# and \$VAL and \$MVAL (from $4 and $5).
#
# NUMBER STATNM RSRCNM OTHRSRC MORERSRC STIME IDNM COMMAND
createResources()
{
  declare -i ctr=0
  QUANT=$1; STATNM=$2; RNM=$3
  ORNM=$4; MRNM=$5
  STIME=$6; IDNM=$7
  shift; shift; shift; shift; shift; shift; shift
  eval LIST=( \"\${${ORNM}S[@]}\" )
  eval MLIST=( \"\${${MRNM}S[@]}\" )
  if test "$RNM" != "NONE"; then echo -n "New $RNM: "; fi
  # FIXME: Should we get a token once here and reuse it?
  for no in `seq 0 $(($QUANT-1))`; do
    AZ=$(($no%$NOAZS+1))
    VAL=${LIST[$ctr]}
    MVAL=${MLIST[$ctr]}
    CMD=`eval echo $@ 2>&1`
    STM=$(date +%s)
    if test -n "$STIME"; then eval "${STIME}+=( $STM )"; fi
    RESP=$(ostackcmd_id $IDNM $CMD)
    RC=$?
    read TM ID < <(echo "$RESP")
    eval ${STATNM}+="($TM)"
    let ctr+=1
    if test $RC != 0; then echo "ERROR: $RNM creation failed" 1>&2; return 1; fi
    if test -n "$ID" -a "$RNM" != "NONE"; then echo -n "$ID "; fi
    eval ${RNM}S+="($ID)"
  done
  if test "$RNM" != "NONE"; then echo; fi
}

# Delete a number of resources
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to store timestamps (optional, use "" if unneeded)
# $4- > openstack command to be called
# The UUID from the resource list ($2) is appended to the command.
#
# STATNM RSRCNM DTIME COMMAND
deleteResources()
{
  STATNM=$1; RNM=$2; DTIME=$3
  shift; shift; shift
  #eval varAlias=( \"\${myvar${varname}[@]}\" )
  eval LIST=( \"\${${RNM}S[@]}\" )
  #echo $LIST
  test -n "$LIST" && echo -n "Del $RNM: "
  #for rsrc in $LIST; do
  LN=${#LIST[@]}
  while test ${#LIST[*]} -gt 0; do
    rsrc=${LIST[-1]}
    echo -n "$rsrc "
    DTM=$(date +%s)
    if test -n "$DTIME"; then eval "${DTIME}+=( $DTM )"; fi
    read TM < <(ostackcmd_id id $@ $rsrc)
    RC="$?"
    eval ${STATNM}+="($TM)"
    if test $RC != 0; then echo "ERROR" 1>&2: return 1; fi
    unset LIST[-1]
  done
  test $LN -gt 0 && echo
}

# Wait for resources reaching a desired state
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with start times
# $5 => value to wait for
# $6 => alternative value to wait for
# $7 => field name to monitor
# $8- > openstack command for querying status
# The values from $2 get appended to the command
#
# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitResources()
{
  STATNM=$1; RNM=$2; CSTAT=$3; STIME=$4
  COMP1=$5; COMP2=$6; IDNM=$7
  shift; shift; shift; shift; shift; shift; shift
  eval RLIST=( \"\${${RNM}S[@]}\" )
  eval SLIST=( \"\${${STIME}[@]}\" )
  LAST=$(( ${#RLIST[@]} - 1 ))
  while test -n "${SLIST[*]}"; do
    STATSTR=""
    for i in $(seq 0 $LAST ); do
      rsrc=${RLIST[$i]}
      if test -z "${SLIST[$i]}"; then STATSTR+='a'; continue; fi
      CMD=`eval echo $@ $rsrc 2>&1`
      RESP=$(ostackcmd_id $IDNM $CMD)
      RC=$?
      read TM STAT < <(echo "$RESP")
      eval ${STATNM}+="( $TM )"
      if test $RC != 0; then echo "ERROR: Querying $RNM $rsrc failed" 1>&2; return 1; fi
      STATSTR+=${STAT:0:1}
      echo -en "Wait $RNM: $STATSTR\r"
      if test "$STAT" == "$COMP1" -o "$STAT" == "$COMP2"; then
        TM=$(date +%s)
	TM=$(python -c "print \"%i\" % ($TM-${SLIST[$i]})")
	eval ${CSTAT}+="($TM)"
	unset SLIST[$i]
      elif test "$STAT" == "error"; then
        echo "ERROR: $NM $rsrc status $STAT" 1>&2; return 1
      fi
    done
    echo -en "Wait $RNM: $STATSTR\r"
    test -z "${SLIST[*]}" && return 0
    sleep 2
  done
}

# Wait for resources reaching a desired state
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with start times
# $5 => value to wait for (special XDELX)
# $6 => alternative value to wait for
# $7 => number of column (0 based)
# $8- > openstack command for querying status
# The values from $2 get appended to the command
#
# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitlistResources()
{
  STATNM=$1; RNM=$2; CSTAT=$3; STIME=$4
  COMP1=$5; COMP2=$6; COL=$7
  shift; shift; shift; shift; shift; shift; shift
  eval RLIST=( \"\${${RNM}S[@]}\" )
  eval SLIST=( \"\${${STIME}[@]}\" )
  LAST=$(( ${#RLIST[@]} - 1 ))
  PARSE="^|"
  for no in $(seq 1 $COL); do PARSE="$PARSE[^|]*|"; done
  PARSE="$PARSE *\([^|]*\)|.*\$"
  #echo "$PARSE"
  while test -n "${SLIST[*]}"; do
    STATSTR=""
    CMD=`eval echo $@ 2>&1`
    ostackcmd_tm $STATNM $CMD
    if test $? != 0; then echo "ERROR: $CMD => $OSTACKRESP" 1>&2; return 1; fi
    read TM REST < <(echo "$OSTACKRESP")
    for i in $(seq 0 $LAST ); do
      rsrc=${RLIST[$i]}
      if test -z "${SLIST[$i]}"; then STATSTR+='x'; continue; fi
      STAT=$(echo "$OSTACKRESP" | grep "^| $rsrc" | sed -e "s@$PARSE@\1@" -e 's/ *$//')
      #echo "STATUS: \"$STAT\""
      if test -n "$STAT"; then STATSTR+=${STAT:0:1}; else STATSTR+="X"; fi
      #echo -en "Wait $RNM: $STATSTR\r"
      if test "$COMP1" == "XDELX" -a -z "$STAT"; then STAT="XDELX"; fi
      if test "$STAT" == "$COMP1" -o "$STAT" == "$COMP2"; then
        TM=$(date +%s)
	TM=$(python -c "print \"%i\" % ($TM-${SLIST[$i]})")
	eval ${CSTAT}+="($TM)"
	unset SLIST[$i]
      elif test "$STAT" == "error"; then
        echo "ERROR: $NM $rsrc status $STAT" 1>&2; return 1
      fi
    done
    echo -en "Wait $RNM: $STATSTR\r"
    test -z "${SLIST[*]}" && return 0
    sleep 2
  done
}

# Wait for deletion of resources
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with deletion start times
# $5- > openstack command for querying status
# The values from $2 get appended to the command
#
# STATNM RSRCNM DSTAT DTIME COMMAND
waitdelResources()
{
  STATNM=$1; RNM=$2; DSTAT=$3; DTIME=$4
  shift; shift; shift; shift
  eval RLIST=( \"\${${RNM}S[@]}\" )
  eval DLIST=( \"\${${DTIME}[@]}\" )
  LAST=$(( ${#RLIST[@]} - 1 ))
  #echo "waitdelResources $STATNM $RNM $DSTAT $DTIME - ${RLIST[*]} - ${DLIST[*]}"
  while test -n "${DLIST[*]}"; do
    STATSTR=""
    for i in $(seq 0 $LAST); do
      rsrc=${RLIST[$i]}
      if test -z "${DLIST[$i]}"; then STATSTR+='x'; continue; fi
      CMD=`eval echo $@ $rsrc`
      RESP=$(ostackcmd_id DELETE $CMD)
      RC=$?
      read TM STAT < <(echo "$RESP")
      eval ${STATNM}+="( $TM )"
      if test $RC != 0; then
        TM=$(date +%s)
	TM=$(python -c "print \"%i\" % ($TM-${DLIST[$i]})")
	eval ${DSTAT}+="($TM)"
	unset DLIST[$i]
        STATSTR+='x'
      else
        STATSTR+=${STAT:0:1}
      fi
      echo -en "WaitDel $RNM: $STATSTR\r"
    done
    echo -en "WaitDel $RNM: $STATSTR \r"
    test -z "${DLIST[*]}" && return 0
    sleep 2
  done
}

# STATNM RESRNM COMMAND
# Only for the log file
showResources()
{
  STATNM=$1
  RNM=$2
  shift; shift
  eval LIST=( \"\${$RNM}S[@]\" )
  while rsrc in ${LIST}; do
    read TM ID < <(ostackcmd_id id $@ $rsrc)
  done
}


# The commands that create and delete resources ...

createRouters()
{
  createResources 1 NETSTATS ROUTER NONE NONE "" id neutron router-create ${RPRE}Router
}

deleteRouters()
{
  deleteResources NETSTATS ROUTER "" neutron router-delete
}

createNets()
{
  createResources 1 NETSTATS JHNET NONE NONE "" id neutron net-create "${RPRE}NET_JH\$no"
  createResources $NONETS NETSTATS NET NONE NONE "" id neutron net-create "${RPRE}NET_\$no"
}

deleteNets()
{
  deleteResources NETSTATS NET "" neutron net-delete
  deleteResources NETSTATS JHNET "" neutron net-delete
}

createSubNets()
{
  createResources 1 NETSTATS JHSUBNET JHNET NONE "" id neutron subnet-create --dns-nameserver 100.125.4.25 --dns-nameserver 8.8.8.8 --name "${RPRE}SUBNET_JH\$no" "\$VAL" "10.250.250.0/24"
  createResources $NONETS NETSTATS SUBNET NET NONE "" id neutron subnet-create --dns-nameserver 100.125.4.25 --dns-nameserver 8.8.8.8 --name "${RPRE}SUBNET_\$no" "\$VAL" "10.250.\$no.0/24"
}

deleteSubNets()
{
  deleteResources NETSTATS SUBNET "" neutron subnet-delete
  deleteResources NETSTATS JHSUBNET "" neutron subnet-delete
}

createRIfaces()
{
  createResources 1 NETSTATS NONE JHSUBNET NONE "" id neutron router-interface-add ${ROUTERS[0]} "\$VAL"
  createResources $NONETS NETSTATS NONE SUBNET NONE "" id neutron router-interface-add ${ROUTERS[0]} "\$VAL"
}

deleteRIfaces()
{
  deleteResources NETSTATS SUBNET "" neutron router-interface-delete ${ROUTERS[0]}
  deleteResources NETSTATS JHSUBNET "" neutron router-interface-delete ${ROUTERS[0]}
}

createSGroups()
{
  NAMES=( ${RPRE}SG_JumpHost ${RPRE}SG_Internal )
  createResources 2 NETSTATS SGROUP NAME NONE "" id neutron security-group-create "\$VAL" || return
  # And set rules ... (we don't need to keep track of and delete them)
  SG0=${SGROUPS[0]}
  SG1=${SGROUPS[1]}
  # Configure SGs: Internal ingress allowed
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG0 $SG0)
  NETSTATS+=( $TM )
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv6 --remote-group-id $SG0 $SG0)
  NETSTATS+=( $TM )
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG1 $SG1)
  NETSTATS+=( $TM )
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv6 --remote-group-id $SG1 $SG1)
  NETSTATS+=( $TM )
  # Configure RPRE_SG_JumpHost rule: All from the other group, port 222 and 443 from outside
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG1 $SG0)
  NETSTATS+=( $TM )
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix 0/0 $SG0)
  #NETSTATS+=( $TM )
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 222 --port-range-max 222 --remote-ip-prefix 0/0 $SG0)
  NETSTATS+=( $TM )
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix 0/0 $SG0)
  NETSTATS+=( $TM )
  # Configure RPRE_SG_Internal rule: ssh and https and ping from the other group
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-group-id $SG0 $SG1)
  NETSTATS+=( $TM )
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 443 --port-range-max 443 --remote-group-id $SG0 $SG1)
  NETSTATS+=( $TM )
  read TM ID < <(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-group-id $SG0 $SG1)
  NETSTATS+=( $TM )
  #neutron security-group-show $SG0
  #neutron security-group-show $SG1
}

deleteSGroups()
{
  deleteResources NETSTATS SGROUP "" neutron security-group-delete
}

createVIPs()
{
  createResources 1 NETSTATS VIP NONE NONE "" id neutron port-create --name ${RPRE}VirtualIP --security-group ${SGROUPS[0]} ${JHNETS[0]}
  # FIXME: We should not need --allowed-adress-pairs here ...
}

deleteVIPs()
{
  deleteResources NETSTATS VIP "" neutron port-delete
}

createJHPorts()
{
  createResources $NONETS NETSTATS JHPORT NONE NONE "" id neutron port-create --name "${RPRE}Port_JH\${no}" --security-group ${SGROUPS[0]} ${JHNETS[0]} || return
  for i in `seq 0 $((NONETS-1))`; do
    RESP=$(ostackcmd_id id neutron port-update ${JHPORTS[$i]} --allowed-address-pairs type=dict list=true ip_address=0.0.0.0/1 ip_address=128.0.0.0/1)
    RC=$?
    read TM ID < <(echo "$RESP")
    NETSTATS+=( $TM )
    if test $RC != 0; then echo "ERROR: Failed setting allowed-adr-pair for port ${JHPORTS[$i]}" 1>&2; return 1; fi
  done
}

createPorts()
{
  if test -n "$MANUALPORTSETUP"; then
    createResources $NOVMS NETSTATS PORT NONE NONE "" id neutron port-create --name "${RPRE}Port_VM\${no}" --security-group ${SGROUPS[1]} "\${NETS[\$((\$no%$NONETS))]}"
  fi
}

deleteJHPorts()
{
  deleteResources NETSTATS JHPORT "" neutron port-delete
}

deletePorts()
{
  deleteResources NETSTATS PORT "" neutron port-delete
}

createJHVols()
{
  JVOLSTIME=()
  createResources $NONETS VOLSTATS JHVOLUME NONE NONE JVOLSTIME id cinder create --image-id $JHIMGID --name ${RPRE}RootVol_JH\$no --availability-zone eu-de-0\$AZ $JHVOLSIZE
}

# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitJHVols()
{
  #waitResources VOLSTATS JHVOLUME VOLCSTATS JVOLSTIME "available" "NA" "status" cinder show
  waitlistResources VOLSTATS JHVOLUME VOLCSTATS JVOLSTIME "available" "NA" 1 cinder list
}

deleteJHVols()
{
  deleteResources VOLSTATS JHVOLUME "" cinder delete
}

createVols()
{
  VOLSTIME=()
  createResources $NOVMS VOLSTATS VOLUME NONE NONE VOLSTIME id cinder create --image-id $IMGID --name ${RPRE}RootVol_VM\$no --availability-zone eu-de-0\$AZ $VOLSIZE
}

# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitVols()
{
  #waitResources VOLSTATS VOLUME VOLCSTATS VOLSTIME "available" "NA" "status" cinder show
  waitlistResources VOLSTATS VOLUME VOLCSTATS VOLSTIME "available" "NA" 1 cinder list
}

deleteVols()
{
  deleteResources VOLSTATS VOLUME "" cinder delete
}

createKeypairs()
{
  UMASK=$(umask)
  umask 0077
  ostackcmd_tm NOVASTATS nova keypair-add ${RPRE}Keypair_JH || return 1
  echo "$OSTACKRESP" > ${RPRE}Keypair_JH.pem
  KEYPAIRS+=( "${RPRE}Keypair_JH" )
  ostackcmd_tm NOVASTATS nova keypair-add ${RPRE}Keypair_VM || return 1
  echo "$OSTACKRESP" > ${RPRE}Keypair_VM.pem
  KEYPAIRS+=( "${RPRE}Keypair_VM" )
  umask $UMASK
}

deleteKeypairs()
{
  deleteResources NOVASTATS KEYPAIR "" nova keypair-delete
  #rm ${RPRE}Keypair_VM.pem
  #rm ${RPRE}Keypair_JH.pem
}

extract_ip()
{
  echo "$1" | grep '| fixed_ips ' | sed 's/^.*"ip_address": "\([0-9a-f:.]*\)".*$/\1/'
}

SNATROUTE=""
createFIPs()
{
  ostackcmd_tm NETSTATS neutron net-external-list || return 1
  EXTNET=$(echo "$OSTACKRESP" | grep '^| [0-9a-f-]* |' | sed 's/^| [0-9a-f-]* | \([^ ]*\).*$/\1/')
  # Actually this fails if the port is not assigned to a VM yet
  #  -- we can not associate a FIP to a port w/o dev owner
  createResources $NONETS NETSTATS FIP JHPORT NONE "" id neutron floatingip-create --port-id \$VAL $EXTNET
  # TODO: Use API to tell VPC that the VIP is the next hop (route table)
  ostackcmd_tm NETSTATS neutron port-show ${VIPS[0]} || return 1
  VIP=$(extract_ip "$OSTACKRESP")
  ostackcmd_tm NETSTATS neutron router-update ${ROUTERS[0]} --routes type=dict list=true destination=0.0.0.0/0,nexthop=$VIP
  if test $? != 0; then
    echo -e "$BOLD We lack the ability to set VPC route via SNAT gateways by API, will be fixed soon"
    echo -e " Please set next hop $VIP to VPC ${RPRE}Router (${ROUTERS[0]}) routes $NORM"
  else
    #SNATROUTE=$(echo "$OSTACKRESP" | grep "^| *id *|" | sed -e "s/^| *id *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "SNATROUTE: destination=0.0.0.0/0,nexthop=$VIP"
    SNATROUTE=1
  fi
  FLOAT=""
  ostackcmd_tm NETSTATS neutron floatingip-list || return 1
  for PORT in ${FIPS[*]}; do
    FLOAT+=" $(echo "$OSTACKRESP" | grep $PORT | sed 's/^|[^|]*|[^|]*| \([0-9:.]*\).*$/\1/')"
  done
  echo "Floating IPs: $FLOAT"
  FLOATS=( $FLOAT )
}

deleteFIPs()
{
  if test -n "$SNATROUTE"; then
    ostackcmd_tm NETSTATS neutron router-update ${ROUTERS[0]} --no-routes 
  fi
  deleteResources NETSTATS FIP "" neutron floatingip-delete
}

createJHVMs()
{
  REDIRS=()
  ostackcmd_tm NETSTATS neutron port-show ${VIPS[0]} || return 1
  VIP=$(extract_ip "$OSTACKRESP")
  if test ${#PORTS[*]} -gt 0; then
    ostackcmd_tm NETSTATS neutron port-show ${PORTS[-2]}
    REDIRS+=( $(extract_ip "$OSTACKRESP") )
    ostackcmd_tm NETSTATS neutron port-show ${PORTS[-1]}
    REDIRS+=( $(extract_ip "$OSTACKRESP") )
  else
    # We don't know the IP addresses yet -- rely on sequential alloc starting at .4 (OTC)
    REDIRS=( 10.250.0.$((4+($NOVMS-1)/$NONETS)) 10.250.1.$((4+($NOVMS-2)/$NONETS)) )
  fi
  #echo "$VIP ${REDIRS[*]}"
  USERDATA="#cloud-config
otc:
   internalnet:
      - 10.250/16
   snat:
      masqnet:
         - INTERNALNET
      fwdmasq:
         - 0/0,TGT,tcp,222,22
   addip:
      eth0: $VIP
"
  echo "$USERDATA" | sed "s/TGT/${REDIRS[0]}/" > user_data.yaml
  cat user_data.yaml >> $LOGFILE
  # of course nova boot --image ... --nic net-id ... would be easier
  createResources 1 NOVASTATS JHVM JHPORT JHVOLUME JVMSTIME id nova boot --flavor $JHFLAVOR --boot-volume ${JHVOLUMES[0]} --key-name ${KEYPAIRS[0]} --user-data user_data.yaml --availability-zone eu-de-01 --security-groups ${SGROUPS[0]} --nic port-id=${JHPORTS[0]} ${RPRE}VM_JH0 || return
  echo "$USERDATA" | sed "s/TGT/${REDIRS[1]}/" > user_data.yaml
  createResources 1 NOVASTATS JHVM JHPORT JHVOLUME JVMSTIME id nova boot --flavor $JHFLAVOR --boot-volume ${JHVOLUMES[1]} --key-name ${KEYPAIRS[0]} --user-data user_data.yaml --availability-zone eu-de-02 --security-groups ${SGROUPS[0]} --nic port-id=${JHPORTS[1]} ${RPRE}VM_JH1 || return
  #rm user_data.yaml
}

waitJHVMs()
{
  #waitResources NOVASTATS JHVM VMCSTATS JVMSTIME "ACTIVE" "NA" "status" nova show
  waitlistResources NOVASTATS JHVM VMCSTATS JVMSTIME "ACTIVE" "NONONO" 2 nova list
}
deleteJHVMs()
{
  JVMSTIME=()
  deleteResources NOVASTATS JHVM JVMSTIME nova delete
}

waitdelJHVMs()
{
  #waitdelResources NOVASTATS JHVM VMDSTATS JVMSTIME nova show
  waitlistResources NOVASTATS JHVM VMDSTATS JVMSTIME "XDELX" "NONONO" 2 nova list
}

createVMs()
{
  if test -n "$MANUALPORTSETUP"; then
    createResources $NOVMS NOVASTATS VM PORT VOLUME VMSTIME id nova boot --flavor $FLAVOR --boot-volume \$MVAL --key-name ${KEYPAIRS[1]} --availability-zone eu-de-0\$AZ --nic port-id=\$VAL ${RPRE}VM_VM\$no
  else
    # SAVE: createResources $NOVMS NETSTATS PORT NONE NONE "" id neutron port-create --name "${RPRE}Port_VM\${no}" --security-group ${SGROUPS[1]} "\${NETS[\$((\$no%$NONETS))]}"
    createResources $NOVMS NOVASTATS VM NET VOLUME VMSTIME id nova boot --flavor $FLAVOR --boot-volume \$MVAL --key-name ${KEYPAIRS[1]} --availability-zone eu-de-0\$AZ --security-groups ${SGROUPS[1]} --nic "net-id=\${NETS[\$((\$no%$NONETS))]}" ${RPRE}VM_VM\$no
  fi
}
waitVMs()
{
  #waitResources NOVASTATS VM VMCSTATS VMSTIME "ACTIVE" "NA" "status" nova show
  waitlistResources NOVASTATS VM VMCSTATS VMSTIME "ACTIVE" "NONONO" 2 nova list
}
deleteVMs()
{
  VMSTIME=()
  deleteResources NOVASTATS VM VMSTIME nova delete
}
waitdelVMs()
{
  #waitdelResources NOVASTATS VM VMDSTATS VMSTIME nova show
  waitlistResources NOVASTATS VM VMDSTATS VMSTIME XDELX NONONO 2 nova list
}
setmetaVMs()
{
  for no in `seq 0 $(($NOVMS-1))`; do
    ostackcmd_tm NOVASTATS nova meta ${VMS[$no]} set deployment=cf server=$no || return 1
  done
}

wait222()
{
  FLIP=${FLOATS[0]}
  echo -n "Wait for port 222 connectivity on $FLIP: "
  declare -i ctr=0
  while [ $ctr -lt 60 ]; do
    echo "quit" | nc -w2 $FLIP 222 >/dev/null 2>&1 && break
    echo -n "."
    sleep 5
    let ctr+=1
  done
  if [ $ctr -ge 60 ]; then echo " timeout"; return 1; fi
  while [ $ctr -lt 80 ]; do
    echo "quit" | nc -w2 ${FLOATS[1]} 222 >/dev/null 2>&1 && break
    echo -n "."
    sleep 5
    let ctr+=1
  done
  if [ $ctr -ge 80 ]; then echo " timeout"; return 1; fi
  echo
}

testsnat()
{
  unset SSH_AUTH_SOCK
  echo "Test outgoing ping (SNAT) ... "
  ssh -p 222 -i ${KEYPAIRS[1]}.pem -o "StrictHostKeyChecking=no" linux@${FLOATS[0]} ping -i1 -c2 8.8.8.8
  ssh -p 222 -i ${KEYPAIRS[1]}.pem -o "StrictHostKeyChecking=no" linux@${FLOATS[1]} ping -i1 -c2 8.8.8.8
  if test $? = 0; then echo -e "$GREEN SUCCESS $NORM"; else echo -e "$RED FAIL $NORM"; fi
}


# STATLIST [DIGITS]
stats()
{
  eval LIST=( \"\${${1}[@]}\" )
  if test -z "${LIST[*]}"; then return; fi
  DIG=${2:-2}
  IFS=$'\n' SLIST=($(sort -n <<<"${LIST[*]}"))
  #echo ${SLIST[*]}
  MIN=${SLIST[0]}
  MAX=${SLIST[-1]}
  NO=${#SLIST[@]}
  MID=$(($NO/2))
  if test $(($NO%2)) = 1; then MED=${SLIST[$MID]};
  else MED=`python -c "print \"%.${DIG}f\" % ((${SLIST[$MID]}+${SLIST[$(($MID-1))]})/2)"`
  fi
  AVGC="($(echo ${LIST[*]}|sed 's/ /+/g'))/$NO"
  #echo "$AVGC"
  AVG=`python -c "print \"%.${DIG}f\" % ($AVGC)"`
  echo "$1: Min $MIN Max $MAX Med $MED Avg $AVG Num $NO" | tee -a $LOGFILE
}

findres()
{
  FILT=${1:-$RPRE}
  shift
  $@ | grep " $FILT" | sed 's/^| \([0-9a-f-]*\) .*$/\1/'
}

cleanup()
{
  VMS=( $(findres ${RPRE}VM_VM nova list) )
  deleteVMs
  ROUTERS=( $(findres "" neutron router-list) )
  SNATROUTE=1
  #FIPS=( $(findres "" neutron floatingip-list) )
  FIPS=( $(neutron floatingip-list | grep '10\.250\.' | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  deleteFIPs
  JHVMS=( $(findres ${RPRE}VM_JH nova list) )
  deleteJHVMs
  KEYPAIRS=( $(nova keypair-list | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  deleteKeypairs
  VOLUMES=( $(findres ${RPRE}RootVol_VM cinder list) )
  waitdelVMs; deleteVols
  JHVOLUMES=( $(findres ${RPRE}RootVol_JH cinder list) )
  waitdelJHVMs; deleteJHVols
  PORTS=( $(findres ${RPRE}Port_VM neutron port-list) )
  JHPORTS=( $(findres ${RPRE}Port_JH neutron port-list) )
  deletePorts; deleteJHPorts	# not strictly needed, ports are del by VM del
  VIPS=( $(findres ${RPRE}VirtualIP neutron port-list) )
  deleteVIPs
  SGROUPS=( $(findres "" neutron security-group-list) )
  deleteSGroups
  SUBNETS=( $(findres "" neutron subnet-list) )
  deleteRIfaces
  deleteSubNets
  NETS=( $(findres "" neutron net-list) )
  deleteNets
  deleteRouters
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
 echo -e "$BOLD *** Start deployment $NONETS SNAT JumpHosts + $NOVMS VMs *** $NORM"
 # Image IDs
 JHIMGID=$(glance image-list $JHIMGFILT | grep "$JHIMG" | head -n1 | sed 's/| \([0-9a-f-]*\).*$/\1/')
 IMGID=$(glance image-list $IMGFILT | grep "$IMG" | head -n1 | sed 's/| \([0-9a-f-]*\).*$/\1/')
 if test -z "$JHIMGID"; then echo "ERROR: No image $JHIMG found, aborting."; exit 1; fi
 if test -z "$IMGID"; then echo "ERROR: No image $IMG found, aborting."; exit 1; fi
 #echo "Image $IMGID $JHIMGID"
 if createRouters; then
  if createNets; then
   if createSubNets; then
    if createRIfaces; then
     if createSGroups; then
      if createVIPs; then
       if createJHPorts && createPorts; then
        if createJHVols; then
         if createVols; then
          waitJHVols
          if createKeypairs; then
           if createJHVMs; then
            if createFIPs; then
             waitJHVMs
             waitVols
             if createVMs; then
              waitVMs
              setmetaVMs
              wait222
              testsnat
              MSTOP=$(date +%s)
              # We should be able to log in to FIP port 222 now ...
              echo -en "$BOLD *** SETUP DONE ($(($MSTOP-$MSTART))s), HIT ENTER TO STOP $NORM"
              read ANS
              MSTART=$(($MSTART+$(date +%s)-$MSTOP))
             fi; deleteVMs
            fi; deleteFIPs
           fi; deleteJHVMs
          fi; deleteKeypairs
         fi; waitdelVMs; deleteVols
        fi; waitdelJHVMs; deleteJHVols
       fi;
       echo -e "${BOLD}Ignore port del errors; VM cleanup took care already.${NORM}"
       deletePorts; deleteJHPorts	# not strictly needed, ports are del by VM del
      fi; deleteVIPs
     fi; deleteSGroups
    fi; deleteRIfaces
   fi; deleteSubNets
  fi; deleteNets
 fi; deleteRouters
 #echo "${NETSTATS[*]}"
 echo -e "$BOLD *** Cleanup complete *** $NORM"
 stats NETSTATS
 stats NOVASTATS
 stats VMCSTATS 0
 stats VMDSTATS 0
 stats VOLSTATS
 stats VOLCSTATS 0
 echo "Overall ($NOVMS + $NONETS) VMs: $(($(date +%s)-$MSTART))s"
else
  usage
fi
