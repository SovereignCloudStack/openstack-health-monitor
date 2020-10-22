#!/bin/bash
# api_monitor.sh
# 
# Test script testing the reliability and performance of OpenStack API
# It works by doing a real scenario test: Setting up a real environment
# With routers, nets, jumphosts, disks, VMs, ...
# 
# We collect statistics on API call performance as well as on resource
# creation times.
# Failures are noted and alarms are generated.
#
# Status:
# - Errors not yet handled everywhere
# - Live Volume and NIC attachment not yet implemented
# - Log too verbose for permament operation ...
# - Script allows to create multiple nets/subnets independent from no of AZs,
#   which may need more testing.
# - Done: Convert from neutron/cinder/nova/... to openstack (-o / -O)
#
# TODO:
# - Align sendalarm with Grafana database entries
#
# (c) Kurt Garloff <kurt.garloff@t-systems.com>, 2/2017-7/2017
# License: CC-BY-SA (2.0)
#
# General approach:
# - create router (VPC)
# - create 1+$NONETS (1+2) nets -- $NONETS is normally the # of AZs
# - create 1+$NONETS subnets
# - create security groups
# - create virtual IP (for outbound SNAT via JumpHosts)
# - create SSH keys
# - create $NOAZS JumpHost VMs by
#   a) creating disks (from image)
#   b) creating ports
#   c) creating VMs
# - associating a floating IP to each Jumphost
# - configuring the virtIP as default route
# - JumpHosts do SNAT for outbound traffic and port forwarding for inbound
#   (this used to require SUSE images with SFW2-snat package to work, but now
#    should work on most images, assuming iptables rules can be configured)
# - create N internal VMs striped over the nets and AZs by
#   a) creating disks (from image) -- if option -d is not used
#   b) creating a port -- if option -P is not used
#   c) creating VM (from volume or from image, dep. on -d)
#   (Steps a and c take long, so we do many in parallel and poll for progress)
#   d) do some property changes to VMs
# - after everything is complete, we wait for the VMs to be up
# - we ping them, log in via ssh and see whether they can ping to the outside world (quad9)
#
# - Finally, we clean up ev'thing in reverse order
#   (We have kept track of resources to clean up.
#    We can also identify them by name, which helps if we got interrupted, or
#    some cleanup action failed.)
#
# So we end up testing: Router, incl. default route (for SNAT instance),
#  networks, subnets, and virtual IP, security groups and floating IPs,
#  volume creation from image, deletion after VM destruction
#  VM creation from bootable volume (and from image if -d is given)
#  Metadata service (without it ssh key injection fails of course)
#  Images (we use openSUSE for the jumphost for SNAT/port-fwd and CentOS7 by dflt for VMs)
#  Waiting for volumes and VMs
#  Destroying all of these resources again
#
# We do some statistics on the duration of the steps (min, avg, median, 95% quantile, max)
# We of course also note any errors and timeouts and report these, optionally sending
#  email or (on OTC) SMN alarms.
#
# This takes rather long, as typical CLI calls take b/w 1 and 5s on OpenStack clouds
# (including the round trip to keystone for the token).
#
# Future enhancements:
# - dynamically attach an additional disk
# - dynamically attach an additional NIC (we do this already with -2/-3/-4)
# - test DNS (designate)
#
# Optimization possibilities:
# - DONE: Cache token and reuse when creating a large number of resources in a loop
#   Use option -O (not used for volume create and image and LB stuff)
#
# Prerequisites:
# - Working python-XXXclient tools (openstack, glance, neutron, nova, cinder)
# - Optionally otc.sh from otc-tools (only if using optional SMN -m and project creation -p)
# - Optionally sendmail (only if email notification is requested)
# - jq (for JSON processing)
# - python2 or 3 for math used to calc statistics
# - SUSE image with SNAT/port-fwd (SuSEfirewall2-snat pkg) for the JumpHosts recommended
#   (but we can do manual iptables settings otherwise nowadays)
# - Any image for the VMs that allows login as user DEFLTUSER (linux) with injected key
#   (If we use -2/-3/-4, we also need a SUSE image to have the cloud-multiroute pkg in there.)
#
# Example:
# Run 100 loops deploying (and deleting) 2+8 VMs (including nets, volumes etc.),
# booting VMs directly from images (and creating ports implicitly), but with single calls (no -D).
# with daily statistics sent to SMN...APIMon-Notes and Alarms to SMN...APIMonitor
# ./api_monitor.sh -n 8 -d -P -s -m urn:smn:eu-de:0ee085d22f6a413293a2c37aaa1f96fe:APIMon-Notes -m urn:smn:eu-de:0ee085d22f6a413293a2c37aaa1f96fe:APIMonitor -i 100
# (SMN is OTC specific notification service that supports sending SMS.)

VERSION=1.62

# debugging
if test "$1" == "--debug"; then set -x; shift; fi

# TODO: Document settings that can be ovverriden by environment variables
# such as PINGTARGET, ALARMPRE, FROM, [JH]IMG, [JH]IMGFILT, JHDEFLTUSER, DEFLTUSER, [JH]FLAVOR

# User settings
#if test -z "$PINGTARGET"; then PINGTARGET=f-ed2-i.F.DE.NET.DTAG.DE; fi
if test -z "$PINGTARGET"; then PINGTARGET=dns.quad9.net; fi
if test -z "$PINGTARGET2"; then PINGTARGET2=google-public-dns-b.google.com; fi

# Prefix for test resources
FORCEDEL=NONONO
if test -z "$RPRE"; then RPRE="APIMonitor_$$_"; fi
if test "$RPRE" == "${RPRE%_}"; then echo "Need trailing _ for prefix RPRE"; exit 1; fi
SHORT_DOMAIN="${OS_USER_DOMAIN_NAME##*OTC*00000000001000}"
SHPRJ="${OS_PROJECT_NAME%_Project}"
ALARMPRE="${SHORT_DOMAIN:3:3}/${OS_REGION_NAME}/${SHPRJ#*_}"
SHORT_DOMAIN=${SHORT_DOMAIN:-$OS_PROJECT_NAME}
GRAFANANM="${GRAFANANM:-api-monitoring}"

# Number of VMs and networks
if test -z "$AZS"; then
  #AZS=$(nova availability-zone-list 2>/dev/null| grep -v '\-\-\-' | grep -v 'not available' | grep -v '| Name' | sed 's/^| \([^ ]*\) *.*$/\1/' | sort -n)
  #AZS=$(openstack availability zone list 2>/dev/null| grep -v '\-\-\-' | grep -v 'not available' | grep -v '| Name' | grep -v '| Zone Name' | sed 's/^| \([^ ]*\) *.*$/\1/' | sort -n)
  AZS=$(openstack availability zone list -f json | jq '.[] | select(."Zone Status" == "available")."Zone Name"'  | tr -d '"')
  if test -z "$AZS"; then AZS=$(otc.sh vm listaz 2>/dev/null | grep -v region | sort -n); fi
  if test -z "$AZS"; then AZS="eu-de-01 eu-de-02"; fi
fi
AZS=($AZS)
#echo "${#AZS[*]} AZs: ${AZS[*]}"; exit 0
NOAZS=${#AZS[*]}
if test -z "$VAZS"; then
  #VAZS=$(cinder availability-zone-list 2>/dev/null| grep -v '\-\-\-' | grep -v 'not available' | grep -v '| Name' | sed 's/^| \([^ ]*\) *.*$/\1/' | sort -n)
  #VAZS=$(openstack availability zone list --volume 2>/dev/null| grep -v '\-\-\-' | grep -v 'not available' | grep -v '| Name' | grep -v '| Zone Name' | sed 's/^| \([^ ]*\) *.*$/\1/' | sort -n)
  VAZS=$(openstack availability zone list --volume -f json | jq '.[] | select(."Zone Status" == "available")."Zone Name"'  | tr -d '"')
  if test -z "$VAZS"; then VAZS=(${AZS[*]}); else VAZS=($VAZS); fi
fi
NOVAZS=${#VAZS[*]}
NOVMS=12
NONETS=$NOAZS
MANUALPORTSETUP=1
ROUTERITER=1
if [[ $OS_AUTH_URL == *otc*t-systems.com* ]]; then
  NAMESERVER=${NAMESERVER:-100.125.4.25}
fi

MAXITER=-9999

ERRWAIT=1
VMERRWAIT=2

unset DISASSOC

# API timeouts
NETTIMEOUT=24
FIPTIMEOUT=32
NOVATIMEOUT=28
NOVABOOTTIMEOUT=48
CINDERTIMEOUT=32
GLANCETIMEOUT=32
DEFTIMEOUT=20
TIMEOUTFACT=1

REFRESHPRJ=0
SUCCWAIT=${SUCCWAIT:-5}

DOMAIN=$(grep '^search' /etc/resolv.conf | awk '{ print $2; }'; exit ${PIPESTATUS[0]}) || DOMAIN=otc.t-systems.com
HOSTNAME=$(hostname)
FQDN=$(hostname -f 2>/dev/null) || FQDN=$HOSTNAME.$DOMAIN
echo "Running api_monitor.sh v$VERSION on host $FQDN"
if test -z "$OS_PROJECT_NAME"; then
	TRIPLE="$OS_CLOUD"
	STRIPLE="$OS_CLOUD"
	ALARMPRE="$OS_CLOUD"
else
	TRIPLE="$OS_USER_DOMAIN_NAME/$OS_PROJECT_NAME/$OS_REGION_NAME"
	STRIPLE="$SHORT_DOMAIN/$SHPRJ/$OS_REGION_NAME"
fi
if ! echo "$@" | grep '\(CLEANUP\|CONNTEST\)' >/dev/null 2>&1; then
  echo "Using $RPRE prefix for resrcs on $TRIPLE (${AZS[*]})"
fi

# Images, flavors, disk sizes defaults -- these can be overriden
# Ideally have SUSE image with SuSEfirewall2-snat for JumpHosts, will be detected
# otherwise raw iptables commands will set up SNAT.
JHIMG="${JHIMG:-Standard_openSUSE_15_latest}"
# Pass " " to filter if you don't need the optimization of image filtering
JHIMGFILT="${JHIMGFILT:---property-filter __platform=OpenSUSE}"
# For 2nd interface (-2/3/4), use also SUSE image with cloud-multiroute
IMG="${IMG:-Standard_CentOS_7_latest}"
IMGFILT="${IMGFILT:---property-filter __platform=CentOS}"
# ssh login names with injected key
DEFLTUSER=${DEFLTUSER:-linux}
JHDEFLTUSER=${JHDEFLTUSER:-$DEFLTUSER}
# OTC flavor names as defaults
#JHFLAVOR=${JHFLAVOR:-computev1-1}
JHFLAVOR=${JHFLAVOR:-s2.medium.1}
FLAVOR=${FLAVOR:-s2.medium.1}

if [[ "$JHIMG" != *openSUSE* ]]; then
  echo "WARN: port forwarding via SUSEfirewall2-snat user_data is better tested ..." >/dev/null
fi

# Optionally increase JH and VM volume sizes beyond image size
# (slows things down due to preventing quick_start and growpart)
ADDJHVOLSIZE=${ADDJHVOLSIZE:-0}
ADDVMVOLSIZE=${ADDVMVOLSIZE:-0}

DATE=`date +%s`
LOGFILE=$RPRE$DATE.log
declare -i APIERRORS=0
declare -i APITIMEOUTS=0
declare -i APICALLS=0
declare -i TOTERR=0

# Nothing to change below here
BOLD="\e[0;1m"
REV="\e[0;3m"
NORM="\e[0;0m"
RED="\e[0;31m"
GREEN="\e[0;32m"
YELLOW="\e[0;33m"


# python3?
if test -n "$(type -p python3)"; then PYTHON3=$(type -p python3); else unset PYTHON3; fi

usage()
{
  #echo "Usage: api_monitor.sh [-n NUMVM] [-l LOGFILE] [-p] CLEANUP|DEPLOY"
  echo "Usage: api_monitor.sh [options]"
  echo " --debug Use set -x to print every line executed"
  echo " -n N   number of VMs to create (beyond #AZ JumpHosts, def: 12)"
  echo " -N N   number of networks/subnets/jumphosts to create (def: # AZs)"
  echo " -l LOGFILE record all command in LOGFILE"
  echo " -e ADR sets eMail address for notes/alarms (assumes working MTA)"
  echo "         second -e splits eMails; notes go to first, alarms to second eMail"
  echo " -E     exit on error (for CONNTEST)"
  echo " -m URN sets notes/alarms by SMN (pass URN of queue)"
  echo "         second -m splits notifications; notes to first, alarms to second URN"
  echo " -s     sends stats as well once per day, not just alarms"
  echo " -S [NM] sends stats to grafana via local telegraf http_listener (def for NM=api-monitoring)"
  echo " -q     do not send any alarms"
  echo " -d     boot Directly from image (not via volume)"
  echo " -P     do not create Port before VM creation"
  echo " -D     create all VMs with one API call (implies -d -P)"
  echo " -i N   sets max number of iterations (def = -1 = inf)"
  echo " -r N   only recreate router after each Nth iteration"
  echo " -g N   increase VM volume size by N GB (ignored for -d/-D)"
  echo " -G N   increase JH volume size by N GB"
  echo " -w N   sets error wait (API, VM): 0-inf seconds or neg value for interactive wait"
  echo " -W N   sets error wait (VM only): 0-inf seconds or neg value for interactive wait"
  echo " -V N   set success wait: Stop for N seconds (neg val: interactive) before tearing down"
  echo " -p N   use a new project every N iterations"
  echo " -c     noColors: don't use bold/red/... ASCII sequences"
  echo " -C     full Connectivity check: Every VM pings every other"
  echo " -o     translate nova/cinder/neutron/glance into openstack client commands"
  echo " -O     like -o, but use token_endpoint auth (after getting token)"
  echo " -x     assume eXclusive project, clean all floating IPs found"
  echo " -I     dIsassociate floating IPs before deleting them"
  echo " -L     create Loadbalancer (LBaaSv2/octavia) and test it"
  echo " -t     long Timeouts (2x, multiple times for 3x, 4x, ...)"
  echo " -2     Create 2ndary subnets and attach 2ndary NICs to VMs and test"
  echo " -3     Create 2ndary subnets, attach, test, reshuffle and retest"
  echo " -4     Create 2ndary subnets, reshuffle, attach, test, reshuffle and retest"
  echo " -R     Recreate 2ndary ports after detaching (OpenStack <= Mitaka bug)"
  echo "Or: api_monitor.sh [-f] CLEANUP XXX to clean up all resources with prefix XXX"
  echo "        Option -f forces the deletion"
  echo "Or: api_monitor.sh [Options] CONNTEST XXX for full conn test for existing env XXX"
  echo "        Options: [-2/3/4] [-o/O] [-i N] [-e ADR] [-E] [-w/W/V N] [-l LOGFILE]"
  echo "You need to have the OS_ variables set to allow OpenStack CLI tools to work."
  echo "You can override defaults by exporting the environment variables AZS, VAZS, RPRE,"
  echo " PINGTARGET, PINGTARGET2, GRAFANANM, [JH]IMG, [JH]IMGFILT, [JH]FLAVOR, [JH]DEFLTUSER,"
  echo " ADDJHVOLSIZE, ADDVMVOLSIZE, SUCCWAIT, ALARMPRE, FROM, ALARM_/NOTE_EMAIL_ADDRESSES[],"
  echo " NAMESERVER."
  echo "Typically, you should configure [JH]IMG, [JH]IMGFILT, [JH]FLAVOR, [JH]DEFLTUSER."
  exit 0
}

while test -n "$1"; do
  case $1 in
    "-n") NOVMS=$2; shift;;
    "-n"*) NOVMS=${1:2};;
    "-N") NONETS=$2; shift;;
    "-l") LOGFILE=$2; shift;;
    "help"|"-h"|"--help") usage;;
    "-s") SENDSTATS=1;;
    "-S") GRAFANA=1;
          if test -n "$2" -a "$2" != "CLEANUP" -a "$2" != "DEPLOY" -a "${2:0:1}" != "-"; then GRAFANANM="$2"; shift; fi;;
    "-P") unset MANUALPORTSETUP;;
    "-d") BOOTFROMIMAGE=1;;
    "-D") BOOTALLATONCE=1; BOOTFROMIMAGE=1; unset MANUALPORTSETUP;;
    "-e") if test -z "$EMAIL"; then EMAIL="$2"; else EMAIL2="$2"; fi; shift;;
    "-m") if test -z "$SMNID"; then SMNID="$2"; else SMNID2="$2"; fi; shift;;
    "-q") NOALARM=1;;
    "-i") MAXITER=$2; shift;;
    "-g") ADDVMVOLSIZE=$2; shift;;
    "-G") ADDJHVOLSIZE=$2; shift;;
    "-w") ERRWAIT=$2; shift;;
    "-W") VMERRWAIT=$2; shift;;
    "-V") SUCCWAIT=$2; shift;;
    "-f") FORCEDEL=XDELX;;
    "-p") REFRESHPRJ=$2; shift;;
    "-c") NOCOL=1;;
    "-C") FULLCONN=1;;
    "-o") OPENSTACKCLIENT=1;;
    "-O") OPENSTACKCLIENT=1; OPENSTACKTOKEN=1;;
    "-x") CLEANALLFIPS=1;;
    "-I") DISASSOC=1;;
    "-r") ROUTERITER=$2; shift;;
    "-L") LOADBALANCER=1;;
    "-t") let TIMEOUTFACT+=1;;
    "-R") SECONDRECREATE=1;;
    "-2") SECONDNET=1;;
    "-3") SECONDNET=1; RESHUFFLE=1;;
    "-4") SECONDNET=1; RESHUFFLE=1; STARTRESHUFFLE=1;;
    "-E") EXITERR=1;;
    "--debug") set -x;;
    "--os-cloud") export OS_CLOUD="$2"; shift;;
    "--os-cloud="*) export OS_CLOUD="${1#--os-cloud=}";;
    "CLEANUP") break;;
    "CONNTEST") if test "$MAXITER" == "-9999"; then MAXITER=1; fi; break;;
    *) echo "Unknown argument \"$1\""; exit 1;;
  esac
  shift
done

if test "$1" != "CONNTEST"; then
  trap exithandler SIGINT
  if test -n "$SECONDNET" -a -z "$FULLCONN"; then
    echo "Warning: 2ndary interfaces (-2/3/4) without full conn test (-C)?"
  fi
fi

# Test precondition
type -p openstack >/dev/null 2>&1
if test $? != 0; then
  echo "Need openstack client installed"
  exit 1
fi

type -p jq >/dev/null 2>&1
if test $? != 0; then
  echo "Need jq installed"
  exit 1
fi

type -p otc.sh >/dev/null 2>&1
if test $? != 0 -a -n "$SMNID"; then
  echo "Need otc.sh for SMN notifications"
  exit 1
fi

test -x /usr/sbin/sendmail
if test $? != 0 -a -n "$EMAIL"; then
  echo "Need /usr/sbin/sendmail for email notifications"
  exit 1
fi

if test -z "$OS_USERNAME" -a -z "$OS_CLOUD"; then
  echo "source OS_ settings file before running this test"
  exit 1
fi

if ! openstack router list >/dev/null; then
  echo "openstack neutron call failed, exit"
  exit 2
fi

if test "$NOCOL" == "1"; then
  BOLD="**"
  REV="__"
  NORM=" "
  RED="!!"
  GREEN="++"
  YELLOW=".."
fi

# For sed expressions without confusing vim
SQ="'"
# openstackclient/XXXclient compat
if test -n "$OPENSTACKCLIENT"; then
  PORTFIXED="s/^.*ip_address=$SQ\([0-9a-f:.]*\)$SQ.*$/\1/"
  PORTFIXED2="s/ip_address=$SQ\([0-9a-f:.]*\)$SQ.*$/\1/"
  FLOATEXTR='s/^|[^|]*| \([0-9:.]*\).*$/\1/'
  VOLSTATCOL=2
else
  PORTFIXED='s/^.*"ip_address": "\([0-9a-f:.]*\)".*$/\1/'
  FLOATEXTR='s/^|[^|]*|[^|]*| \([0-9:.]*\).*$/\1/'
  VOLSTATCOL=1
fi

# Sanity checks
# Last subnet is for the JumpHosts, thus we have 63 /22 networks avail within 10.250/16
if test ${NONETS} -gt 63; then
  echo "Can not create more than 63 (sub)networks"
  exit 1
fi

# We reserve 6 IPs, so allow max 1018 in our /22 net
if test $((NOVMS/NONETS)) -gt 1018; then
  echo "Can not create more than 1018 VMs per (sub)net"
  echo " Please decrease -n or increase -N"
  exit 1
fi

# Alarm notification
# $1 => return code
# $2 => invoked command
# $3 => command output
# $4 => timeout (for rc=137)
sendalarm()
{
  local PRE RES RM URN TOMSG
  local RECEIVER_LIST RECEIVER
  DATE=$(date)
  if test $1 = 0; then
    PRE="Note"
    RES=""
    echo -e "$BOLD$PRE on $ALARMPRE/${RPRE%_} on $HOSTNAME: $2\n$DATE\n$3$NORM" 1>&2
  elif test $1 -gt 128; then
    PRE="TIMEOUT $4"
    RES=" => $1"
    echo -e "$RED$PRE on $ALARMPRE/${RPRE%_} on $HOSTNAME: $2\n$DATE\n$3$NORM" 1>&2
  else
    PRE="ALARM $1"
    RES=" => $1"
    echo -e "$RED$PRE on $ALARMPRE/${RPRE%_} on $HOSTNAME: $2\n$DATE\n$3$NORM" 1>&2
  fi
  TOMSG=""
  if test "$4" != "0" -a $1 != 0 -a $1 != 1; then
    TOMSG="(Timeout: ${4}s)"
    echo -e "$BOLD$PRE(Timeout: ${4}s)$NORM" 1>&2
  fi
  if test -n "$NOALARM"; then return; fi
  if test $1 != 0; then
    RECEIVER_LIST=("${ALARM_EMAIL_ADDRESSES[@]}")
  else
    RECEIVER_LIST=("${NOTE_EMAIL_ADDRESSES[@]}")
  fi
  if test -n "$EMAIL"; then
    if test -n "$EMAIL2" -a $1 != 0; then EM="$EMAIL2"; else EM="$EMAIL"; fi
    RECEIVER_LIST=("$EM" "${RECEIVER_LIST[@]}")
  fi
  FROM="${FROM:-$LOGNAME@$FQDN}"
  for RECEIVER in "${RECEIVER_LIST[@]}"
  do
    echo "From: ${RPRE%_} $HOSTNAME <$FROM>
To: $RECEIVER
Subject: $PRE on $ALARMPRE: $2
Date: $(date -R)

$PRE on $STRIPLE

${RPRE%_} on $HOSTNAME:
$2
$3
$TOMSG" | /usr/sbin/sendmail -t -f $FROM
  done
  if test $1 != 0; then
    RECEIVER_LIST=("${ALARM_MOBILE_NUMBERS[@]}")
  else
    RECEIVER_LIST=("${NOTE_MOBILE_NUMBERS[@]}")
  fi
  if test -n "$SMNID"; then
    if test -n "$SMNID2" -a $1 != 0; then URN="$SMNID2"; else URN="$SMNID"; fi
    RECEIVER_LIST=("$URN" "${RECEIVER_LIST[@]}")
  fi
  for RECEIVER in "${RECEIVER_LIST[@]}"
  do
    echo "$PRE on $STRIPLE: $DATE
${RPRE%_} on $HOSTNAME:
$2
$3
$TOMSG" | otc.sh notifications publish $RECEIVER "$PRE from $HOSTNAME/$ALARMPRE"
  done
}

rc2bin()
{
  if test $1 = 0; then echo 0; return 0; else echo 1; return 1; fi
}

# Map return code to 2 (timeout), 1 (error), or 0 (success) for Grafana
# $1 => input (RC), returns global var GRC
rc2grafana()
{
  if test $1 == 0; then GRC=0; elif test $1 -ge 128; then GRC=2; else GRC=1; fi
}

updAPIerr()
{
  let APIERRORS+=$(rc2bin $1);
  if test $1 -ge 129; then let APITIMEOUTS+=1; fi
}

declare -i EXITED=0
exithandler()
{
  loop=$(($MAXITER-1))
  if test "$EXITED" = "0"; then
    echo -e "\n${REV}SIGINT received, exiting after this iteration$NORM"
  elif test "$EXITED" = "1"; then
    echo -e "\n$BOLD OK, cleaning up right away $NORM"
    FORCEDEL=NONONO
    cleanup
    if test "$REFRESHPRJ" != 0; then cleanprj; fi
    kill -TERM 0
  else
    echo -e "\n$RED OK, OK, exiting without cleanup. Use api_monitor.sh CLEANUP $RPRE to do so.$NORM"
    if test "$REFESHPRJ" != 0; then echo -e "${RED}export OS_PROJECT_NAME=$OS_PROJECT_NAME before doing so$NORM"; fi
    kill -TERM 0
  fi
  let EXITED+=1
}

errwait()
{
  if test $1 -lt 0; then
    local ans
    echo -en "${YELLOW}ERROR: Hit Enter to continue: $NORM"
    read ans
  else
    sleep $1
  fi
}


# Timeout killer
# $1 => PID to kill
# $2 => timeout
# waits $2, sends QUIT, 1s, HUP, 1s, KILL
killin()
{
  sleep $2
  test -d /proc/$1 || return 0
  kill -SIGQUIT $1
  sleep 1
  kill -SIGHUP $1
  sleep 1
  kill -SIGKILL $1
}

NOVA_EP="${NOVA_EP:-novaURL}"
CINDER_EP="${CINDER_EP:-cinderURL}"
NEUTRON_EP="${NEUTRON_EP:-neutronURL}"
GLANCE_EP="${GLANCE_EP:-glanceURL}"
OSTACKCMD=""; EP=""
# Translate nova/cinder/neutron ... to openstack commands
translate()
{
  local DEFCMD=""
  CMDS=(nova cinder neutron glance)
  OSTDEFS=(server volume network image)
  EPS=($NOVA_EP $CINDER_EP $NEUTRON_EP $GLANCE_EP)
  for no in $(seq 0 $((${#CMDS[*]}-1))); do
    if test ${CMDS[$no]} == $1; then
      EP=${EPS[$no]}
      DEFCMD=${OSTDEFS[$no]}
    fi
  done
  OSTACKCMD=("$@")
  if test "$1" == "myopenstack" -a -z "$OPENSTACKTOKEN" -o -z "$EP"; then shift; OSTACKCMD=("openstack" "$@"); return 0; fi
  if test -z "$OPENSTACKCLIENT" -o "$1" == "openstack" -o "$1" == "myopenstack"; then return 0; fi
  if test -n "$LOGFILE"; then echo "#DEBUG: $@" >> $LOGFILE; fi
  #echo "#DEBUG: $@" 1>&2
  if test -z "$DEFCMD"; then echo "ERROR: Unknown cmd $@" 1>&2; return 1; fi
  local OPST
  if test -n "$OPENSTACKTOKEN" -a "$DEFCMD" != "image"; then OPST=myopenstack; else OPST=openstack; fi
  shift
  CMD=${1##*-}
  if test "$CMD" == "$1"; then
    # No '-'
    shift
    OSTACKCMD=($OPST $DEFCMD $CMD "$@")
    if test "$DEFCMD" == "volume" -a "$CMD" == "create"; then
      ARGS=$(echo "$@" | sed -e 's/\-\-image\-id/--image/' -e 's/\-\-name \([^ ]*\) *\([0-9]*\) *$/--size \2 \1/')
      #OSTACKCMD=($OPST $DEFCMD $CMD $ARGS)
      # No token_endpoint auth for volume creation (need to talk to image service as well?)
      OSTACKCMD=(openstack $DEFCMD $CMD $ARGS)
    # Optimization: Avoid image and flavor name lookups in server list when polling
    elif test "$DEFCMD" == "server" -a "$CMD" == "list"; then
      ARGS=$(echo "$@" | sed -e 's@\-\-sort display_name:asc@--sort-column Name@')
      OSTACKCMD=($OPST $DEFCMD $CMD $ARGS -n)
    # Optimization: Avoid Attachment name lookup in volume list when polling
    elif test "$DEFCMD" == "volume" -a "$CMD" == "list"; then OSTACKCMD=("${OSTACKCMD[@]}" -c ID -c Name -c Status -c Size)
    #echo "#DEBUG: ${OSTACKCMD[@]}" 1>&2
    elif test "$DEFCMD" == "server" -a "$CMD" == "boot"; then
      # Only handles one SG
      ARGS=$(echo "$@" | sed -e 's@\-\-boot\-volume@--volume@' -e 's@\-\-security\-groups@--security-group@' -e 's@\-\-min\-count@--min@' -e 's@\-\-max\-count@--max@')
      #OSTACKCMD=($OPST $DEFCMD create $ARGS)
      # No token_endpoint auth for server creation (need to talk to neutron/cinder/glance as well)
      OSTACKCMD=(openstack $DEFCMD create $ARGS)
    elif test "$DEFCMD" == "server" -a "$CMD" == "meta"; then
      # nova meta ${VMS[$no]} set deployment=$CFTEST server=$no
      ARGS=$(echo "$@" | sed -e 's@set @@' -e 's@\([a-zA-Z_0-9]*=[^ ]*\)@--property \1@g')
      OSTACKCMD=($OPST $DEFCMD set $ARGS)
    fi
  else
    C1=${1%-*}
    if test "$C1" == "net"; then C1="network"; fi
    if test "$C1" == "floatingip"; then C1="floating ip"; fi
    if test "$C1" == "keypair" -a "$CMD" == "add"; then CMD="create"; fi
    C1=${C1//-/ }
    shift
    #OSTACKCMD=($OPST $C1 $CMD "$@")
    OSTACKCMD=($OPST $C1 $CMD "${@//--property-filter/--property}")
    if test "$C1" == "subnet" -a "$CMD" == "create"; then
      ARGS=$(echo "$@" | sed -e 's@\-\-disable-dhcp@--no-dhcp@' -e 's@\-\-name \([^ ]*\) *\([^ ]*\) *\([^ ]*\)@--network \2 --subnet-range \3 \1@')
      OSTACKCMD=($OPST $C1 $CMD ${ARGS})
    elif test "$C1" == "floating ip" -a "$CMD" == "create"; then
      ARGS=$(echo "$@" | sed 's@\-\-port\-id@--port@')
      OSTACKCMD=($OPST $C1 $CMD ${ARGS})
    elif test "$C1" == "net external"; then
      OSTACKCMD=($OPST network $CMD --external "$@")
    elif test "$C1" == "port" -a "$CMD" == "create"; then
      ARGS=$(echo "$@" | sed -e 's@subnet_id=@subnet=@g' -e 's@\-\-name \([^ ]*\) *\([^ ]*\)@--network \2 \1@')
      OSTACKCMD=($OPST $C1 $CMD ${ARGS})
    elif test "$C1" == "port" -a "$CMD" == "update"; then
      # --allowed-address-pairs type=dict list=true ip_address=0.0.0.0/1 ip_address=128.0.0.0/1)
      ARGS=$(echo "$@" | sed -e 's@\-\-allowed-address-pairs type=dict list=true@@' -e 's@ip_address=\([^ ]*\)@--allowed-address ip-address=\1@g')
      OSTACKCMD=($OPST $C1 set ${ARGS})
    elif test "$C1" == "router" -a "$CMD" == "update"; then
      # --routes type=dict list=true destination=0.0.0.0/0,nexthop=$VIP
      ARGS=$(echo "$@" | sed -e 's@\-\-routes type=dict list=true@@' -e 's@destination=\([^ ,]*\),nexthop=\([^ ,]*\)@--route destination=\1,gateway=\2@g' -e 's/\-\-no\-routes/--no-route/')
      OSTACKCMD=($OPST $C1 set ${ARGS})
    elif test "$C1" == "router interface" -a "$CMD" == "add"; then
      OSTACKCMD=($OPST router add subnet "$@")
    elif test "$C1" == "router interface" -a "$CMD" == "delete"; then
      OSTACKCMD=($OPST router remove subnet "$@")
    elif test "$C1" == "router gateway" -a "$CMD" == "set"; then
      #neutron router-gateway-set ${ROUTERS[0]} $EXTNET
      ARGS=$(echo "$@" | sed 's/\([^-][^ ]*\) *\([^ ]*\)/--external-gateway \2 \1/')
      OSTACKCMD=($OPST router set "${ARGS[@]}")
    elif test "$C1" == "security group rule" -a "$CMD" == "create"; then
      ARGS=$(echo "$@" | sed -e 's/\-\-direction ingress/--ingress/' -e 's/\-\-direction egress/--egress/' -e 's/\-\-remote\-ip\-prefix/--remote-ip/' -e 's/\-\-remote\-group\-id/--remote-group/' -e 's/\-\-protocol tcp *\-\-port\-range\-min \([0-9]*\) *\-\-port\-range\-max \([0-9]*\)/--protocol tcp --dst-port \1:\2/' -e 's/\-\-protocol icmp *\-\-port\-range\-min \([0-9]*\) *\-\-port\-range\-max \([0-9]*\)/--protocol icmp --icmp-type \1 --icmp-code \2/')
      if ! echo "$ARGS" | grep '\-\-protocol' >/dev/null 2>&1; then ARGS="$ARGS --protocol any"; fi
      OSTACKCMD=($OPST $C1 $CMD $ARGS)
    # No token_endpoint auth for vNIC at/detachment
    elif test "$C1" == "interface" -a "$CMD" == "attach"; then
      C1="server"; CMD="add port"; OPST="openstack"
      ARGS=$(echo "$@" | sed -e 's@\-\-port\-id \([^ ]*\) *\([^ ]*\)$@\2 \1@')
      OSTACKCMD=($OPST $C1 $CMD $ARGS)
    elif test "$C1" == "interface" -a "$CMD" == "detach"; then
      C1="server"; CMD="remove port"; OPST="openstack"
      # The interface-detach syntax is not symmetric to interface-attach, ouch!
      #ARGS=$(echo "$@" | sed -e 's@--port-id \([^ ]\) *\([^ ]*\)$@\2 \1@')
      #OSTACKCMD=($OPST $C1 $CMD $ARGS)
      OSTACKCMD=($OPST $C1 $CMD $@)
    elif test "$C1" == "lbaas loadbalancer"; then
      OSTACKCMD=(openstack loadbalancer $CMD $@)
    elif test "$C1" == "lbaas pool"; then
      OSTACKCMD=(openstack loadbalancer pool $CMD --wait $@)
    elif test "$C1" == "lbaas listener"; then
      ARGS=$(echo "$@" | sed 's/--loadbalancer //')
      OSTACKCMD=(openstack loadbalancer listener $CMD --wait $ARGS)
    elif test "$C1" == "lbaas member"; then
      OSTACKCMD=(openstack loadbalancer member $CMD --wait $@)
    fi
    #echo "#DEBUG: ${OSTACKCMD[@]}" 1>&2
  fi
  if test -n "$LOGFILE"; then echo "#=> : ${OSTACKCMD[@]}" >> $LOGFILE; fi
  return 0
}

# Do some math (python syntax)
# $1 => formatting
# $2 => math expr
math()
{
  if test -n ${PYTHON3}; then
    python3 -c "print(\"$1\" % ($2))"
  else
    python -c "print \"$1\" % ($2)"
  fi
}

# Wrapper for calling openstack
# Allows to inject OS_TOKEN and OS_URL to enforce token_endpoint auth
myopenstack()
{
  #TODO: Check whether old openstack client version accept the syntax (maybe they need --os-auth-type admin_token?)
  #echo "openstack --os-auth-type token_endpoint --os-project-name \"\" --os-token {SHA1}$(echo $TOKEN| sha1sum) --os-url $EP $@" >> $LOGFILE
  echo "openstack --os-token {SHA1}$(echo $TOKEN| sha1sum) --os-endpoint $EP $@" >> $LOGFILE
  #OS_CLOUD="" OS_PROJECT_NAME="" OS_PROJECT_ID="" OS_PROJECT_DOMAIN_ID="" OS_USER_DOMAIN_NAME="" OS_PROJECT_DOMAIN_NAME="" exec openstack --os-auth-type token_endpoint --os-project-name "" --os-token $TOKEN --os-url $EP "$@"
  #OS_CLOUD="" OS_PROJECT_NAME="" OS_PROJECT_ID="" OS_PROJECT_DOMAIN_ID="" OS_USER_DOMAIN_NAME="" OS_PROJECT_DOMAIN_NAME="" exec openstack --os-token $TOKEN --os-endpoint $EP "$@"
  OS_CLOUD="" OS_PROJECT_NAME="" OS_PROJECT_ID="" OS_PROJECT_DOMAIN_ID="" OS_USER_DOMAIN_NAME="" OS_PROJECT_DOMAIN_NAME="" exec openstack --os-token $TOKEN --os-endpoint $EP --os-auth-type admin_token --os-project-name="" "$@"
  #OS_PASSWORD="" OS_USERNAME="" OS_PROJECT_DOMAIN_NAME="" OS_PROJECT_NAME="" OS_PROJECT_DOMAIN_ID="" OS_USER_DOMAIN_NAME=""
}

# Command wrapper for openstack list commands
# $1 = search term
# $2 = timeout (in s)
# $3-oo => command
# Return value: Error from command
# Output: "TIME ID"
ostackcmd_search()
{
  local SEARCH=$1; shift
  local TIMEOUT=$1; shift
  if test $TIMEOUTFACT -gt 1; then let TIMEOUT*=$TIMEOUTFACT; fi
  local LSTART=$(date +%s.%3N)
  translate "$@"
  if test "$TIMEOUT" = "0"; then
    RESP=$(${OSTACKCMD[@]} 2>&1)
  else
    RESP=$(${OSTACKCMD[@]} 2>&1 & TPID=$!; killin $TPID $TIMEOUT >/dev/null 2>&1 & KPID=$!; wait $TPID; RC=$?; kill $KPID; exit $RC)
  fi
  local RC=$?
  local LEND=$(date +%s.%3N)
  ID=$(echo "$RESP" | grep "$SEARCH" | head -n1 | sed -e 's/^| *\([^ ]*\) *|.*$/\1/')
  echo "$LSTART/$LEND/$SEARCH: ${OSTACKCMD[@]} => $RC $RESP $ID" >> $LOGFILE
  if test $RC != 0 -a -z "$IGNORE_ERRORS"; then
    sendalarm $RC "$*" "$RESP" $TIMEOUT
    errwait $ERRWAIT
  fi
  local TIM=$(math "%.2f" "$LEND-$LSTART")
  if test "$RC" != "0"; then echo "$TIM $RC"; echo -e "${YELLOW}ERROR: ${OSTACKCMD[@]} => $RC $RESP$NORM" 1>&2; return $RC; fi
  if test -z "$ID"; then echo "$TIM $RC"; echo -e "${YELLOW}ERROR: ${OSTACKCMD[@]} => $RC $RESP => $SEARCH not found$NORM" 1>&2; return $RC; fi
  echo "$TIM $ID"
  return $RC
}

# Command wrapper for openstack commands
# Collecting timing, logging, and extracting id
# $1 = id to extract
# $2 = timeout (in s)
# $3-oo => command
# Return value: Error from command
# Output: "TIME ID"
ostackcmd_id()
{
  local IDNM=$1; shift
  local TIMEOUT=$1; shift
  if test $TIMEOUTFACT -gt 1; then let TIMEOUT*=$TIMEOUTFACT; fi
  local LSTART=$(date +%s.%3N)
  translate "$@"
  if test "$TIMEOUT" = "0"; then
    RESP=$(${OSTACKCMD[@]} 2>&1)
  else
    RESP=$(${OSTACKCMD[@]} 2>&1 & TPID=$!; killin $TPID $TIMEOUT >/dev/null 2>&1 & KPID=$!; wait $TPID; RC=$?; kill $KPID; exit $RC)
  fi
  local RC=$?
  local LEND=$(date +%s.%3N)
  local TIM=$(math "%.2f" "$LEND-$LSTART")

  test "$1" = "openstack" -o "$1" = "myopenstack" && shift
  if test -n "$GRAFANA"; then
      # log time / rc to grafana
      rc2grafana $RC
      curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=$1,method=$2 duration=$TIM,return_code=$GRC $(date +%s%N)" >> grafana.log
  fi

  if test $RC != 0 -a -z "$IGNORE_ERRORS"; then
    sendalarm $RC "$*" "$RESP" $TIMEOUT
    errwait $ERRWAIT
  fi
  if test "$IDNM" = "DELETE"; then
    ID=$(echo "$RESP" | grep "^| *status *|" | sed -e "s/^| *status *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$LSTART/$LEND/$ID: ${OSTACKCMD[@]} => $RC $RESP" >> $LOGFILE
  else
    ID=$(echo "$RESP" | grep "^| *$IDNM *|" | sed -e "s/^| *$IDNM *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "$LSTART/$LEND/$ID: ${OSTACKCMD[@]} => $RC $RESP" >> $LOGFILE
    if test "$RC" != "0" -a -z "$IGNORE_ERRORS"; then echo "$TIM $RC"; echo -e "${YELLOW}ERROR: ${OSTACKCMD[@]} => $RC $RESP$NORM" 1>&2; return $RC; fi
  fi
  echo "$TIM $ID"
  return $RC
}

# Another variant -- return results in global variable OSTACKRESP
# Append timing to $1 array
# $2 = timeout (in s)
# $3-oo command
# Return value: Error from command
# Output: None (but sets timing array and OSTACKRESP)
# DO NOT call this in a subshell
# As this is not in a subshell, we can also do API error counting directly ...
OSTACKRESP=""
ostackcmd_tm()
{
  local STATNM=$1; shift
  local TIMEOUT=$1; shift
  if test $TIMEOUTFACT -gt 1; then let TIMEOUT*=$TIMEOUTFACT; fi
  local LSTART=$(date +%s.%3N)
  # We can count here, as we are not in a subprocess
  let APICALLS+=1
  translate "$@"
  if test "$TIMEOUT" = "0"; then
    OSTACKRESP=$(${OSTACKCMD[@]} 2>&1)
  else
    OSTACKRESP=$(${OSTACKCMD[@]} 2>&1 & TPID=$!; killin $TPID $TIMEOUT >/dev/null 2>&1 & KPID=$!; wait $TPID; RC=$?; kill $KPID; exit $RC)
  fi
  local RC=$?
  if test $RC != 0 -a -z "$IGNORE_ERRORS"; then
    # We can count here, as we are not in a subprocess
    let APIERRORS+=1
    sendalarm $RC "$*" "$OSTACKRESP" $TIMEOUT
    errwait $ERRWAIT
  fi
  # We capture stderr in the response, need to remove neutron deprecation warning
  # TODO: Would be better to capture stderr elsewhere and just use in case of errors
  if test "${OSTACKCMD[0]}" == "neutron"; then
    OSTACKRESP=$(echo "$OSTACKRESP" | sed 's@neutron CLI is deprecated and will be removed in the future\. Use openstack CLI instead\.@@g')
  fi
  local LEND=$(date +%s.%3N)
  local TIM=$(math "%.2f" "$LEND-$LSTART")
  test "$1" = "openstack" -o "$1" = "myopenstack" && shift
  if test -n "$GRAFANA"; then
    # log time / rc to grafana telegraph
    rc2grafana $RC
    # Note: We log untranslated commands to grafana here, for continuity reasons
    # (This is why we do translation in the first place ...)
    curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=$1,method=$2 duration=$TIM,return_code=$GRC $(date +%s%N)" >> grafana.log
  fi
  eval "${STATNM}+=( $TIM )"
  echo "$LSTART/$LEND/: ${OSTACKCMD[@]} => $OSTACKRESP" >> $LOGFILE
  return $RC
}

# Create a number of resources and keep track of them
# $1 => quantity of resources
# $2 => name of timing statistics array
# $3 => name of resource list array ("S" appended)
# $4 => name of resource array ("S" appended, use \$VAL to ref) (optional)
# $5 => dito, use \$MVAL (optional, use NONE if unneeded)
# $6 => name of array where we store the timestamp of the operation (opt)
# $7 => id field from resource to be used for storing in $3
# $8 => timeout
# $9- > openstack command to be called
#
# In the command you can reference \$AZ (1 or 2), \$no (running number)
# and \$VAL and \$MVAL (from $4 and $5).
#
# NUMBER STATNM RSRCNM OTHRSRC MORERSRC STIME IDNM COMMAND
createResources()
{
  local ctr
  declare -i ctr=0
  local QUANT=$1; local STATNM=$2; local RNM=$3
  local ORNM=$4; local MRNM=$5
  local STIME=$6; local IDNM=$7
  shift; shift; shift; shift; shift; shift; shift
  local TIMEOUT=$1; shift
  #if test $TIMEOUTFACT -gt 1; then let TIMEOUT+=2; fi
  eval local LIST=( \"\${${ORNM}S[@]}\" )
  eval local MLIST=( \"\${${MRNM}S[@]}\" )
  if test "$RNM" != "NONE"; then echo -n "New $RNM: "; fi
  local RC=0
  local TIRESP
  # FIXME: Should we get a token once here and reuse it?
  for no in `seq 0 $(($QUANT-1))`; do
    local AZN=$(($no%$NOAZS))
    local VAZN=$(($no%$NOVAZS))
    local AZ=$(($AZ+1))
    local VAZ=$(($VAZ+1))
    local VAL=${LIST[$ctr]}
    local MVAL=${MLIST[$ctr]}
    local CMD=`eval echo $@ 2>&1`
    local STM=$(date +%s)
    if test -n "$STIME"; then eval "${STIME}+=( $STM )"; fi
    let APICALLS+=1
    TIRESP=$(ostackcmd_id $IDNM $TIMEOUT $CMD)
    RC=$?
    #echo "DEBUG: ostackcmd_id $CMD => $RC" 1>&2
    updAPIerr $RC
    local TM
    read TM ID <<<"$TIRESP"
    if test $RC == 0; then eval ${STATNM}+="($TM)"; fi
    let ctr+=1
    # Workaround for teuto.net
    if test "$1" = "cinder" && [[ $OS_AUTH_URL == *teutostack* ]]; then echo -en " ${RED}+5s${NORM} " 1>&2; sleep 5; fi
    if test $RC != 0; then echo -e "${YELLOW}ERROR: $RNM creation failed$NORM" 1>&2; return 1; fi
    if test -n "$ID" -a "$RNM" != "NONE"; then echo -n "$ID "; fi
    eval ${RNM}S+="($ID)"
  done
  if test "$RNM" != "NONE"; then echo; fi
}

# Delete a number of resources
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to store timestamps (optional, use "" if unneeded)
# $4 => timeout
# $5- > openstack command to be called
# The UUID from the resource list ($2) is appended to the command.
#
# STATNM RSRCNM DTIME COMMAND
deleteResources()
{
  local STATNM=$1; local RNM=$2; local DTIME=$3
  local ERR=0
  shift; shift; shift
  local TIMEOUT=$1; shift
  #if test $TIMEOUTFACT -gt 1; then let TIMEOUT+=2; fi
  local FAILDEL=()
  eval local LIST=( \"\${${ORNM}S[@]}\" )
  #eval local varAlias=( \"\${myvar${varname}[@]}\" )
  eval local LIST=( \"\${${RNM}S[@]}\" )
  #echo $LIST
  test -n "$LIST" && echo -n "Del $RNM: "
  #for rsrc in $LIST; do
  local LN=${#LIST[@]}
  local TIRESP
  local IGNERRS=0
  while test ${#LIST[*]} -gt 0; do
    local rsrc=${LIST[-1]}
    echo -n "$rsrc "
    local DTM=$(date +%s)
    if test -n "$DTIME"; then eval "${DTIME}+=( $DTM )"; fi
    local TM
    let APICALLS+=1
    TIRESP=$(ostackcmd_id id $TIMEOUT $@ $rsrc)
    local RC="$?"
    if test -z "$IGNORE_ERRORS"; then
      updAPIerr $RC
    else
      let IGNERRS+=$RC
      RC=0
    fi
    read TM ID <<<"$TIRESP"
    if test $RC != 0; then
      echo -e "${YELLOW}ERROR deleting $RNM $rsrc; retry and continue ...$NORM" 1>&2
      let ERR+=1
      sleep 2
      TIRESP=$(ostackcmd_id id $(($TIMEOUT+8)) $@ $rsrc)
      RC=$?
      updAPIerr $RC
      if test $RC != 0; then FAILDEL+=($rsrc); fi
    else
      eval ${STATNM}+="($TM)"
    fi
    unset LIST[-1]
  done
  if test -n "$IGNORE_ERRORS" -a $IGNERRS -gt 0; then echo -n " ($IGNERRS errors ignored) "; fi
  test $LN -gt 0 && echo
  # FIXME: Should we try again immediately?
  if test -n "$FAILDEL"; then
    echo "Store failed dels in REM${RNM}S for later re-cleanup: ${FAILDEL[*]}"
    eval "REM${RNM}S=(${FAILDEL[*]})"
  fi
  return $ERR
}

# Convert status to colored one-char string
# $1 => status string
# $2 => wanted1
# $3 => wanted2 (optional)
# Return code: 3 == missing, 2 == found, 1 == ERROR, 0 in progress
colstat()
{
  if test "$2" == "NONNULL" -a -n "$1" -a "$1" != "null"; then
    echo -e "${GREEN}*${NORM}"; return 2
  elif test "$2" == "$1" || test -n "$3" -a "$3" == "$1"; then
    echo -e "${GREEN}${1:0:1}${NORM}"; return 2
  elif test "${1:0:5}" == "error" -o "${1:0:5}" == "ERROR"; then
    echo -e "${RED}${1:0:1}${NORM}"; return 1
  elif test -n "$1"; then
    echo "${1:0:1}"
  else
    # Handle empty (error)
    echo "?"; return 3
  fi
  return 0
}


# Wait for resources reaching a desired state
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with start times
# $5 => value to wait for
# $6 => alternative value to wait for
# $7 => field name to monitor
# $8 => timeout
# $9- > openstack command for querying status
# The values from $2 get appended to the command
#
# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitResources()
{
  ERRRSC=()
  local STATNM=$1; local RNM=$2; local CSTAT=$3; local STIME=$4
  local COMP1=$5; local COMP2=$6; local IDNM=$7
  shift; shift; shift; shift; shift; shift; shift
  local TIMEOUT=$1; shift
  #if test $TIMEOUTFACT -gt 1; then let TIMEOUT+=2; fi
  local STATI=()
  eval local RLIST=( \"\${${RNM}S[@]}\" )
  eval local SLIST=( \"\${${STIME}[@]}\" )
  local LAST=$(( ${#RLIST[@]} - 1 ))
  declare -i ctr=0
  declare -i WERR=0
  local TIRESP
  while test -n "${SLIST[*]}" -a $ctr -le 320; do
    local STATSTR=""
    for i in $(seq 0 $LAST ); do
      local rsrc=${RLIST[$i]}
      if test -z "${SLIST[$i]}"; then STATSTR+=$(colstat "${STATI[$i]}" "$COMP1" "$COMP2"); continue; fi
      local CMD=`eval echo $@ $rsrc 2>&1`
      let APICALLS+=1
      TIRESP=$(ostackcmd_id $IDNM $TIMEOUT $CMD)
      local RC=$?
      updAPIerr $RC
      local TM STAT
      read TM STAT <<<"$TIRESP"
      eval ${STATNM}+="( $TM )"
      if test $RC != 0; then echo -e "\n${YELLOW}ERROR: Querying $RNM $rsrc failed$NORM" 1>&2; return 1; fi
      STATI[$i]=$STAT
      STATSTR+=$(colstat "$STAT" "$COMP1" "$COMP2")
      STE=$?
      echo -en "Wait $RNM: $STATSTR\r"
      if test $STE != 0; then
        if test $STE == 1 -o $STE == 3; then
          echo -e "\n${YELLOW}ERROR: $NM $rsrc status $STAT$NORM" 1>&2 #; return 1
          ERRRSC[$WERR]=$rsrc
          let WERR+=1
        fi
        TM=$(date +%s)
        TM=$(math "%i" "$TM-${SLIST[$i]}")
        eval ${CSTAT}+="($TM)"
        if test -n "$GRAFANA"; then
          # log time / rc to grafana
          if test $STE -ge 2; then RC=0; else RC=$STE; fi
          curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=wait$RNM,method=$COMP1 duration=$TM,return_code=$RC $(date +%s%N)" >> grafana.log
        fi
        unset SLIST[$i]
      fi
    done
    echo -en "Wait $RNM: $STATSTR\r"
    if test -z "${SLIST[*]}"; then echo; return $WERR; fi
    let ctr+=1
    sleep 2
  done
  if test $ctr -ge 320; then let WERR+=1; fi
  echo
  return $WERR
}

# Wait for resources reaching a desired state
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with start times
# $5 => value to wait for (special XDELX)
# $6 => alternative value to wait for 
#       (special: 2ndary XDELX results in waiting also for ERRORED res.)
# $7 => number of column (0 based)
# $8 => timeout
# $9- > openstack command for querying status
# The values from $2 get appended to the command
#
# Return value: Number of resources not in desired state (e.g. error, wrong state, missing, ...)
#
# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitlistResources()
{
  ERRRSC=()
  local STATNM=$1; local RNM=$2; local CSTAT=$3; local STIME=$4
  local COMP1=$5; local COMP2=$6; local COL=$7
  local NERR=0
  shift; shift; shift; shift; shift; shift; shift
  local TIMEOUT=$1; shift
  #if test $TIMEOUTFACT -gt 1; then let TIMEOUT+=2; fi
  local STATI=()
  eval local RLIST=( \"\${${RNM}S[@]}\" )
  eval RRLIST=( \"\${${RNM}S[@]}\" )
  eval local SLIST=( \"\${${STIME}[@]}\" )
  local LAST=$(( ${#RLIST[@]} - 1 ))
  local PARSE="^|"
  local WAITVAL
  if test "$COMP1" == "XDELX"; then WAITVAL="del"; else WAITVAL="$COMP1"; fi
  for no in $(seq 1 $COL); do PARSE="$PARSE[^|]*|"; done
  PARSE="$PARSE *\([^|]*\)|.*\$"
  #echo "$PARSE"
  declare -i ctr=0
  declare -i WERR=0
  declare -i misserr=0
  local waitstart=$(date +%s)
  if test -n "$CSTAT"; then MAXWAIT=240; else MAXWAIT=30; fi
  if test -z "${RLIST[*]}"; then return 0; fi
  while test -n "${SLIST[*]}" -a $ctr -le $MAXWAIT; do
    local STATSTR=""
    local CMD=`eval echo $@ 2>&1`
    ostackcmd_tm $STATNM $TIMEOUT $CMD
    if test $? != 0; then
      echo -e "\n${YELLOW}ERROR: $CMD => $OSTACKRESP$NORM" 1>&2
      # Only bail out after 4th error;
      # so we retry in case there are spurious 500/503 (throttling) errors
      # Do not give up so early on waiting for deletion ...
      let NERR+=1
      if test $NERR -ge 4 -a "$COMP1" != "XDELX" -o $NERR -ge 20; then return 1; fi
      sleep 10
    fi
    local TM
    misserr=0
    for i in $(seq 0 $LAST ); do
      local rsrc=${RLIST[$i]}
      if test -z "${SLIST[$i]}"; then STATSTR+=$(colstat "${STATI[$i]}" "$COMP1" "$COMP2"); continue; fi
      local STAT=$(echo "$OSTACKRESP" | grep "^| $rsrc" | sed -e "s@$PARSE@\1@" -e 's/ *$//')
      #echo "STATUS: \"$STAT\""
      if test "$COMP1" == "XDELX" -a -z "$STAT"; then STAT="XDELX"; fi
      STATI[$i]="$STAT"
      STATSTR+=$(colstat "$STAT" "$COMP1" "$COMP2")
      STE=$?
      #echo -en "Wait $RNM: $STATSTR\r"
      # Found or ERROR
      if test $STE != 0; then
        # ERROR
        if test $STE == 1 -o $STE == 3; then
          # Really wait for deletion of errored resources?
          if test "$COMP2" == "XDELX"; then continue; fi
          ERRRSC[$WERR]=$rsrc
          let WERR+=1
          let misserr+=1
          echo -e "\n${YELLOW}ERROR: $NM $rsrc status $STAT$NORM" 1>&2 #; return 1
        fi
        # Found
        TM=$(date +%s)
        TM=$(math "%i" "$TM-${SLIST[$i]}")
        unset RRLIST[$i]
        unset SLIST[$i]
        if test -n "$CSTAT"; then
          eval ${CSTAT}+="($TM)"
          if test -n "$GRAFANA"; then
            # log time / rc to grafana
            if test $STE -ge 2; then RC=0; else RC=$STE; fi
            curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=wait$RNM,method=$COMP1 duration=$TM,return_code=$RC $(date +%s%N)" >> grafana.log
          fi
        fi
      fi
    done
    echo -en "\rWait $WAITVAL $RNM[${#SLIST[*]}/${#RLIST[*]}]: $STATSTR "
    # Save 3s
    if test -z "${SLIST[*]}"; then break; fi
    # We can stop waiting if all resources have failed/disappeared (more than once)
    if test $misserr -ge ${#RLIST[@]} -a $WERR -ge $((${#RLIST[@]}*2)); then break; fi
    sleep 3
    let ctr+=1
  done
  if test $ctr -ge $MAXWAIT; then let WERR+=${#SLIST[*]}; let misserr=${#SLIST[*]}; fi
  if test -n "${SLIST[*]}"; then
    echo " TIMEOUT $(($(date +%s)-$waitstart))"
    echo -e "\n${YELLOW}Wait TIMEOUT/ERROR${NORM} ($(($(date +%s)-$waitstart))s, $ctr iterations), LEFT: ${RED}${RRLIST[*]}:${SLIST[*]}${NORM}" 1>&2
    #FIXME: Shouldn't we send an alarm right here?
  else
    echo " ($(($(date +%s)-$waitstart))s, $ctr iterations)"
  fi
  return $misserr
}

# UNUSED!
# Wait for deletion of resources
# $1 => name of timing statistics array
# $2 => name of array containing resources ("S" appended)
# $3 => name of array to collect completion timing stats
# $4 => name of array with deletion start times
# $5 => timeout
# $6- > openstack command for querying status
# The values from $2 get appended to the command
#
# STATNM RSRCNM DSTAT DTIME COMMAND
waitdelResources()
{
  local STATNM=$1; local RNM=$2; local DSTAT=$3; local DTIME=$4
  shift; shift; shift; shift
  local TIMEOUT=$1; shift
  #if test $TIMEOUTFACT -gt 1; then let TIMEOUT+=2; fi
  eval local RLIST=( \"\${${RNM}S[@]}\" )
  eval local DLIST=( \"\${${DTIME}[@]}\" )
  local STATI=()
  local LAST=$(( ${#RLIST[@]} - 1 ))
  local STATI=()
  local RESP
  #echo "waitdelResources $STATNM $RNM $DSTAT $DTIME - ${RLIST[*]} - ${DLIST[*]}"
  declare -i ctr=0
  while test -n "${DLIST[*]}"i -a $ctr -le 320; do
    local STATSTR=""
    for i in $(seq 0 $LAST); do
      local rsrc=${RLIST[$i]}
      if test -z "${DLIST[$i]}"; then STATSTR+=$(colstat "${STATI[$i]}" "XDELX" ""); continue; fi
      local CMD=`eval echo $@ $rsrc`
      let APICALLS+=1
      RESP=$(ostackcmd_id DELETE $TIMEOUT $CMD)
      local RC=$?
      updAPIerr $RC
      local TM STAT
      read TM STAT <<<"$RESP"
      eval ${STATNM}+="( $TM )"
      if test $RC != 0; then
        TM=$(date +%s)
        TM=$(math "%i" "$TM-${DLIST[$i]}")
        eval ${DSTAT}+="($TM)"
        unset DLIST[$i]
        STAT="XDELX"
      fi
      STATI[$i]=$STAT
      STATSTR+=$(colstat "$STAT" "XDELX" "")
      if test -n "$GRAFANA"; then
        # log time / rc to grafana
        rc2grafana $RC
        curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=wait$RNM,method=DEL duration=$TM,return_code=$GRC $(date +%s%N)" >> grafana.log
      fi
      #echo -en "WaitDel $RNM: $STATSTR\r"
    done
    echo -en "WaitDel $RNM: $STATSTR \r"
    if test -z "${DLIST[*]}"; then echo; return 0; fi
    sleep 2
    let ctr+=1
  done
  if test $ctr -ge 320; then let WERR+=1; fi
  if test -n "${DLIST[*]}"; then echo -e "\nLEFT: ${RED}${DLIST[*]}${NORM}"; else echo; fi
  return $WERR
}

# Handle waitlistResources return value:
# Do nothing for $? == 0.
# Otherwise do custom commands (typically XXX show) for each resource in $ERRRSC[*]
# This is to create additional info in the debug log file
# $1: Statistics array
# $2: Command timeout
# $3-...: Command
# Function return original $?
handleWaitErr()
{
  local RV=$?
  local rsrc
  if test $RV = 0; then return $RV; fi
  for rsrc in ${ERRRSC[*]}; do
    ostackcmd_tm "$@" $rsrc
  done
  return $RV
}

# STATNM RESRNM COMMAND
# Only for the log file
# $1 => STATS
# $2 => Resource listname
# $3 => timeout
showResources()
{
  local STATNM=$1
  local RNM=$2
  local RESP
  shift; shift
  local TIMEOUT=$1; shift
  #if test $TIMEOUTFACT -gt 1; then let TIMEOUT+=2; fi
  eval local LIST=( \"\${$RNM}S[@]\" )
  local rsrc TM
  while rsrc in ${LIST}; do
    let APICALLS+=1
    RESP=$(ostackcmd_id id $TIMEOUT $@ $rsrc)
    updAPIerr $?
    #read TM ID <<<"$RESP"
  done
}


# The commands that create and delete resources ...

createRouters()
{
  if test -z "$ROUTERS"; then
    createResources 1 NETSTATS ROUTER NONE NONE "" id $FIPTIMEOUT neutron router-create ${RPRE}Router
  fi
}

deleteRouters()
{
  deleteResources NETSTATS ROUTER "" $(($FIPTIMEOUT+8)) neutron router-delete
  RC=$?
  if test $RC == 0; then ROUTERS=(); fi
  return $RC
}

createNets()
{
  createResources 1 NETSTATS JHNET NONE NONE "" id $NETTIMEOUT neutron net-create "${RPRE}NET_JH\$no"
  createResources $NONETS NETSTATS NET NONE NONE "" id $NETTIMEOUT neutron net-create "${RPRE}NET_VM_\$no"
}

deleteNets()
{
  if test -n "$SECONDNET"; then
    deleteResources NETSTATS SECONDNET "" $NETTIMEOUT neutron net-delete
  fi
  deleteResources NETSTATS NET "" $NETTIMEOUT neutron net-delete
  deleteResources NETSTATS JHNET "" $NETTIMEOUT neutron net-delete
}

# We allocate 10.250.$((no*4)/22 for the VMs and 10.250.255.0/24 for all JumpHosts (one per AZ)
JHSUBNETIP=10.250.255.0/24

createSubNets()
{
  if test -n "$NAMESERVER"; then
    createResources 1 NETSTATS JHSUBNET JHNET NONE "" id $NETTIMEOUT neutron subnet-create --dns-nameserver 9.9.9.9 --dns-nameserver $NAMESERVER --name "${RPRE}SUBNET_JH\$no" "\$VAL" "$JHSUBNETIP"
    createResources $NONETS NETSTATS SUBNET NET NONE "" id $NETTIMEOUT neutron subnet-create --dns-nameserver $NAMESERVER --dns-nameserver 9.9.9.9 --name "${RPRE}SUBNET_\$no" "\$VAL" "10.250.\$((no*4)).0/22"
  else
    createResources 1 NETSTATS JHSUBNET JHNET NONE "" id $NETTIMEOUT neutron subnet-create --name "${RPRE}SUBNET_JH\$no" "\$VAL" "$JHSUBNETIP"
    createResources $NONETS NETSTATS SUBNET NET NONE "" id $NETTIMEOUT neutron subnet-create --name "${RPRE}SUBNET_VM_\$no" "\$VAL" "10.250.\$((no*4)).0/22"
  fi
}

create2ndSubNets()
{
  if test -n "$SECONDNET"; then
    SECONDNETS=(); SECONDSUBNETS=()
    createResources $NONETS NETSTATS SECONDNET NONE NONE "" id $NETTIMEOUT neutron net-create "${RPRE}NET2_VM_\$no"
    #createResources $NONETS NETSTATS SECONDSUBNET NET NONE "" id $NETTIMEOUT neutron subnet-create --disable-dhcp --name "${RPRE}SUBNET2_\$no" "\$VAL" "10.251.\$((no+4)).0/22"
    createResources $NONETS NETSTATS SECONDSUBNET SECONDNET NONE "" id $NETTIMEOUT neutron subnet-create --name "${RPRE}SUBNET2_VM_\$no" "\$VAL" "10.251.\$((no*4)).0/22"
    createResources $NONETS NETSTATS NONE SECONDSUBNET NONE "" id $FIPTIMEOUT neutron router-interface-add ${ROUTERS[0]} "\$VAL"
  fi
}

deleteSubNets()
{
  # TODO: Need to wait for LB being gone?
  if test -n "$SECONDNET"; then
    deleteResources NETSTATS SECONDSUBNET "" $NETTIMEOUT neutron subnet-delete
  fi
  deleteResources NETSTATS SUBNET "" $NETTIMEOUT neutron subnet-delete
  deleteResources NETSTATS JHSUBNET "" $NETTIMEOUT neutron subnet-delete
}

# Plug subnets into router
createRIfaces()
{
  createResources 1 NETSTATS NONE JHSUBNET NONE "" id $FIPTIMEOUT neutron router-interface-add ${ROUTERS[0]} "\$VAL"
  createResources $NONETS NETSTATS NONE SUBNET NONE "" id $FIPTIMEOUT neutron router-interface-add ${ROUTERS[0]} "\$VAL"
}

# Remove subnet interfaces on router
deleteRIfaces()
{
  if test -z "${ROUTERS[0]}"; then return 0; fi
  echo -en "Delete Router Interfaces ...\n "
  if test -n "$SECONDNET"; then
    deleteResources NETSTATS SECONDSUBNET "" $FIPTIMEOUT neutron router-interface-delete ${ROUTERS[0]}
    echo -n " "
  fi
  deleteResources NETSTATS SUBNET "" $FIPTIMEOUT neutron router-interface-delete ${ROUTERS[0]}
  echo -n " "
  deleteResources NETSTATS JHSUBNET "" $FIPTIMEOUT neutron router-interface-delete ${ROUTERS[0]}
}

# Setup security groups with their rulesets
createSGroups()
{
  local RESP
  local OLDAPIERRS=$APIERRORS
  NAMES=( ${RPRE}SG_JumpHost ${RPRE}SG_Internal )
  createResources 2 NETSTATS SGROUP NAME NONE "" id $NETTIMEOUT neutron security-group-create "\$VAL" || return
  # And set rules ... (we don't need to keep track of and delete them)
  SG0=${SGROUPS[0]}
  SG1=${SGROUPS[1]}
  # Configure SGs: We can NOT allow any references to SG0, as the allowed-address-pair setting renders SGs useless
  #  that reference the SG0
  let APICALLS+=9
  #RESP=$(ostackcmd_id id neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG0 $SG0)
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-ip-prefix $JHSUBNETIP $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv6 --remote-group-id $SG0 $SG0)
  #updAPIerr $?
  #read TM ID <<<"$RESP"
  #NETSTATS+=( $TM )
  # Configure SGs: Internal ingress allowed
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG1 $SG1)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv6 --remote-group-id $SG1 $SG1)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  # Configure RPRE_SG_JumpHost rule: All from the other group, port 22 and 222- from outside
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --remote-group-id $SG1 $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix 0/0 $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 222 --port-range-max $((222+($NOVMS-1)/$NOAZS)) --remote-ip-prefix 0/0 $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix 0/0 $SG0)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  # Configure RPRE_SG_Internal rule: ssh (and https) and ping from the other group
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-group-id $SG0 $SG1)
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 22 --port-range-max 22 --remote-ip-prefix $JHSUBNETIP $SG1)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 443 --port-range-max 443 --remote-group-id $SG0 $SG1)
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 443 --port-range-max 443 --remote-ip-prefix $JHSUBNETIP $SG1)
  #updAPIerr $?
  #read TM ID <<<"$RESP"
  #NETSTATS+=( $TM )
  #RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-group-id $SG0 $SG1)
  RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol icmp --port-range-min 8 --port-range-max 0 --remote-ip-prefix $JHSUBNETIP $SG1)
  updAPIerr $?
  read TM ID <<<"$RESP"
  NETSTATS+=( $TM )
  if test -n "$LOADBALANCER"; then
    RESP=$(ostackcmd_id id $NETTIMEOUT neutron security-group-rule-create --direction ingress --ethertype IPv4 --protocol tcp --port-range-min 80 --port-range-max 80 --remote-ip-prefix $JHSUBNETIP $SG1)
    updAPIerr $?
    read TM ID <<<"$RESP"
    NETSTATS+=( $TM )
  fi  
  #neutron security-group-show $SG0
  #neutron security-group-show $SG1
  test $OLDAPIERRS == $APIERRORS
}

cleanupPorts()
{
  RPORTS=( $(findres ${RPRE}Port_ neutron port-list) )
  deleteResources NETSTATS RPORT "" $NETTIMEOUT neutron port-delete
  #RVIPS=( $(findres ${RPRE}VirtualIP neutron port-list) )
  #deleteResources NETSTATS RVIP "" $NETTIMEOUT neutron port-delete
}


deleteSGroups()
{
  #neutron port-list
  #neutron security-group-list
  deleteResources NETSTATS SGROUP "" $NETTIMEOUT neutron security-group-delete
}

createVIPs()
{
  createResources 1 NETSTATS VIP NONE NONE "" id $NETTIMEOUT neutron port-create --security-group ${SGROUPS[0]} --name ${RPRE}VirtualIP ${JHNETS[0]}
  # FIXME: We should not need --allowed-adress-pairs here ...
}

deleteVIPs()
{
  deleteResources NETSTATS VIP "" $NETTIMEOUT neutron port-delete
}

createJHPorts()
{
  local RESP RC TM ID
  createResources $NOAZS NETSTATS JHPORT NONE NONE "" id $NETTIMEOUT neutron port-create --security-group ${SGROUPS[0]} --name "${RPRE}Port_JH\${no}" ${JHNETS[0]} || return
  for i in `seq 0 $((NOAZS-1))`; do
    let APICALLS+=1
    RESP=$(ostackcmd_id id $NETTIMEOUT neutron port-update ${JHPORTS[$i]} --allowed-address-pairs type=dict list=true ip_address=0.0.0.0/1 ip_address=128.0.0.0/1)
    RC=$?
    updAPIerr $RC
    read TM ID <<<"$RESP"
    NETSTATS+=( $TM )
    if test $RC != 0; then echo -e "${YELLOW}ERROR: Failed setting allowed-adr-pair for port ${JHPORTS[$i]}$NORM" 1>&2; return 1; fi
  done
}

createPorts()
{
  if test -n "$MANUALPORTSETUP"; then
    createResources $NOVMS NETSTATS PORT NONE NONE "" id $NETTIMEOUT neutron port-create --security-group ${SGROUPS[1]} --name "${RPRE}Port_VM\${no}" "\${NETS[\$((\$no%$NONETS))]}"
  fi
}

create2ndPorts()
{
  if test -n "$SECONDNET"; then
    SECONDPORTS=()
    createResources $NOVMS NETSTATS SECONDPORT NONE NONE "" id $NETTIMEOUT neutron port-create --security-group ${SGROUPS[1]} --fixed-ip subnet_id="\${SECONDSUBNETS[\$((\$no%$NONETS))]}" --name "${RPRE}Port2_VM\${no}" "\${SECONDNETS[\$((\$no%$NONETS))]}"
  fi
}

deleteJHPorts()
{
  deleteResources NETSTATS JHPORT "" $NETTIMEOUT neutron port-delete
}

deletePorts()
{
  deleteResources NETSTATS PORT "" $NETTIMEOUT neutron port-delete
}

delete2ndPorts()
{
  if test -n "$SECONDNET"; then
    deleteResources NETSTATS SECONDPORT "" $NETTIMEOUT neutron port-delete
  fi
}

createJHVols()
{
  JVOLSTIME=()
  createResources $NOAZS VOLSTATS JHVOLUME NONE NONE JVOLSTIME id $CINDERTIMEOUT cinder create --image-id $JHIMGID --availability-zone \${VAZS[\$VAZN]} --name ${RPRE}RootVol_JH\$no $JHVOLSIZE
}

# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitJHVols()
{
  #waitResources VOLSTATS JHVOLUME VOLCSTATS JVOLSTIME "available" "NA" "status" cinder show
  waitlistResources VOLSTATS JHVOLUME VOLCSTATS JVOLSTIME "available" "NA" $VOLSTATCOL $CINDERTIMEOUT cinder list
  handleWaitErr VOLSTATS $CINDERTIMEOUT cinder show
}

deleteJHVols()
{
  deleteResources VOLSTATS JHVOLUME "" $CINDERTIMEOUT cinder delete
}

createVols()
{
  if test -n "$BOOTFROMIMAGE"; then return 0; fi
  VOLSTIME=()
  createResources $NOVMS VOLSTATS VOLUME NONE NONE VOLSTIME id $CINDERTIMEOUT cinder create --image-id $IMGID --availability-zone \${VAZS[\$VAZN]} --name ${RPRE}RootVol_VM\$no $VOLSIZE
}

# STATNM RSRCNM CSTAT STIME PROG1 PROG2 FIELD COMMAND
waitVols()
{
  if test -n "$BOOTFROMIMAGE"; then return 0; fi
  #waitResources VOLSTATS VOLUME VOLCSTATS VOLSTIME "available" "NA" "status" cinder show
  waitlistResources VOLSTATS VOLUME VOLCSTATS VOLSTIME "available" "NA" $VOLSTATCOL $CINDERTIMEOUT cinder list
  handleWaitErr VOLSTATS $CINDERTIMEOUT cinder show
}

deleteVols()
{
  if test -n "$BOOTFROMIMAGE"; then return 0; fi
  deleteResources VOLSTATS VOLUME "" $CINDERTIMEOUT cinder delete
}

createKeypairs()
{
  UMASK=$(umask)
  umask 0077
  ostackcmd_tm NOVASTATS $NOVATIMEOUT nova keypair-add ${RPRE}Keypair_JH || return 1
  echo "$OSTACKRESP" > ${RPRE}Keypair_JH.pem
  KEYPAIRS+=( "${RPRE}Keypair_JH" )
  ostackcmd_tm NOVASTATS $NOVATIMEOUT nova keypair-add ${RPRE}Keypair_VM || return 1
  echo "$OSTACKRESP" > ${RPRE}Keypair_VM.pem
  KEYPAIRS+=( "${RPRE}Keypair_VM" )
  umask $UMASK
}

deleteKeypairs()
{
  deleteResources NOVASTATS KEYPAIR "" $NOVATIMEOUT nova keypair-delete
  #rm ${RPRE}Keypair_VM.pem
  #rm ${RPRE}Keypair_JH.pem
}

# Extract IP address from neutron port-show output
extract_ip()
{
  echo "$1" | grep '| fixed_ips ' | sed "$PORTFIXED"
}

# Create Floating IPs, and set route via Virtual IP
SNATROUTE=""
createFIPs()
{
  local FLOAT RESP
  #createResources $NOAZS NETSTATS JHPORT NONE NONE "" id $NETTIMEOUT neutron port-create --security-group ${SGROUPS[0]} --name "${RPRE}Port_JH\${no}" ${JHNETS[0]} || return
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron net-external-list || return 1
  #EXTNET=$(echo "$OSTACKRESP" | grep '^| [0-9a-f-]* |' | sed 's/^| \([0-9a-f-]*\) | \([^ ]*\).*$/\2/')
  EXTNET=$(echo "$OSTACKRESP" | grep '^| [0-9a-f-]* |' | sed 's/^| \([0-9a-f-]*\) | \([^ ]*\).*$/\1/')
  # Not needed on OTC, but for most other OpenStack clouds:
  # Connect Router to external network gateway
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron router-gateway-set ${ROUTERS[0]} $EXTNET
  # Actually this fails if the port is not assigned to a VM yet
  #  -- we can not associate a FIP to a port w/o dev owner
  # So wait for JHPORTS having a device owner
  #echo "Wait for JHPorts: "
  waitResources NETSTATS JHPORT JPORTSTAT JVMSTIME "NONNULL" "NONONO" "device_owner" $NETTIMEOUT neutron port-show
  # Now FIP creation is safe
  createResources $NOAZS FIPSTATS FIP JHPORT NONE "" id $FIPTIMEOUT neutron floatingip-create --port-id \$VAL $EXTNET
  if test $? != 0 -o -n "$INJECTFIPERR"; then return 1; fi
  # Use API to tell VPC that the VIP is the next hop (route table)
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-show ${VIPS[0]} || return 1
  VIP=$(extract_ip "$OSTACKRESP")
  # Find out whether the router does SNAT ...
  RESP=$(ostackcmd_id external_gateway_info $NETTIMEOUT neutron router-show ${ROUTERS[0]})
  updAPIerr $?
  read TM EXTGW <<<"$RESP"
  NETSTATS+=( $TM )
  SNAT=$(echo $EXTGW | sed 's/^[^,]*, "enable_snat": \([^ }]*\).*$/\1/')
  if test "$SNAT" = "false"; then
    ostackcmd_tm NETSTATS $NETTIMEOUT neutron router-update ${ROUTERS[0]} --routes type=dict list=true destination=0.0.0.0/0,nexthop=$VIP
  else
    echo "SNAT enabled already, no need to use SNAT instance via VIP"
  fi
  if test $? != 0; then
    echo -e "$BOLD We lack the ability to set VPC route via SNAT gateways by API, will be fixed soon"
    echo -e " Please set next hop $VIP to VPC ${RPRE}Router (${ROUTERS[0]}) routes $NORM"
    SNATROUTE=""
  else
    #SNATROUTE=$(echo "$OSTACKRESP" | grep "^| *id *|" | sed -e "s/^| *id *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
    echo "SNATROUTE: destination=0.0.0.0/0,nexthop=$VIP"
    SNATROUTE=1
  fi
  FLOAT=""
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron floatingip-list || return 1
  for PORT in ${FIPS[*]}; do
    FLOAT+=" $(echo "$OSTACKRESP" | grep $PORT | sed "$FLOATEXTR")"
  done
  echo "Floating IPs: $FLOAT"
  FLOATS=( $FLOAT )
}

# Delete VIP nexthop and EIPs
deleteFIPs()
{
  if test -n "$SNATROUTE" -a -n "${ROUTERS[0]}"; then
    ostackcmd_tm NETSTATS $NETTIMEOUT neutron router-update ${ROUTERS[0]} --no-routes
    if test $? != 0; then
      echo -e "${YELLOW}ERROR: router --no-routes failed, retry ...${NORM}" 1>&2
      sleep 2
      ostackcmd_tm NETSTATS $(($NETTIMEOUT+8)) neutron router-update ${ROUTERS[0]} --no-routes
    fi
  fi
  OLDFIPS=(${FIPS[*]})
  if test -n "$DISASSOC"; then
    # osTicket #361989: We suddenly need to disassociate before we can delete. Bug?
    deleteResources FIPSTATS FIP "" $FIPTIMEOUT neutron floatingip-disassociate
  fi
  deleteResources FIPSTATS FIP "" $FIPTIMEOUT neutron floatingip-delete
  # Extra treatment: Try again to avoid leftover FIPs
  # sleep 1
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron floatingip-list || return 0
  local FIPSLEFT=""
  for FIP in ${OLDFIPS[*]}; do
    if echo "$OSTACKRESP" | grep "^| $FIP" >/dev/null 2>&1; then FIPSLEFT="$FIPSLEFT$FIP "; fi
  done
  if test -n "$FIPSLEFT"; then
    sendalarm 1 "Cleanup Floating IPs $FIPSLEFT again"
    #echo -e "${RED}Delete FIP again: $FIP${NORM}" 1>&2
    ostackcmd_tm NETSTATS $FIPTIMEOUT neutron floatingip-delete $FIPSLEFT
  fi
}

# Create a list of port forwarding rules (redirection/fwdmasq)
declare -a REDIRS
calcRedirs()
{
  local port ptn pi IP STR off
  REDIRS=()
  #echo "#DEBUG: cR Ports ${PORTS[*]}"
  # This is the mapping:
  # 222,JH0 -> VM0; 222,JH1 -> VM1, 222,JHa -> VMa, 223,JH0 -> VM(a+1) ...
  # Note: We need (a) a reproducible VM sorting order for CONNTEST with
  #  secondary port reshuffling and (b) PORTS needs to match VMS ordering
  # This is why we use orderVMs
  # Optimization: Do neutron port-list once and parse multiple times ...
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-list -c id -c device_id -c fixed_ips -f json
  if test ${#PORTS[*]} -gt 0; then
    declare -i ptn=222
    declare -i pi=0
    for port in ${PORTS[*]}; do
      #ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-show $port
      #echo -n "##DEBUG: $port: "
      #IP=$(extract_ip "$OSTACKRESP")
      if test -z "$OPENSTACKCLIENT"; then
        IP=$(echo "$OSTACKRESP" | jq -r ".[] | select(.id == \"$port\") | .fixed_ips[].ip_address" | tr -d '"')
      else
        IP=$(echo "$OSTACKRESP" | jq -r ".[] | select(.ID == \"$port\") | .[\"Fixed IP Addresses\"]")
	if echo "$IP" | grep ip_address >/dev/null 2>&1; then IP=$(echo "$IP" | jq '.[].ip_address'); fi
	IP=$(echo -e "$IP" | tr -d '"' | sed "$PORTFIXED2")
      fi
      STR="0/0,$IP,tcp,$ptn,22"
      off=$(($pi%$NOAZS))
      #echo "Port $port: $STR => REDIRS[$off]"
      REDIRS[$off]="${REDIRS[$off]}$STR
"
      if test $(($off+1)) == $NOAZS; then let ptn+=1; fi
      let pi+=1
    done
    #for off in $(seq 0 $(($NOAZS-1))); do
    #  echo " REDIR $off: ${REDIRS[$off]}"
    #done
  fi
}

# JumpHosts creation with SNAT and port forwarding
createJHVMs()
{
  local IP STR odd ptn RD USERDATA JHNUM port
  REDIRS=()
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-show ${VIPS[0]} || return 1
  VIP=$(extract_ip "$OSTACKRESP")
  calcRedirs
  #echo "#DEBUG: $VIP ${REDIRS[*]}"
  for JHNUM in $(seq 0 $(($NOAZS-1))); do
    if test -z "${REDIRS[$JHNUM]}"; then
      # No fwdmasq config possible yet
      USERDATA="#cloud-config
otc:
   internalnet:
      - 10.250/16
   snat:
      masqnet:
         - INTERNALNET
   addip:
      eth0: $VIP
"
    else
      RD=$(echo -n "${REDIRS[$JHNUM]}" |  sed 's@^0@         - 0@')
      USERDATA="#cloud-config
otc:
   internalnet:
      - 10.250/16
   snat:
      masqnet:
         - INTERNALNET
      fwdmasq:
$RD
   addip:
      eth0: $VIP
"
    fi
    echo "$USERDATA" > ${RPRE}user_data_JH.yaml
    cat ${RPRE}user_data_JH.yaml >> $LOGFILE
    createResources 1 NOVABSTATS JHVM JHPORT JHVOLUME JVMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $JHFLAVOR --boot-volume ${JHVOLUMES[$JHNUM]} --key-name ${KEYPAIRS[0]} --user-data ${RPRE}user_data_JH.yaml --availability-zone ${AZS[$(($JHNUM%$NOAZS))]} --security-groups ${SGROUPS[0]} --nic port-id=${JHPORTS[$JHNUM]} ${RPRE}VM_JH$JHNUM || return
  done
}

# Fill PORTS array by matching part's device_ids with the VM UUIDs
collectPorts()
{
  local vm vmid
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-list -c id -c device_id -c fixed_ips -f json
  #echo -e "#DEBUG: cP VMs ${VMS[*]}\n\'$OSTACKRESP\'"
  #echo "#DEBUG: cP VMs ${VMS[*]}"
  if test -n "$SECONDNET" -a -z "$SECONDPORTS"; then COLLSECOND=1; else unset COLLSECOND; fi
  for vm in $(seq 0 $(($NOVMS-1))); do
    vmid=${VMS[$vm]}
    if test -z "$vmid"; then sendalarm 1 "nova list" "VM $vm not found" $NOVATIMEOUT; continue; fi
    #port=$(echo "$OSTACKRESP" | jq -r '.[]' | grep -C4 "$vmid")
    #echo -e "#DEBUG: $port"
    if test -z "$OPENSTACKCLIENT"; then
      ports=$(echo "$OSTACKRESP" | jq -r ".[] | select(.device_id == \"$vmid\") | .id+\" \"+.fixed_ips[].ip_address" | tr -d '"')
    else
      ports=$(echo "$OSTACKRESP" | jq -r "def str(s): s|tostring; .[] | select(.device_id == \"$vmid\") | .ID+\" \"+str(.[\"Fixed IP Addresses\"])" | tr -d '"')
      #if echo "$ports" | grep ip_address >/dev/null 2>&1; then ports=$(echo "$ports" | jq '.[].ip_address'); fi
      ports=$(echo -e "$ports" | tr -d '"' | sed "$PORTFIXED2")
    fi
    port=$(echo -e "$ports" | grep 10.250 | sed 's/^\([^ ]*\) .*$/\1/')
    PORTS[$vm]=$port
    if test -n "$COLLSECOND"; then
      port2=$(echo -e "$ports" | grep 10.251 | sed 's/^\([^ ]*\) .*$/\1/')
      SECONDPORTS[$vm]=$port2
    fi
  done
  echo "VM Ports: ${PORTS[*]}"
  if test -n "$SECONDPORTS"; then echo "VM Ports2: ${SECONDPORTS[*]}"; fi

}

# When NOT creating ports before JHVM starts, we cannot pass the port fwd information
# via user-data as we don't know the IP addresses. So modify VM via ssh.
setPortForward()
{
  if test -n "$MANUALPORTSETUP"; then return; fi
  local JHNUM FWDMASQ SHEBANG SCRIPT
  # If we need to collect port info, do so now
  if test -z "${PORTS[*]}"; then collectPorts; fi
  calcRedirs
  #echo "#DEBUG: sPF VIP REDIR $VIP ${REDIRS[*]}"
  for JHNUM in $(seq 0 $(($NOAZS-1))); do
    if test -z "${REDIRS[$JHNUM]}"; then
      echo -e "${YELLOW}ERROR: No redirections?$NORM" 1>&2
      return 1
    fi
    FWDMASQ=$( echo ${REDIRS[$JHNUM]} )
    ssh-keygen -R ${FLOATS[$JHNUM]} -f ~/.ssh/known_hosts.$RPRE >/dev/null 2>&1
    SHEBANG='#!'
    SCRIPT=$(echo "$SHEBANG/bin/bash
sed -i 's@^FW_FORWARD_MASQ=.*\$@FW_FORWARD_MASQ=\"$FWDMASQ\"@' /etc/sysconfig/SuSEfirewall2
systemctl restart SuSEfirewall2
")
    echo "$SCRIPT" | ssh -i ${KEYPAIRS[0]}.pem -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${JHDEFLTUSER}@${FLOATS[$JHNUM]} "cat - >upd_sfw2"
    ssh -i ${KEYPAIRS[0]}.pem -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${JHDEFLTUSER}@${FLOATS[$JHNUM]} sudo "/bin/bash ./upd_sfw2"
  done
}

# Configure port forwarding etc. on non-SUSE VMs using plain iptables commands
setPortForwardGen()
{
  #if test -n "$MANUALPORTSETUP"; then return; fi
  local JHNUM FWDMASQ SHEBANG SCRIPT
  # If we need to collect port info, do so now
  if test -z "${PORTS[*]}"; then collectPorts; fi
  calcRedirs
  #echo "#DEBUG: sPF VIP REDIR $VIP ${REDIRS[*]}"
  for JHNUM in $(seq 0 $(($NOAZS-1))); do
    if test -z "${REDIRS[$JHNUM]}"; then
      echo -e "${YELLOW}ERROR: No redirections?$NORM" 1>&2
      return 1
    fi
    FWDMASQ=$( echo ${REDIRS[$JHNUM]} )
    ssh-keygen -R ${FLOATS[$JHNUM]} -f ~/.ssh/known_hosts.$RPRE >/dev/null 2>&1
    SHEBANG='#!'
    SCRIPT=$(echo "$SHEBANG/bin/bash
# SUSE image specific
if test -f /etc/sysconfig/scripts/SuSEfirewall2-snathelper; then
  sed -i 's@^FW_FORWARD_MASQ=.*\$@FW_FORWARD_MASQ=\"$FWDMASQ\"@' /etc/sysconfig/SuSEfirewall2
  systemctl restart SuSEfirewall2
else
  # Determine default NIC
  DEV=\$(ip route show | grep ^default | head -n1 | sed 's@default via [^ ]* dev \([^ ]*\) .*@\1@g')
  # Add VIP
  ip addr add $VIP/32 dev \$DEV
  # Outbound Masquerading
  iptables -t nat -A POSTROUTING -o \$DEV -s 10.250/16 -j MASQUERADE
  iptables -P FORWARD DROP
  iptables -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  iptables -I FORWARD 2 -i \$DEV -o \$DEV -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -I FORWARD 3 -i \$DEV -o \$DEV -s 10.250/16 -j ACCEPT
  # Set ip_forward
  echo 1 > /proc/sys/net/ipv4/ip_forward
  # Inbound Masquerading
  iptables -I FORWARD 4 -i \$DEV -o \$DEV -d 10.250/16 -p tcp --dport 22 -j ACCEPT
  iptables -t nat -A POSTROUTING -o \$DEV -d 10.250/16 -p tcp --dport 22 -j MASQUERADE")
# "0/0,10.250.0.24,tcp,222,22 0/0,10.250.4.16,tcp,223,22 0/0,10.250.0.9,tcp,224,22 0/0,10.250.4.10,tcp,225,22 0/0,10.250.0.7,tcp,226,22 0/0,10.250.4.5,tcp,227,22 0/0,10.250.0.4,tcp,228,22 0/0,10.250.4.4,tcp,229,22"
    for FMQ in $FWDMASQ; do
      OLDIFS="$IFS"; IFS=","
      read saddr daddr proto port dport < <(echo "$FMQ")
      IFS="$OLDIFS"
      SCRIPT=$(echo -e "$SCRIPT\n  iptables -t nat -A PREROUTING -s $saddr -i \$DEV -j DNAT -p $proto --dport $port --to-destination $daddr:$dport")
    done
    SCRIPT=$(echo -e "$SCRIPT\nfi")
    echo "$SCRIPT" | ssh -i ${KEYPAIRS[0]}.pem -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${JHDEFLTUSER}@${FLOATS[$JHNUM]} "cat - >upd_ipt"
    # -tt is a workaround for a RHEL/CentOS 7 bug
    ssh -tt -i ${KEYPAIRS[0]}.pem -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${JHDEFLTUSER}@${FLOATS[$JHNUM]} sudo "/bin/bash ./upd_ipt"
  done
}


# Loadbalancers
createLBs()
{
  if test -n "$LOADBALANCER"; then
    createResources 1 NETSTATS LBAAS JHNET NONE LBSTIME id $NETTIMEOUT neutron lbaas-loadbalancer-create --vip-network-id ${JHNETS[0]} --name "${RPRE}LB_0"
  fi
}

deleteLBs()
{
  if test -n "$LBAASS"; then
    deleteResources NETSTATS LBAAS "" $NETTIMEOUT neutron lbaas-loadbalancer-delete
  fi
}

waitLBs()
{
  #echo "Wait for LBs ${LBAASS[*]} ..."
  #waitResources NETSTATS LBAAS LBCSTATS LBSTIME "ACTIVE" "NA" "provisioning_status" neutron lbaas-loadbalancer-show
  waitlistResources NETSTATS LBAAS LBCSTATS LBSTIME "ACTIVE" "NONONO" 4 $NETTIMEOUT neutron lbaas-loadbalancer-list
  handleWaitErr NETSTATS $NETTIMEOUT neutron lbaas-loadbalancer-show
}

testLBs()
{
  local ERR=0
  createResources 1 NETSTATS POOL LBAAS NONE "" id $NETTIMEOUT neutron lbaas-pool-create --name "${RPRE}Pool_0" --protocol HTTP --lb-algorithm=ROUND_ROBIN --session-persistence type=HTTP_COOKIE --loadbalancer ${LBAASS[0]} # --wait
  let ERR+=$?
  createResources 1 NETSTATS LISTENER POOL LBAAS "" id $NETTIMEOUT neutron lbaas-listener-create --name "${RPRE}Listener_0" --default-pool ${POOLS[0]} --protocol HTTP --protocol-port 80 --loadbalancer ${LBAASS[0]}
  let ERR+=$?
  createResources $NOVMS NETSTATS MEMBER IP POOL "" id $NETTIMEOUT neutron lbaas-member-create --name "${RPRE}Member_\$no" --address \${IPS[\$no]} --protocol-port 80 ${POOLS[0]}
  let ERR+=$?
  # TODO: Implement health monitors?
  # Assign a FIP to the LB
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron lbaas-loadbalancer-show ${LBAASS[0]} -f value -c vip_port_id
  let ERR+=$?
  LBPORT=$OSTACKRESP
  createResources 1 NETSTATS LBFIP NONE NONE "" id $NETTIMEOUT neutron floating-ip-create --port $LBPORT $EXTNET
  let ERR+=$?
  LBIP=$(echo "$RESP" | grep ' floating_ip_address ' | sed 's/^|[^|]*| *\([a-f0-9:\.]*\).*$/\1/')
  echo -n "Test LB at $LBIP:"
  # Access LB several times
  for i in $(seq 0 $NOVMS); do
    ANS=$(curl -m4 http://$LBIP/hostname 2>/dev/null)
    RC=$?
    echo -n " $ANS"
    if test $RC != 0; then
      sendalarm 2 "No response from LB $LBIP port 80" "$RC" 4
      if test -n "$EXITERR"; then exit 3; fi
      let LBERRORS+=$RC
      let ERR+=1
      errwait $ERRWAIT
    fi
  done
  return $ERR
}

cleanLBs()
{
  deleteResources NETSTATS MEMBER "" $NETTIMEOUT neutron lbaas-member-delete ${POOLS[0]}
  deleteResources NETSTATS LISTENER "" $NETTIMEOUT neutron lbaas-listener-delete
  deleteResources NETSTATS POOL "" $NETTIMEOUT neutron lbaas-pool-delete
  deleteResources NETSTATS LBFIP "" $NETTIMEOUT neutron floating-ip-delete
}

waitJHVMs()
{
  #waitResources NOVASTATS JHVM VMCSTATS JVMSTIME "ACTIVE" "NA" "status" nova show
  waitlistResources NOVASTATS JHVM VMCSTATS JVMSTIME "ACTIVE" "NONONO" 2 $NOVATIMEOUT nova list
  handleWaitErr NOVASTATS $NOVATIMEOUT nova show
}

deleteJHVMs()
{
  # The platform can take a long long time to delete a VM in build state, so better wait a bit
  # to see whether it becomes active, so deletion has a better chance to suceed in finite time.
  # Note: We wait ~100s (30x4s) and don't disturb VMCSTATS by this, empty CSTATS is handled
  #  as special case in waitlistResources
  # Note: We meanwhile abort for broken JHs, so this is no longer needed.
  #waitlistResources NOVASTATS JHVM "" JVMSTIME "ACTIVE" "ERROR" 2 $NOVATIMEOUT nova list
  JVMSTIME=()
  deleteResources NOVABSTATS JHVM JVMSTIME $NOVATIMEOUT nova delete
}

waitdelJHVMs()
{
  #waitdelResources NOVASTATS JHVM VMDSTATS JVMSTIME nova show
  waitlistResources NOVASTATS JHVM VMDSTATS JVMSTIME "XDELX" "$FORCEDEL" 2 $NOVATIMEOUT nova list
}

# Bring VMs in $OSTACKRESP (from nova list/openstack server list) into order
# NET0-1 => 0, NET1-1 => 1, Nn-1 => n, NET0-2 => n+1, ...
orderVMs()
{
  VMS=()
  for netno in $(seq 0 $(($NONETS-1))); do
    declare -i off=$netno
    OLDIFS="$IFS"; IFS="|"
    #nova list | grep " ${RPRE}VM_VM_NET$netno"
    while read sep vmid sep name sep; do
      #echo -n " VM$off=$vmid"
      IFS=" " VMS[$off]=$(echo $vmid)
      IFS=" " VMSTIME[$off]=${STMS[$netno]}
      #echo "DEBUG: VMS[$off]=$name $vmid (net $netno)"
      let off+=$NONETS
    done  < <(echo "$OSTACKRESP" | grep " ${RPRE}VM_VM_NET$netno")
    IFS="$OLDIFS"
    #echo
  done
}

# Create many VMs with one API call (option -D)
createVMsAll()
{
  local netno AZ THISNOVM vmid off STMS
  local ERRS=0
  local UDTMP=./${RPRE}user_data_VM.yaml
  echo -e "#cloud-config\nwrite_files:\n - content: |\n      # TEST FILE CONTENTS\n      api_monitor.sh.${RPRE}ALL\n   path: /tmp/testfile\n   permissions: '0644'" > $UDTMP
  if test -n "$LOADBALANCER"; then
    # FIXME: This is distro dependent, implement at least also for CentOS & Ubuntu
    echo -e "packages:\n  - thttpd\nruncmd:\n  - hostname > /srv/www/htdocs/hostname\n  - systemctl start thttpd\n  - sed -i 's/FW_SERVICES_EXT_TCP=""/FW_SERVICES_EXT_TCP="http"/' /etc/sysconfig/SuSEfirewall2\n  - systemctl restart SuSEfirewall2" >> $UDTMP
  fi
  declare -a STMS
  echo -n "Create VMs in batches: "
  # Can not pass port IDs during boot in batch creation
  if test -n "$SECONDNET" -a -z "$DELAYEDATTACH"; then DELAYEDATTACH=1; fi 
  for netno in $(seq 0 $(($NONETS-1))); do
    AZ=${AZS[$(($netno%$NOAZS))]}
    THISNOVM=$((($NOVMS+$NONETS-$netno-1)/$NONETS))
    STMS[$netno]=$(date +%s)
    ostackcmd_tm NOVABSTATS $(($NOVABOOTTIMEOUT+$THISNOVM*$DEFTIMEOUT/2)) nova boot --flavor $FLAVOR --image $IMGID --key-name ${KEYPAIRS[1]} --availability-zone $AZ --security-groups ${SGROUPS[1]} --nic net-id=${NETS[$netno]} --user-data $UDTMP ${RPRE}VM_VM_NET$netno --min-count=$THISNOVM --max-count=$THISNOVM
    let ERRS+=$?
    # TODO: More error handling here?
  done
  sleep 1
  # Collect VMIDs
  ostackcmd_tm NOVASTATS $NOVATIMEOUT nova list --sort display_name:asc
  orderVMs
  echo "${VMS[*]}"
  #collectPorts
  return $ERRS
}

# Classic creation of all VMs, one by one
createVMs()
{
  if test -n "$BOOTALLATONCE"; then createVMsAll; return; fi
  local UDTMP=./${RPRE}user_data_VM.yaml
  for no in $(seq 0 $NOVMS); do
    echo -e "#cloud-config\nwrite_files:\n - content: |\n      # TEST FILE CONTENTS\n      api_monitor.sh.${RPRE}$no\n   path: /tmp/testfile\n   permissions: '0644'" > $UDTMP.$no
  done
  if test -n "$BOOTFROMIMAGE"; then
    if test -n "$MANUALPORTSETUP"; then
      createResources $NOVMS NOVABSTATS VM PORT VOLUME VMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $FLAVOR --image $IMGID --key-name ${KEYPAIRS[1]} --availability-zone \${AZS[\$AZN]} --nic port-id=\$VAL --user-data $UDTMP.\$no ${RPRE}VM_VM\$no
    else
      # SAVE: createResources $NOVMS NETSTATS PORT NONE NONE "" id neutron port-create --name "${RPRE}Port_VM\${no}" --security-group ${SGROUPS[1]} "\${NETS[\$((\$no%$NONETS))]}"
      createResources $NOVMS NOVABSTATS VM NET VOLUME VMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $FLAVOR --image $IMGID --key-name ${KEYPAIRS[1]} --availability-zone \${AZS[\$AZN]} --security-groups ${SGROUPS[1]} --nic "net-id=\${NETS[\$((\$no%$NONETS))]}" --user-data $UDTMP.\$no ${RPRE}VM_VM\$no
    fi
  else
    if test -n "$MANUALPORTSETUP"; then
      createResources $NOVMS NOVABSTATS VM PORT VOLUME VMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $FLAVOR --boot-volume \$MVAL --key-name ${KEYPAIRS[1]} --availability-zone \${AZS[\$AZN]} --nic port-id=\$VAL --user-data $UDTMP.\$no ${RPRE}VM_VM\$no
    else
      # SAVE: createResources $NOVMS NETSTATS PORT NONE NONE "" id neutron port-create --name "${RPRE}Port_VM\${no}" --security-group ${SGROUPS[1]} "\${NETS[\$((\$no%$NONETS))]}"
      createResources $NOVMS NOVABSTATS VM NET VOLUME VMSTIME id $NOVABOOTTIMEOUT nova boot --flavor $FLAVOR --boot-volume \$MVAL --key-name ${KEYPAIRS[1]} --availability-zone \${AZS[\$AZN]} --security-groups ${SGROUPS[1]} --nic "net-id=\${NETS[\$((\$no%$NONETS))]}" --user-data $UDTMP.\$no ${RPRE}VM_VM\$no
    fi
  fi
  local RC=$?
  rm $UDTMP.*
  return $RC
}

# Wait for VMs to get into active state
waitVMs()
{
  #waitResources NOVASTATS VM VMCSTATS VMSTIME "ACTIVE" "NA" "status" nova show
  waitlistResources NOVASTATS VM VMCSTATS VMSTIME "ACTIVE" "NONONO" 2 $NOVATIMEOUT nova list
  handleWaitErr NOVASTATS $NOVATIMEOUT nova show
}

# Remove VMs (one by one or by batch if we created in batches)
deleteVMs()
{
  VMSTIME=()
  if test -z "${VMS[*]}"; then return; fi
  if test -n "$BOOTALLATONCE"; then
    local DT vm
    echo "Del VM in batch: ${VMS[*]}"
    DT=$(date +%s)
    ostackcmd_tm NOVABSTATS $(($NOVMS*$DEFTIMEOUT/2+$NOVABOOTTIMEOUT)) nova delete ${VMS[*]}
    if test $? != 0; then
      echo -e "${YELLOW}ERROR: VM delete call returned error. Retrying ...$NORM" 1>&2
      sleep 2
      ostackcmd_tm NOVABSTATS $(($NOVMS*$DEFTIMEOUT/2+$NOVABOOTTIMEOUT)) nova delete ${VMS[*]}
    fi
    for vm in $(seq 0 $((${#VMS[*]}-1))); do VMSTIME[$vm]=$DT; done
  else
    deleteResources NOVABSTATS VM VMSTIME $NOVABOOTTIMEOUT nova delete
  fi
}

# Wait for VMs to disappear
waitdelVMs()
{
  #waitdelResources NOVASTATS VM VMDSTATS VMSTIME nova show
  waitlistResources NOVASTATS VM VMDSTATS VMSTIME XDELX $FORCEDEL 2 $NOVATIMEOUT nova list
}

# Meta data setting for test purposes
setmetaVMs()
{
  if test -n "$BOOTALLATONCE"; then CFTEST=cfbatch; else CFTEST=cftest; fi
  echo -n "Set VM Metadata: "
  for no in `seq 0 $(($NOVMS-1))`; do
    echo -n "${VMS[$no]} "
    ostackcmd_tm NOVASTATS $NOVATIMEOUT nova meta ${VMS[$no]} set deployment=$CFTEST server=$no || return 1
  done
  echo
}

# Attach (if needed) and configure 2ndary NICs
config2ndNIC()
{
  if test -z "$SECONDNET"; then return 0; fi
  # Attach
  echo -n "Attaching 2ndary Ports to VMs ... "
  for no in `seq 0 $(($NOVMS-1))`; do
    ostackcmd_tm NOVASTATS $NOVATIMEOUT nova interface-attach --port-id ${SECONDPORTS[$no]} ${VMS[$no]}
    echo -n "."
  done
  # Configure VMs
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    #echo -n "${FLOATS[$JHNO]} "
    st=$JHNO
    for red in ${REDIRS[$JHNO]}; do
      pno=${red#*tcp,}
      pno=${pno%%,*}
      #echo -n " $pno "
      ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-show ${SECONDPORTS[$st]}
      if test -n "$OPENSTACKCLIENT"; then
        IP=$(echo "$OSTACKRESP" | grep 'fixed_ips' | sed "s@^.*ip_address=$SQ\([^$SQ]*\)$SQ.*\$@\1@")
      else
        IP=$(echo "$OSTACKRESP" | grep 'fixed_ips' | sed 's@^.*"ip_address": "\([^"]*\)".*$@\1@')
      fi
      # Using rttbl2 (cloud-multiroute), calculating GW here is unneeded. We assume eth1 is the second vNIC here
      GW=${IP%.*}; LAST=${GW##*.}; GW=${GW%.*}.$((LAST-LAST%4)).1
      # There probably is an easier way to handle a secondary interface that needs a gateway ...
      echo "ssh -o \"PasswordAuthentication=no\" -o \"ConnectTimeout=6\" -o \"UserKnownHostsFile=~/.ssh/known_hosts.$RPRE\" -p $pno -i ${KEYPAIRS[1]}.pem $DEFLTUSER@${FLOATS[$JHNO]} \"ADR=\$(ip addr show eth1 | grep ' inet ' | grep -v \$IP/22 | sed 's@^.* inet \([0-9\./]*\).*$@\1@'); test -n \"\$ADR\" && sudo ip addr del $ADR dev eth1; sudo ip addr add $IP/22 dev eth1 2>/dev/null; sudo ip rule del pref 32674 2>/dev/null; sudo ip rule del pref 32765 2>/dev/null; sudo ip route flush table eth1tbl 2>/dev/null; sudo /usr/sbin/rttbl2.sh -g >/dev/null" >> $LOGFILE
      ssh -o "PasswordAuthentication=no" -o "ConnectTimeout=6" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" -p $pno -i ${KEYPAIRS[1]}.pem $DEFLTUSER@${FLOATS[$JHNO]} "ADR=$(ip addr show eth1 2>/dev/null | grep ' inet ' | grep -v $IP\/22 | sed 's@^.* inet \([0-9\./]*\).*$@\1@'); test -n \"$ADR\" && sudo ip addr del $ADR dev eth1; sudo ip addr add $IP/22 dev eth1 2>/dev/null; sudo ip rule del pref 32674 2>/dev/null; sudo ip rule del pref 32765 2>/dev/null; sudo ip route flush table eth1tbl 2>/dev/null; sudo /usr/sbin/rttbl2.sh -g >/dev/null"
      # ip route add default via $GW"
      RC=$?
      echo -n "+"
      let st+=$NOAZS
    done
  done
  echo " done"
}


# Reorder 2nd ports, detach and reattach in new order
reShuffle()
{
  # Attach
  echo -n "Detaching 2ndary ports ... "
  for no in `seq 0 $(($NOVMS-1))`; do
    ostackcmd_tm NOVASTATS $NOVATIMEOUT nova interface-detach ${VMS[$no]} ${SECONDPORTS[$no]}
    echo -n "."
  done
  echo " done. Now reshuffle ..."
  if test -n "$SECONDRECREATE"; then
    IGNORE_ERRORS=1
    delete2ndPorts
    unset IGNORE_ERRORS
    create2ndPorts
  fi
  declare -i i=0
  NEWORDER=$(for p in ${SECONDPORTS[@]}; do echo $p; done | shuf)
  while read p; do
    SECONDPORTS[$i]=$p
    let i+=1
  done < <(echo "$NEWORDER")
  echo "VM Ports2: ${SECONDPORTS[@]}"
  config2ndNIC
}

# Wait for VMs being accessible behind fwdmasq (ports 222+)
wait222()
{
  local NCPROXY pno ctr JHNO waiterr perr red ST TIM
  declare -i waiterr=0
  ST=$(date +%s)
  #if test -n "$http_proxy"; then NCPROXY="-X connect -x $http_proxy"; fi
  MAXWAIT=90
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    echo -n "${FLOATS[$JHNO]} "
    echo -n "ping "
    declare -i ctr=0
    perr=0
    # First test JH
    if test -n "$LOGFILE"; then echo "ping -c1 -w2 ${FLOATS[$JHNO]}" >> $LOGFILE; fi
    while test $ctr -le $MAXWAIT; do
      ping -c1 -w2 ${FLOATS[$JHNO]} >/dev/null 2>&1 && break
      sleep 2
      echo -n "."
      let ctr+=1
    done
    if test $ctr -ge $MAXWAIT; then echo -e "${RED}JumpHost$JHNO (${FLOATS[$JHNO]}) not pingable${NORM}"; let waiterr+=1; perr=1; fi
    # Now ssh
    echo -n " ssh "
    declare -i ctr=0
    if test -n "$LOGFILE"; then echo "nc $NCPROXY -w 2 ${FLOATS[$JHNO]} 22" >> $LOGFILE; fi
    while [ $ctr -le $MAXWAIT ]; do
      echo "quit" | nc $NCPROXY -w 2 ${FLOATS[$JHNO]} 22 >/dev/null 2>&1 && break
      echo -n "."
      sleep 2
      let ctr+=1
    done
    if [ $ctr -ge $MAXWAIT ]; then
      echo -ne " $RED timeout $NORM"
      let waiterr+=1
      let perr+=1
    fi
    if test -n "$GRAFANA"; then
      TIM=$(($(date +%s)-$ST))
      curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=ssh,method=JHVM$JHNO duration=$TIM,return_code=$perr $(date +%s%N)" >> grafana.log
    fi
    if [ $ctr -ge $MAXWAIT ]; then
      # It does not make sense to wait for machines behind JH if JH is not reachable
      local skip=$(echo ${REDIRS[$JHNO]} | wc -w)
      sleep $skip
      let waiterr+=$skip
      continue
    fi
    # Now test VMs behind JH
    for red in ${REDIRS[$JHNO]}; do
      local verr=0
      pno=${red#*tcp,}
      pno=${pno%%,*}
      declare -i ctr=0
      echo -n " $pno "
      if test -n "$LOGFILE"; then echo "nc $NCPROXY -w 2 ${FLOATS[$JHNO]} $pno" >> $LOGFILE; fi
      while [ $ctr -le $MAXWAIT ]; do
        echo "quit" | nc $NCPROXY -w 2 ${FLOATS[$JHNO]} $pno >/dev/null 2>&1 && break
        echo -n "."
        sleep 2
        let ctr+=1
      done
      if [ $ctr -ge $MAXWAIT ]; then echo -ne " $RED timeout $NORM"; let waiterr+=1; verr=1; fi
      MAXWAIT=42
      if test -n "$GRAFANA"; then
        TIM=$(($(date +%s)-$ST))
        curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=ssh,method=VM$JHNO:$pno duration=$TIM,return_code=$verr $(date +%s%N)" >> grafana.log
      fi
    done
    MAXWAIT=60
  done
  if test $waiterr == 0; then echo "OK ($(($(date +%s)-$ST))s)"; else echo "RET $waiterr ($(($(date +%s)-$ST))s)"; fi
  return $waiterr
}

# Test ssh and test for user_data (or just plain ls) and internet ping (via SNAT instance)
# $1 => Keypair
# $2 => IP
# $3 => Port
# $4 => NUMBER
# RC: 2 => ls or user_data injection failed
#     1 => ping failed
testlsandping()
{
  unset SSH_AUTH_SOCK
  if test -z "$3" -o "$3" = "22"; then
    MAXWAIT=36
    unset pport
    ssh-keygen -R $2 -f ~/.ssh/known_hosts.$RPRE >/dev/null 2>&1
    USER="$JHDEFLTUSER"
  else
    MAXWAIT=26
    pport="-p $3"
    ssh-keygen -R [$2]:$3 -f ~/.ssh/known_hosts.$RPRE >/dev/null 2>&1
    USER="$DEFLTUSER"
  fi
  if test -z "$pport"; then
    if test -n "$LOGFILE"; then
      echo "ssh -i $1.pem $pport -o \"PasswordAuthentication=no\" -o \"StrictHostKeyChecking=no\" -o \"ConnectTimeout=10\" -o \"UserKnownHostsFile=~/.ssh/known_hosts.$RPRE\" ${USER}@$2 ls" >> $LOGFILE
    fi
    # no user_data on JumpHosts
    ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=12" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 ls >/dev/null 2>&1 || { echo -n ".."; sleep 4;
    ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=20" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 ls >/dev/null 2>&1; } || return 2
  else
    if test -n "$LOGFILE"; then
      echo "ssh -i $1.pem $pport -o \"PasswordAuthentication=no\" -o \"StrictHostKeyChecking=no\" -o \"ConnectTimeout=8\" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 grep api_monitor.sh.${RPRE}[$4]" >> $LOGFILE
    fi
    # Test whether user_data file injection worked
    if test -n "$BOOTALLATONCE"; then
      # no indiv user data per VM when mass booting ...
      ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=8"  -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 grep api_monitor.sh.${RPRE} /tmp/testfile >/dev/null 2>&1 || { echo -n "o"; sleep 2;
      ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=16" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 grep api_monitor.sh.${RPRE} /tmp/testfile >/dev/null 2>&1; } || return 2
    else
      ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=8"  -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 grep api_monitor.sh.${RPRE}$4 /tmp/testfile >/dev/null 2>&1 || { echo -n "O"; sleep 2;
      ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=16" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 grep api_monitor.sh.${RPRE}$4 /tmp/testfile >/dev/null 2>&1; } || return 2
    fi
  fi
  #
  if test -n "$LOGFILE"; then
    echo "ssh -i $1.pem $pport -o \"PasswordAuthentication=no\" -o \"ConnectTimeout=8\" -o \"UserKnownHostsFile=~/.ssh/known_hosts.$RPRE\" ${USER}@$2 ping -c1 $PINGTARGET" >> $LOGFILE
  fi
  #nslookup $PINGTARGET >/dev/null 2>&1
  PING=$(ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "ConnectTimeout=8" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 ping -c1 $PINGTARGET 2>/dev/null | tail -n2; exit ${PIPESTATUS[0]})
  if test $? = 0; then echo $PING; return 0; fi
  #nslookup $PINGTARGET2 >/dev/null 2>&1
  echo -n "x"
  sleep 2
  PING=$(ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "ConnectTimeout=8" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 ping -c1 $PINGTARGET2 2>&1 | tail -n2; exit ${PIPESTATUS[0]})
  RC=$?
  echo -n "x"
  if test $RC == 0; then return 0; fi
  echo "$PING"
  ERR=$PING
  #sleep 1
  #PING=$(ssh -i $1.pem $pport -o "PasswordAuthentication=no" -o "ConnectTimeout=8" -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" ${USER}@$2 ping -c1 9.9.9.9 >/dev/null 2>&1 | tail -n2; exit ${PIPESTATUS[0]})
  #RC=$?
  if test $RC != 0; then return 1; else return 0; fi
}

# Test internet access of JumpHosts (via ssh)
testjhinet()
{
  local RC R JHNO ST TIM
  unset SSH_AUTH_SOCK
  ERR=""
  #echo "Test JH access and outgoing inet ... "
  ST=$(date +%s)
  declare -i RC=0
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    echo -n "Access JH$JHNO (${FLOATS[$JHNO]}): "
    # Do wait up to 60s for ping
    declare -i ctr=0
    while test $ctr -lt 15; do
      ping -c1 -w2 ${FLOATS[$JHNO]} >/dev/null 2>&1 && break
      sleep 2
      echo -n "."
      let ctr+=1
    done
    if test $ctr -ge 15; then echo -n "(ping timeout)"; ERR="${ERR}ping ${FLOATS[$JHNO]}; "; fi
    # Wait up to 36s for ssh
    testlsandping ${KEYPAIRS[0]} ${FLOATS[$JHNO]}
    R=$?
    if test $R == 2; then
      RC=2; ERR="${ERR}ssh JH$JHNO ls; "
    elif test $R == 1; then
      let CUMPINGERRORS+=1; ERR="${ERR}ssh JH$JHNO ping $PINGTARGET || ping $PINGTARGET2; "
    fi
# We skip wait222 now for failed JHs, so we need to record this here in case of failure
# Don't generate entry for success here, we'll test this again in wait222, which records the success/time
    if test -n "$GRAFANA" -a $R != 0; then
      TIM=$(($(date +%s)-$ST))
      curl -si -XPOST 'http://localhost:8186/write?db=cicd' --data-binary "$GRAFANANM,cmd=ssh,method=JHVM$JHNO duration=$TIM,return_code=$R $(date +%s%N)" >/dev/null
    fi
  done
  if test $RC = 0; then
    echo -e "$GREEN SUCCESS $NORM ($(($(date +%s)-$ST))s)"
    if test -n "$ERR"; then echo -e "RC=0 but $RED $ERR $NORM"; fi
  else
     echo -e "$RED FAIL $ERR $NORM ($(($(date +%s)-$ST))s)"
  fi
  return $RC
}

# Test VM access (fwdmasq) and outgoing SNAT inet on all VMs
testsnat()
{
  local FAIL ERRJH pno RC JHNO
  unset SSH_AUTH_SOCK
  ERR=""
  ERRJH=()
  declare -i FAIL=0
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    declare -i no=$JHNO
    for red in ${REDIRS[$JHNO]}; do
      pno=${red#*tcp,}
      pno=${pno%%,*}
      testlsandping ${KEYPAIRS[1]} ${FLOATS[$JHNO]} $pno $no
      RC=$?
      let no+=$NOAZS
      if test $RC == 2; then
        ERRJH[$JHNO]="${ERRJH[$JHNO]}$red "
      elif test $RC == 1; then
        let PINGERRORS+=1
        ERR="${ERR}ssh VM$JHNO $red ping $PINGTARGET || ping $PINGTARGET2; "
      fi
    done
  done
  if test ${#ERRJH[*]} != 0; then echo -e "$RED $ERR $NORM"; ERR=""; sleep 12; fi
  # Process errors: Retry
  # FIXME: Is it actually worth retrying? Does it really improve the results?
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    no=$JHNO
    for red in ${ERRJH[$JHNO]}; do
      pno=${red#*tcp,}
      pno=${pno%%,*}
      testlsandping ${KEYPAIRS[1]} ${FLOATS[$JHNO]} $pno $no
      RC=$?
      let no+=$NOAZS
      if test $RC == 2; then
        let FAIL+=2
        ERR="${ERR}(2)ssh VM$JHNO $red ls; "
      elif test $RC == 1; then
        let PINGERRORS+=1
        ERR="${ERR}(2)ssh VM$JHNO $red ping $PINGTARGET || ping $PINGTARGET2; "
      fi
    done
  done
  if test -n "$ERR"; then echo -e "$RED $ERR ($FAIL) $NORM"; fi
  if test ${#ERRJH[*]} != 0; then
    echo -en "$BOLD RETRIED: "
    for JHNO in $(seq 0 $(($NOAZS-1))); do
      test -n "${ERRJH[$JHNO]}" && echo -n "$JHNO: ${ERRJH[$JHNO]} "
    done
    echo -e "$NORM"
  fi
  return $FAIL
}

declare -i FPRETRY=0
declare -i FPERR=0
# Have each VM ping all VMs
# OUTPUT:
# FPRETRY: Number of retried pings
# FPERR: Number of failed pings (=> $RC)
fullconntest()
{
  cat > ${RPRE}ping << EOT
#!/bin/bash
myping()
{
  if ping -c1 -w1 \$1 >/dev/null 2>&1; then echo -n "."; return 0; fi
  sleep 1
  if ping -c1 -w3 \$1 >/dev/null 2>&1; then echo -n "o"; return 1; fi
  echo -n "X"; return 2
}
declare -i RETRIES=0
declare -i FAILS=0
for adr in "\$@"; do
  myping \$adr
  RC=\$?
  if test \$RC == 1; then let RETRIES+=1; fi
  if test \$RC == 2; then let FAILS+=1; fi
done
echo " \$RETRIES \$FAILS"
exit \$((RETRIES+FAILS))
EOT
  chmod +x ${RPRE}ping
  # collect all IPs
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron port-list -c id -c device_id -c fixed_ips -f json
  IPS=()
  NP=${#PORTS[*]}
  for pno in $(seq 0 $(($NP-1))); do
    port=${PORTS[$pno]}
    if test -z "$OPENSTACKCLIENT"; then
      IPS[$pno]=$(echo "$OSTACKRESP" | jq ".[] | select(.id == \"$port\") | .fixed_ips[] | .ip_address" | tr -d '"')
    else
      IPS[$pno]=$(echo "$OSTACKRESP" | jq ".[] | select(.ID == \"$port\") | .[\"Fixed IP Addresses\"]")
      if echo "${IPS[$pno]}" | grep ip_address >/dev/null 2>&1; then IPS[$pno]=$(echo "${IPS[$pno]}" | jq '.[].ip_address'); fi
      IPS[$pno]=$(echo "${IPS[$pno]}" | tr -d '"' | sed "$PORTFIXED")
    fi
  done
  if test -n "$SECONDNET"; then
    for pno in $(seq 0 $((${#SECONDPORTS[*]}-1))); do
      port=${SECONDPORTS[$pno]}
      if test -z "$OPENSTACKCLIENT"; then
        IPS[$((pno+NP))]=$(echo "$OSTACKRESP" | jq ".[] | select(.id == \"$port\") | .fixed_ips[] | .ip_address" | tr -d '"')
      else
        IPS[$((pno+NP))]=$(echo "$OSTACKRESP" | jq ".[] | select(.ID == \"$port\") | .[\"Fixed IP Addresses\"]")
        if echo "${IPS[$((pno+NP))]}" | grep ip_address >/dev/null 2>&1; then IPS[$((pno+NP))]=$(echo "${IPS[$((pno+NP))]}" | jq '.[].ip_address'); fi
        IPS[$((pno+NP))]=$(echo "${IPS[$((pno+NP))]}" | tr -d '"' | sed "$PORTFIXED")
      fi
    done
  fi
  ERR=""
  FPRETRY=0
  FPERR=0
  echo "VM2VM Connectivity Check ... (${IPS[*]})"
  RC=0
  for JHNO in $(seq 0 $(($NOAZS-1))); do
    no=$JHNO
    for red in ${REDIRS[$JHNO]}; do
      pno=${red#*tcp,}
      pno=${pno%%,*}
      scp -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" -o "PasswordAuthentication=no" -i ${KEYPAIRS[1]}.pem -P $pno -p ${RPRE}ping ${DEFLTUSER}@${FLOATS[$JHNO]}: >/dev/null
      #echo "ssh -o \"UserKnownHostsFile=~/.ssh/known_hosts.$RPRE\" -o \"PasswordAuthentication=no\" -i ${KEYPAIRS[1]}.pem -p $pno ${DEFLTUSER}@${FLOATS[$JHNO]} ./${RPRE}ping ${IPS[*]}"
      if test -n "$LOGFILE"; then echo "ssh -o \"UserKnownHostsFile=~/.ssh/known_hosts.$RPRE\" -o \"PasswordAuthentication=no\" -i ${KEYPAIRS[1]}.pem -p $pno ${DEFLTUSER}@${FLOATS[$JHNO]} ./${RPRE}ping ${IPS[*]})" >> $LOGFILE; fi
      PINGRES="$(ssh -o "UserKnownHostsFile=~/.ssh/known_hosts.$RPRE" -o "PasswordAuthentication=no" -i ${KEYPAIRS[1]}.pem -p $pno ${DEFLTUSER}@${FLOATS[$JHNO]} ./${RPRE}ping ${IPS[*]})"
      R=$?
      if test $R -gt $RC; then RC=$R; fi
      echo "$PINGRES"
      if test "$R" = "255"; then let CONNERRORS+=$((2*$NOVMS)); let FPERR+=$NOVMS; ERR="$ERR
UNREACHABLE 0 $NOVMS"; continue; fi
      ERR="$ERR
$PINGRES"
      let CONNERRORS+=$R
      PINGRES="${PINGRES#* }"
      let FPRETRY+=${PINGRES% *}
      let FPERR+=${PINGRES#* }
    done
  done
  rm ${RPRE}ping
  return $RC
}

# [-m] STATLIST [DIGITS [NAME]]
# m for machine readable
stats()
{
  local NM NO VAL LIST DIG OLDIFS SLIST MIN MAX MID MED NFQ NFQL NFQR NFQF NFP AVGC AVG
  if test "$1" = "-m"; then MACHINE=1; shift; else unset MACHINE; fi
  # Fixup "{" found after errors in time stats
  NM=$1
  NO=$(eval echo "\${#${NM}[@]}")
  for idx in `seq 0 $(($NO-1))`; do
    VAL=$(eval echo \${${NM}[$idx]})
    if test "$VAL" = "{"; then eval $NM[$idx]=1.00; fi
  done
  # Display name
  if test -n "$3"; then NAME=$3; else NAME=$1; fi
  # Generate list and sorted list
  eval LIST=( \"\${${1}[@]}\" )
  if test -z "${LIST[*]}"; then return; fi
  DIG=${2:-2}
  OLDIFS="$IFS"
  IFS=$'\n' SLIST=($(sort -n <<<"${LIST[*]}"))
  IFS="$OLDIFS"
  #echo ${SLIST[*]}
  NO=${#SLIST[@]}
  # Some easy stats, Min, Max, Med, Avg, 95% quantile ...
  MIN=${SLIST[0]}
  MAX=${SLIST[-1]}
  MID=$(($NO/2))
  if test $(($NO%2)) = 1; then MED=${SLIST[$MID]};
  else MED=`math "%.${DIG}f" "(${SLIST[$MID]}+${SLIST[$(($MID-1))]})/2"`
  fi
  NFQ=$(scale=3; echo "(($NO-1)*95)/100" | bc -l)
  NFQL=${NFQ%.*}; NFQR=$((NFQL+1)); NFQF=0.${NFQ#*.}
  #echo "DEBUG 95%: $NFQ $NFQL $NFR $NFQF"
  if test $NO = 1; then NFP=${SLIST[$NFQL]}; else
    NFP=`math "%.${DIG}f" "${SLIST[$NFQL]}*(1-$NFQF)+${SLIST[$NFQR]}*$NFQF"`
  fi
  AVGC="($(echo ${SLIST[*]}|sed 's/ /+/g'))/$NO"
  #echo "$AVGC"
  #AVG=`math "%.${DIG}f" "$AVGC"`
  AVG=$(echo "scale=$DIG; $AVGC" | bc -l)
  if test -n "$MACHINE"; then
    echo "#$NM: $NO|$MIN|$MED|$AVG|$NFP|$MAX" | tee -a $LOGFILE
  else
    echo "$NAME: Num $NO Min $MIN Med $MED Avg $AVG 95% $NFP Max $MAX" | tee -a $LOGFILE
  fi
}

# [-m] for machine readable
allstats()
{
 stats $1 NETSTATS   2 "Neutron CLI Stats "
 stats $1 FIPSTATS   2 "Neutron FIP Stats "
 stats $1 NOVASTATS  2 "Nova CLI Stats    "
 stats $1 NOVABSTATS 2 "Nova Boot Stats   "
 stats $1 VMCSTATS   0 "VM Creation Stats "
 if test -n "$LOADBALANCER"; then
   stats $1 LBCSTATS   0 "LB Creation Stats "
 fi
 stats $1 VMDSTATS   0 "VM Deletion Stats "
 stats $1 VOLSTATS   2 "Cinder CLI Stats  "
 stats $1 VOLCSTATS  0 "Vol Creation Stats"
 stats $1 WAITTIME   0 "Wait for VM Stats "
 stats $1 TOTTIME    0 "Total setup Stats "
}

# Identify which FIPs really belong to us
# Also populates JHPORTS (in Name order)
findFIPs()
{
  FIPRESP="$OSTACKRESP"
  EP="$NEUTRON_EP"
  ostackcmd_tm NETSTATS $NETTIMEOUT myopenstack port list --network ${JHNETS[0]} --sort-column Name
  JHPORTS=()
  while read ln; do
    PORT=$(echo "$ln" | sed 's/^| \([0-9a-f-]*\) .*$/\1/')
    JHPORTS+=$PORT
  done < <(echo "$OSTACKRESP")
  #echo -n " JHPorts(${#JHPORTS[*]}): ${JHPORTS[*]}"
  ostackcmd_tm NETSTATS $NETTIMEOUT neutron floatingip-list
  FIPS=(); FLOATS=()
  for fno in $(seq 0 $((${#JHPORTS[*]}-1))); do
    #echo -en "\nneutron floatingip-list | grep -e \"${JHPORTS[$fno]}\": "
    #echo "$OSTACKRESP" | grep -e "${JHPORTS[$fno]}" | sed 's/^| *\([^ ]*\) *|.*$/\1/'
    FIPS[$fno]=$(echo "$OSTACKRESP" | grep -e "${JHPORTS[$fno]}" | sed 's/^| *\([^ ]*\) *|.*$/\1/')
    FLOATS[$fno]=$(echo "$OSTACKRESP" | grep -e "${FIPS[$fno]}" | sed "$FLOATEXTR")
  done
}

# TODO: Create wrapper that collects stats, handles timeouts ...
# Helper to find a resource ...
# $1 => Filter (grepped)
# $2--oo => command
findres()
{
  local FILT=${1:-$RPRE}
  shift
  translate "$@"
  # FIXME: Add timeout handling
  ${OSTACKCMD[@]} 2>/dev/null | grep " $FILT" | sed 's/^| \([0-9a-f-]*\) .*$/\1/'
}

collectRes()
{
  echo -en "${BOLD}Collecting resources:${NORM} "
  ROUTERS=( $(findres "" neutron router-list) )
  SNATROUTE=1
  JHVMS=( $(findres ${RPRE}VM_JH nova list --sort display_name:asc) )
  NOAZS=${#JHVMS[*]}
  if test "$NOAZS" == 0; then echo "No JH"; return 1; fi
  VIPS=( $(findres ${RPRE}VirtualIP neutron port-list) )
  VOLUMES=( $(findres ${RPRE}RootVol_VM cinder list) )
  # Volume names if we boot from image
  VOLUMES2=( $(findres ${RPRE}VM_VM cinder list) )
  JHVOLUMES=( $(findres ${RPRE}RootVol_JH cinder list) )
  echo -en "$NOAZS JHVMs $((${#VOLUMES[*]}+${#VOLUMES2[*]}+${#JHVOLUMES[*]})) Vols"
  KEYPAIRS=( $(nova keypair-list | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  # Detect secondary ports, delete again, but set flag
  JHSUBNETS=( $(findres ${RPRE}SUBNET_JH neutron subnet-list) )
  SUBNETS=( $(findres ${RPRE}SUBNET_VM neutron subnet-list) )
  SECONDSUBNETS=( $(findres ${RPRE}SUBNET2_VM neutron subnet-list) )
  LBAASS=( $(findres ${RPRE}LB neutron lbaas-loadbalancer-list) )
  if test -n "$LBAASS"; then
    POOLS=( $(findres ${RPRE}Pool neutron lbaas-pool-list) )
    LISTENERS=( $(findres ${RPRE}Listener neutron lbaas-listener-list) )
    #MEMBERS=( $(findres ${RPRE}Member neutron lbaas-member-list ${POOLS[0]}) )
  fi
  JHNETS=( $(findres ${RPRE}NET_JH neutron net-list) )
  NETS=( $(findres ${RPRE}NET_VM neutron net-list) )
  SECONDNETS=( $(findres ${RPRE}NET2_VM neutron net-list) )
  NONETS=${#NETS[*]}
  echo -n " $NONETS networks"
  if test -n "$SECONDNETS"; then SECONDNET=1; fi
  #SECONDPORTS=( $(findres ${RPRE}Port2_VM neutron port-list) )
  #if test -n "$SECONDPORTS"; then SECONDNET=1; SECONDPORTS=(); fi
  #ostackcmd_tm NETSTATS $NETTIMEOUT neutron floatingip-list || return 1
  #FIPS=( $(echo "$OSTACKRESP" | grep '10\.250\.255' | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  #if test "${#FIPS[*]} != ${NOAZS[*]}"; then filterFIPs; fi
  findFIPs
  #echo "FIPS: ${FIPS[*]}, FLOATS: ${FLOATS[*]}"
  echo -n " ${#FLOATS[*]} Floats (${FLOATS[*]}) "
  #VMS=( $(findres ${RPRE}VM_VM nova list --sort display_name:asc) )
  ostackcmd_tm NOVASTATS $NOVATIMEOUT nova list --sort display_name:asc
  orderVMs
  NOVMS=${#VMS[*]}
  echo " $NOVMS VMs "
  #echo "VMS: ${VMS[*]}"
  collectPorts
  #JHPORTS=( $(findres ${RPRE}Port_JH neutron port-list) )
  SGROUPS=( $(findres "" neutron security-group-list) )
  calcRedirs
  if test ${#VMS[*]} -gt 0; then
    # Determine batch mode
    ostackcmd_tm NOVASTATS $NOVATIMEOUT nova show ${VMS[0]}
    if echo "$OSTACKRESP" | grep -e 'metadata' | grep '"deployment": "cfbatch"' >/dev/null 2>&1; then BOOTALLATONCE=1; fi
    # openstack server list output is slightly different
    if echo "$OSTACKRESP" | grep -e 'properties' | grep "deployment='cfbatch'" >/dev/null 2>&1; then BOOTALLATONCE=1; fi
  fi
}

cleanup_new()
{
  collectRes
  deleteVMs
  deleteFIPs
  deleteJHVMs
  deleteVIPs
  cleanLBs
  waitdelVMs; deleteVols
  VOLUMES=("${VOLUMES2[@]}"); deleteVols
  waitdelJHVMs; deleteJHVols
  deleteLBs
  deleteKeypairs
  delete2ndPorts; deletePorts; deleteJHPorts	# not strictly needed, ports are del by VM del
  deleteSGroups
  deleteRIfaces
  deleteSubNets; deleteJHSubNets
  deleteNets; deleteJHNets
  deleteRouters
}

cleanup()
{
  # Could also call collectres here first and then clean up ...
  # Might result in a few extra port deletions but otherwise work
  # See cleanup_new (will switch after some extra testing)
  VMS=( $(findres ${RPRE}VM_VM nova list) )
  deleteVMs
  ROUTERS=( $(findres "" neutron router-list) )
  SNATROUTE=1
  #FIPS=( $(findres "" neutron floatingip-list) )
  # NOTE: This will find FIPs from other APIMon jobs in the same tenant also
  #  maybe we should use findFIPs
  translate neutron floatingip-list
  FIPS=( $(${OSTACKCMD[@]} | grep '10\.250\.255' | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  deleteFIPs
  JHVMS=( $(findres ${RPRE}VM_JH nova list) )
  deleteJHVMs
  LBAASS=( $(findres ${RPRE}LB neutron lbaas-loadbalancer-list) )
    if test -n "$LBAASS"; then
    POOLS=( $(findres ${RPRE}Pool neutron lbaas-pool-list) )
    LISTENERS=( $(findres ${RPRE}Listener neutron lbaas-listener-list) )
    #MEMBERS=( $(findres ${RPRE}Member neutron lbaas-member-list ${POOLS[0]}) )
  fi
  cleanLBs
  VIPS=( $(findres ${RPRE}VirtualIP neutron port-list) )
  deleteVIPs
  VOLUMES=( $(findres ${RPRE}RootVol_VM cinder list) )
  waitdelVMs; deleteVols
  # When we boot from image, names are different ...
  VOLUMES=( $(findres ${RPRE}VM_VM cinder list) )
  deleteVols
  JHVOLUMES=( $(findres ${RPRE}RootVol_JH cinder list) )
  waitdelJHVMs; deleteJHVols
  deleteLBs
  translate nova keypair-list
  KEYPAIRS=( $(${OSTACKCMD[@]} | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  deleteKeypairs
  PORTS=( $(findres ${RPRE}Port_VM neutron port-list) )
  SECONDPORTS=( $(findres ${RPRE}Port2_VM neutron port-list) )
  if test -n "$SECONDPORTS"; then SECONDNET=1; fi
  JHPORTS=( $(findres ${RPRE}Port_JH neutron port-list) )
  delete2ndPorts; deletePorts; deleteJHPorts	# not strictly needed, ports are del by VM del
  SGROUPS=( $(findres "" neutron security-group-list) )
  deleteSGroups
  SUBNETS=( $(findres "" neutron subnet-list) )
  JHSUBNETS=()
  deleteRIfaces
  deleteSubNets
  NETS=( $(findres "" neutron net-list) )
  JHNETS=()
  deleteNets
  deleteRouters
}

# Network cleanups can fail if VM deletion failed, so cleanup again
# and wait until networks have disappeared
waitnetgone()
{	
  local DVMS DFIPS DJHVMS DKPS VOLS DJHVOLS
  # Cleanup: These really should not exist
  VMS=( $(findres ${RPRE}VM_VM nova list) ); DVMS=(${VMS[*]})
  deleteVMs
  ROUTERS=( $(findres "" neutron router-list) )
  # Floating IPs don't have a name and are thus hard to associate with us
  ostackcmd_tm NETSTATS $FIPTIMEOUT neutron floatingip-list
  if test -n "$CLEANALLFIPS"; then
    FIPS=( $(echo "$OSTACKRESP" | grep '[0-9]\{1,3\}\.[0-9]\{1,3\}\.' | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  elif test -n "${OLDFIPS[*]}"; then
    OFFILT=$(echo "\\(${OLDFIPS[*]}\\)" | sed 's@ @\\|@g')
    FIPS=( $(echo "$OSTACKRESP" | grep "$OFFILT" | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  else
    FIPS=( $(echo "$OSTACKRESP" | grep '10\.250\.255' | sed 's/^| *\([^ ]*\) *|.*$/\1/') )
  fi
  DFIPS=(${FIPS[*]})
  deleteFIPs
  JHVMS=( $(findres ${RPRE}VM_JH nova list) ); DJHVMS=(${JHVMS[*]})
  deleteJHVMs
  VOLUMES=( $(findres ${RPRE}RootVol_VM cinder list) ); DVOLS=(${VOLUMES[*]})
  waitdelVMs; deleteVols
  JHVOLUMES=( $(findres ${RPRE}RootVol_JH cinder list) ); DJHVOLS=(${JHVOLUMES[*]})
  waitdelJHVMs; deleteJHVols
  ostackcmd_tm NOVASTATS $DEFTIMEOUT nova keypair-list
  KEYPAIRS=( $(echo "$OSTACKCMD" | grep $RPRE | sed 's/^| *\([^ ]*\) *|.*$/\1/') ); DKPS=(${KEYPAIRS[*]})
  deleteKeypairs
  if test -n "$DVMS$DFIPS$DJHVMS$DKPS$DVOL$DJHVOLS"; then
    echo -e "${YELLOW}ERROR: Found VMs $DVMS FIPs $DFIPS JHVMs $DJHVMS Keypairs $DKPS Volumes $DVOLS JHVols $DJHVOLS\n VMs $REMVMS FIPS $REMFIPS JHVMs $REMHJVMS Keypairs $REMKPS Volumes $REMVOLS JHVols $REMJHVOLS$NORM" 1>&2
    sendalarm 1 Cleanup "Found VMs $DVMS FIPs $DFIPS JHVMs $DJHVMS Keypairs $DKPS Volumes $DVOLS JHVols $DJHVOLS
 VMs $REMVMS FIPs $REMFIPS JHVMs $REMJHVMS Keypairs $REMKPS Volumes $REMVOLS JHVols $REMJHVOLS" 0
  fi
  # Cleanup: These might be left over ...
  local to
  declare -i to=0
  # There should not be anything left ...
  PORTS=( $(findres "" neutron port-list) )
  IGNORE_ERRORS=1
  deletePorts
  unset IGNORE_ERRORS
  echo -n "Wait for subnets/nets to disappear: "
  while test $to -lt 40; do
    SUBNETS=( $(findres "" neutron subnet-list) )
    NETS=( $(findres "" neutron net-list) )
    if test -z "${SUBNETS[*]}" -a -z "${NETS[*]}"; then echo "gone"; return; fi
    sleep 2
    let to+=1
    echo -n "."
  done
  SGROUPS=( $(findres "" neutron security-group-list) )
  ROUTERS=( $(findres "" neutron router-list) )
  IGNORE_ERRORS=1
  deleteSGroups
  if test -n "$ROUTERS"; then deleteRIfaces; fi
  deleteSubNets
  deleteNets
  if test -n "$ROUTERS"; then deleteRouters; fi
  unset IGNORE_ERRORS
}

# Token retrieval and catalog ...

# Args: Name (implicit: OSTACKRESP)
getPublicEP()
{
  local EPS EPS2 NL
  NL="$(echo)"
  EPS=$(echo "$OSTACKRESP" | jq ".[] | select(.Name == \"$1\") | .Endpoints")
  EPS2=$(echo "$EPS" | jq '.[] | .interface+"|"+.region+"|"+.region_id+"|"+.url' 2>/dev/null | tr -d '"')
  if test -z "$EPS2" -a -n "$EPS"; then
    while read ln; do
      if echo "$ln" | grep '^[^:]*$' >/dev/null 2>&1; then REG=$ln; continue; fi
      ENT=$(echo $ln | sed "s@^ *\([^:]*\): @\1|$REG|$REG|@")
      EPS2="${EPS2}$ENT$NL"
    done < <(echo -e $EPS)
  fi
  if test -n "$OS_REGION_NAME"; then EPS2=$(echo "$EPS2" | grep "$OS_REGION_NAME"); fi
  EPS=$(echo "$EPS2" | grep public)
  echo "${EPS##*|}"
}

TOKEN=""
getToken()
{
  ostackcmd_tm KEYSTONESTATS $DEFTIMEOUT openstack catalog list -f json
  NOVA_EP=$(getPublicEP nova)
  CINDER_EP=$(getPublicEP cinder)
  if test -z "$CINDER_EP"; then CINDER_EP=$(getPublicEP cinderv2); fi
  GLANCE_EP=$(getPublicEP glance)
  NEUTRON_EP=$(getPublicEP neutron)
  #echo "ENDPOINTS: $NOVA_EP, $CINDER_EP, $GLANCE_EP, $NEUTRON_EP"
  ostackcmd_tm KEYSTONESTATS $DEFTIMEOUT openstack token issue -f json
  TOKEN=$(echo "$OSTACKRESP" | jq '.id' | tr -d '"')
  #echo "TOKEN: {SHA1}$(echo $TOKEN | sha1sum)"
  PROJECT=$(echo "$OSTACKRESP" | jq '.project_id' | tr -d '"')
  USER=$(echo "$OSTACKRESP" | jq '.user_id' | tr -d '"')
  #echo "PROJECT: $PROJECT, USER: $USER"
}

# Clean/Delete old OpenStack project
cleanprj()
{
  if test ${#OS_PROJECT_NAME} -le 5; then echo -e "${YELLOW}ERROR: Won't delete $OS_PROJECT_NAME$NORM" 1>&2; return 1; fi
  #TODO: Wait for resources being gone
  sleep 10
  otc.sh iam deleteproject $OS_PROJECT_NAME 2>/dev/null || otc.sh iam cleanproject $OS_PROJECT_NAME
  echo -e "${REV}Note: Removed Project $OS_PROJECT_NAME ($?)${NORM}"
}

# Create a new OpenStack project
createnewprj()
{
  # First cleanup old project
  if test "$RUNS" != 0; then cleanprj; fi
  PRJNO=$(($RUNS/$REFRESHPRJ))
  OS_PROJECT_NAME=${OS_PROJECT_NAME:0:5}_APIMonitor_$$_$PRJNO
  unset OS_PROJECT_ID
  otc.sh iam createproject $OS_PROJECT_NAME >/dev/null
  echo -e "${REV}Note: Created project $OS_PROJECT_NAME ($?)$NORM"
  sleep 10
}

# Allow for many recipients
parse_notification_addresses()
{
  # Parses from Environment
  # API_MONITOR_ALARM_EMAIL_[0-9]+         # email address
  # API_MONITOR_NOTE_EMAIL_[0-9]+          # email address
  # API_MONITOR_ALARM_MOBILE_NUMBER_[0-9]+ # international mobile number
  # API_MONITOR_NOTE_MOBILE_NUMBER_[0-9]+  # international mobile number

  # Sets global array with values from enironment variables:
  # ${ALARM_EMAIL_ADDRESSES[@]}
  # ${NOTE_EMAIL_ADDRESSES[@]}
  # ${ALARM_MOBILE_NUMBERS[@]}
  # ${NOTE_MOBILE_NUMBERS[@]}

  for env_name in $(env | egrep API_MONITOR_ALARM_EMAIL\(_[0-9]+\)? | sed 's/^\([^=]*\)=.*/\1/')
  do
    ALARM_EMAIL_ADDRESSES=("${ALARM_EMAIL_ADDRESSES[@]}" ${!env_name})
  done

  for env_name in $(env | egrep API_MONITOR_NOTE_EMAIL\(_[0-9]+\)? | sed 's/^\([^=]*\)=.*/\1/')
  do
    NOTE_EMAIL_ADDRESSES=("${NOTE_EMAIL_ADDRESSES[@]}" ${!env_name})
  done

  for env_name in $(env | egrep API_MONITOR_ALARM_MOBILE_NUMBER\(_[0-9]+\)? | sed 's/^\([^=]*\)=.*/\1/')
  do
    ALARM_MOBILE_NUMBERS=("${ALARM_MOBILE_NUMBERS[@]}" ${!env_name})
  done

  for env_name in $(env | egrep API_MONITOR_NOTE_MOBILE_NUMBER\(_[0-9]+\)? | sed 's/^\([^=]*\)=.*/\1/')
  do
    NOTE_MOBILE_NUMBERS=("${NOTE_MOBILE_NUMBERS[@]}" ${!env_name})
  done
}

parse_notification_addresses

declare -i loop=0

# Statistics
# API performance neutron, cinder, nova
declare -a NETSTATS
declare -a FIPSTATS
declare -a VOLSTATS
declare -a NOVASTATS
declare -a KEYSTONESTATS
declare -a NOVABSTATS
# Resource creation stats (creation/deletion)
declare -a VOLCSTATS
declare -a VOLDSTATS
declare -a VMCSTATS
declare -a LBCSTATS
declare -a VMCDTATS

declare -a TOTTIME
declare -a WAITTIME

declare -i CUMPINGERRORS=0
declare -i CUMLBERRORS=0
declare -i CUMAPIERRORS=0
declare -i CUMAPITIMEOUTS=0
declare -i CUMAPICALLS=0
declare -i CUMVMERRORS=0
declare -i CUMWAITERRORS=0
declare -i CUMCONNERRORS=0
declare -i CUMVMS=0
declare -i RUNS=0
declare -i SUCCRUNS=0

LASTDATE=$(date +%Y-%m-%d)
LASTTIME=$(date +%H:%M:%S)

# Declare empty router list outside of loop
# so we can reuse (option -r N).
declare -a ROUTERS=()

# We save roundtrips to keystone, so be 2s more aggressive with timeouts
if test -n "$OPENSTACKTOKEN"; then
  let NETTIMEOUT-=2
  let FIPTIMEOUT-=2
  let NOVATIMEOUT-=2
  let NOVABOOTTIMEOUT-=2
  let CINDERTIMEOUT-=2
  let GLANCETIMEOUT-=2
  let DEFTIMEOUT-=2
fi


# MAIN LOOP
while test $loop != $MAXITER; do

declare -i PINGERRORS=0
declare -i APIERRORS=0
declare -i APITIMEOUTS=0
declare -i VMERRORS=0
declare -i LBERRORS=0
declare -i WAITERRORS=0
declare -i CONNERRORS=0
declare -i APICALLS=0
declare -i ROUNDVMS=0

# Arrays to store resource creation start times
declare -a VOLSTIME=()
declare -a JVOLSTIME=()
declare -a VMSTIME=()
declare -a JVMSTIME=()
declare -a LBSTIME=()

# List of resources - neutron
declare -a NETS=()
declare -a SUBNETS=()
declare -a JHNETS=()
declare -a JHSUBNETS=()
declare -a LBAASS=()
declare -a SGROUPS=()
declare -a JHPORTS=()
declare -a PORTS=()
declare -a VIPS=()
declare -a FIPS=()
declare -a FLOATS=()
# cinder
declare -a JHVOLUMES=()
declare -a VOLUMES=()
# nova
declare -a KEYPAIRS=()
declare -a VMS=()
declare -a JHVMS=()
SNATROUTE=""

# Main
MSTART=$(date +%s)
# Get token
if test -n "$OPENSTACKTOKEN"; then
  getToken
  if test -z "$CINDER_EP" -o -z "$NOVA_EP" -o -z "$GLANCE_EP" -o -z "$NEUTRON_EP" -o -z "$TOKEN"; then
    echo "Trouble getting token/catalog, retry ..."
    sleep 2
    getToken
  fi
  TOKENSTAMP=$(date +%s)
fi
# Debugging: Start with volume step
if test "$1" = "CLEANUP"; then
  if test -n "$2"; then RPRE=$2; if test ${RPRE%_} == ${RPRE}; then RPRE=${RPRE}_; fi; fi
  echo -e "$BOLD *** Start cleanup $RPRE *** $NORM"
  #SECONDNET=1
  cleanup
  echo -e "$BOLD *** Cleanup complete *** $NORM"
  # We always return 0 here, as we dont want to stop the testing on failed cleanups.
  exit 0
elif test "$1" = "CONNTEST"; then
  if test -n "$2"; then RPRE=$2; if test ${RPRE%_} == ${RPRE}; then RPRE=${RPRE}_; fi; fi
  while test $loop != $MAXITER; do
   echo -e "$BOLD *** Start connectivity test for $RPRE *** $NORM"
   # Only collect resource on e. 10th iteration
   if test "$(($loop%10))" == 0; then collectRes; else echo " Reuse known resources ..."; sleep 2; fi
   if test -z "${VMS[*]}"; then echo "No VMs found"; exit 1; fi
   #echo "FLOATs: ${FLOATS[*]} JHVMS: ${JHVMS[*]}"
   testjhinet
   RC=$?
   if test $RC != 0; then
     sendalarm 2 "JH unreachable" "$ERR" 20
     if test -n "$EXITERR"; then exit 2; fi
     let VMERRORS+=$RC
     errwait $ERRWAIT
   fi
   #echo "REDIRS: ${REDIRS[*]}"
   wait222
   # Defer alarms
   #if test $? != 0; then exit 2; fi
   testsnat
   RC=$?
   if test $RC != 0; then
     sendalarm 2 "VMs unreachable/can not ping outside" "$ERR" 16
     if test -n "$EXITERR"; then exit 3; fi
     let VMERRORS+=$RC
     errwait $ERRWAIT
   fi
   if test -n "$RESHUFFLE" -a -n "$STARTRESHUFFLE"; then reShuffle; fi
   fullconntest
   #if test $? != 0; then exit 4; fi
   if test $FPERR -gt 0; then
     sendalarm 2 "Connectivity errors" "$FPERR + $FPRETRY\n$ERR" 5
     if test -n "$EXITERR"; then exit 4; fi
     # Error counting done by fullconntest already
     errwait $ERRWAIT
   fi
   if test -n "$RESHUFFLE"; then
     reShuffle
     fullconntest
     if test $FPERR -gt 0; then
       sendalarm 2 "Connectivity errors" "$FPERR + $FPRETRY\n$ERR" 5
       if test -n "$EXITERR"; then exit 4; fi
       # Error counting done by fullconntest already
       errwait $ERRWAIT
       fi
     let SUCCRUNS+=1
   fi
   echo -e "$BOLD *** Connectivity test complete *** $NORM"
   let SUCCRUNS+=1
   if test $SUCCWAIT -ge 0; then sleep $SUCCWAIT; else echo -n "Hit enter to continue ..."; read ANS; fi
   let loop+=1
   # Refresh token after 10hrs
   if test -n "$TOKENSTAMP" && test $(($(date +%s)-$TOKENSTAMP)) -ge 36000; then
     getToken
     TOKENSTAMP=$(date +%s)
   fi
   # TODO: We don't do anything with the collected statistics in CONNTEST yet ... fix!
  done
  exit 0 #$RC
else # test "$1" = "DEPLOY"; then
 if test "$REFRESHPRJ" != 0 && test $(($RUNS%$REFRESHPRJ)) == 0; then createnewprj; fi
 # Complete setup
 echo -e "$BOLD *** Start deployment $loop for $NOAZS SNAT JumpHosts + $NOVMS VMs *** $NORM ($TRIPLE)"
 date
 unset THISRUNSUCCESS
 # Image IDs
 JHIMGID=$(ostackcmd_search "$JHIMG" $GLANCETIMEOUT glance image-list $JHIMGFILT | awk '{ print $2; }')
 if test -z "$JHIMGID" -o "$JHIMGID" == "0"; then sendalarm 1 "No JH image $JHIMG found, aborting." "" $GLANCETIMEOUT; exit 1; fi
 IMGID=$(ostackcmd_search "$IMG" $GLANCETIMEOUT glance image-list $IMGFILT | awk '{ print $2; }')
 if test -z "$IMGID" -o "$IMG" == "0"; then sendalarm 1 "No image $IMG found, aborting." "" $GLANCETIMEOUT; exit 1; fi
 let APICALLS+=2
 # Retrieve root volume size
 OR=$(ostackcmd_id min_disk $GLANCETIMEOUT glance image-show $JHIMGID)
 if test $? != 0; then
  let APIERRORS+=1; sendalarm 1 "glance image-show failed" "" $GLANCETIMEOUT
  errwait $ERRWAIT
  let loop+=1
  continue
 else
  read TM SZ <<<"$OR"
  JHVOLSIZE=$(($SZ+$ADDJHVOLSIZE))
 fi
 if test $JHVOLSIZE = 0; then
  #JHVOLSIZE=10
  #echo "$RESP" | grep 'size'
  #JHVOLSIZE=$(echo "$RESP" | grep "^| *size *|" | sed -e "s/^| *size *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
  OR=$(ostackcmd_id size $GLANCETIMEOUT glance image-show $JHIMGID)
  read TM JHVOLSIZE <<<"$OR"
  JHVOLSIZE=$((($JHVOLSIZE/1024/1024+1023)/1024))
 fi
 OR=$(ostackcmd_id min_disk $GLANCETIMEOUT glance image-show $IMGID)
 if test $? != 0; then
  let APIERRORS+=1; sendalarm 1 "glance image-show failed" "" $GLANCETIMEOUT
 else
  read TM SZ <<<"$OR"
  VOLSIZE=$(($SZ+$ADDVMVOLSIZE))
 fi
 if test $VOLSIZE = 0; then
  #VOLSIZE=10
  #VOLSIZE=$(echo "$RESP" | grep "^| *size *|" | sed -e "s/^| *size *| *\([^|]*\).*\$/\1/" -e 's/ *$//')
  OR=$(ostackcmd_id size $GLANCETIMEOUT glance image-show $JHIMGID)
  read TM VOLSIZE <<<"$OR"
  VOLSIZE=$((($VOLSIZE/1024/1024+1023)/1024))
 fi
 let APICALLS+=2
 #echo "Image $IMGID $VOLSIZE $JHIMGID $JHVOLSIZE"; exit 0;
 if createRouters; then
  if createNets; then
   if createSubNets; then
    if createRIfaces; then
     if createSGroups; then
      createLBs;
      if createJHVols; then
       if createVIPs; then
        if createJHPorts; then
         if createVols; then
          if createKeypairs; then
           createPorts
           waitJHVols
           if createJHVMs; then
            let ROUNDVMS=$NOAZS
            waitVols
            if createVMs; then
             let ROUNDVMS+=$NOVMS
             waitJHVMs
             RC=$?
             if test $RC != 0; then
               # ERR+=$RC Errors will be counted later again
               sendalarm $RC "Timeout waiting for JHVM " "${RRLIST[*]}" $((4*$MAXWAIT))
               # FIXME: Shouldn't we count errors and abort here? Without JumpHosts, the rest is hopeless ...
               let ERR+=$RC
               if test $RC -gt $NOAZS; then let VMERRORS+=$NOAZS; else let VMERRORS+=$RC; fi
             else
              if createFIPs; then
               # loadbalancer
               waitLBs
               LBERR=$?
               # No error handling here (but alarms are generated)
               waitVMs
               if test $RC != 0; then
                 # Errors will be counted later again
                 sendalarm $RC "Timeout waiting for VM " "${RRLIST[*]}" $((4*$MAXWAIT))
               fi
               setmetaVMs
               create2ndSubNets
               create2ndPorts
               # Test JumpHosts
               # NOTE: Alarms and Grafana error logging are not fully aligned here
               testjhinet
               RC=$?
               # Retry
               if test $RC != 0; then echo "$ERR"; sleep 5; testjhinet; RC=$?; fi
               # Non-working JH breaks us ...
               if test $RC != 0; then
                 let VMERRORS+=$RC
                 sendalarm $RC "$ERR" "" 70
                 errwait $VMERRWAIT
                 # FIXME: Shouldn't we abort here?
                 echo "${BOLD}Aborting this deployment due to non-functional JH, clean up now ...${NORM}"
                 sleep 1
               else
                # Test normal hosts
                #setPortForward
                setPortForwardGen
                WSTART=$(date +%s)
                wait222
                WAITERRORS=$?
                # No need to send alarm yet, will do after testsnat
                #if test $WAITERRORS != 0; then
                #  sendalarm $RC "$ERR" "" $((4*$MAXWAIT))
                #  errwait $VMERRWAIT
                #fi
                testsnat
                RC=$?
                let VMERRORS+=$((RC/2))
                if test $RC != 0; then
                  sendalarm $RC "$ERR" "" $((4*$MAXWAIT))
                  errwait $VMERRWAIT
                fi
                # Attach and config 2ndary NICs
                config2ndNIC
                # Full connection test
                if test -n "$FULLCONN"; then
                  fullconntest
                  # Test for FPERR instead?
                  if test $FPERR -gt 0; then
                    sendalarm 2 "Connectivity errors" "$FPERR + $FPRETRY\n$ERR" 5
                    errwait $ERRWAIT
                  fi
                  if test -n "$SECONDNET" -a -n "$RESHUFFLE"; then
                    reShuffle
                    fullconntest
                    if test $FPERR -gt 0; then
                      sendalarm 2 "Connectivity errors" "$FPERR + $FPRETRY\n$ERR" 5
                      errwait $ERRWAIT
                    fi
                  fi
                fi
                # TODO: Create disk ... and attach to JH VMs ... and test access
                # TODO: Attach additional net interfaces to JHs ... and test IP addr
                # Test load balancer
                if test -n "$LOADBALANCER" -a $LBERR = 0; then testLBs; fi
                MSTOP=$(date +%s)
                WAITTIME+=($(($MSTOP-$WSTART)))
                echo -e "$BOLD *** SETUP DONE ($(($MSTOP-$MSTART))s), DELETE AGAIN $NORM"
                let SUCCRUNS+=1
                THISRUNSUCCESS=1
                if test $SUCCWAIT -ge 0; then sleep $SUCCWAIT; else echo -n "Hit enter to continue ..."; read ANS; fi
                # Refresh token if needed
                if test -n "$TOKENSTAMP" && test $(($(date +%s)-$TOKENSTAMP)) -ge 36000; then
                  getToken
                  TOKENSTAMP=$(date +%s)
                fi
                if test -n "$LOADBALANCER" -a $LBERR = 0; then cleanLBs; fi
                # Subtract waiting time (5s here)
                MSTART=$(($MSTART+$(date +%s)-$MSTOP))
               fi
               # TODO: Detach and delete disks again
              fi; deleteFIPs
             fi; #JH wait successful
            fi; deleteVMs
           fi; deleteJHVMs
          fi; deleteKeypairs
         fi; waitdelVMs; deleteVols
        fi; waitdelJHVMs
        #echo -e "${BOLD}Ignore port del errors; VM cleanup took care already.${NORM}"
        IGNORE_ERRORS=1
        delete2ndPorts
        #if test -n "$SECONDNET" -o -n "$MANUALPORTSETUP"; then deletePorts; fi
        #deletePorts; deleteJHPorts	# not strictly needed, ports are del by VM del
        unset IGNORE_ERRORS
       fi; deleteVIPs
      fi; deleteLBs
      deleteJHVols
     # There is a chance that some VMs were not created, but ports were allocated, so clean ...
     fi; cleanupPorts; deleteSGroups
    fi; deleteRIfaces
   fi; deleteSubNets
  fi; deleteNets
 fi
 # We may recycle the router
 if test $(($loop+1)) == $MAXITER -o $((($loop+1)%$ROUTERITER)) == 0; then deleteRouters; fi
 #echo "${NETSTATS[*]}"
 echo -e "$BOLD *** Cleanup complete *** $NORM"
 THISRUNTIME=$(($(date +%s)-$MSTART))
 # Only account successful runs for total runtime stats
 if test -n "$THISRUNSUCCESS"; then
   TOTTIME+=($THISRUNTIME)
 fi
 # Raise an alarm if we have not yet sent one and we're very slow despite this
 if test -n "$OPENSTACKTOKEN"; then
   if test -n "$BOOTALLATONCE"; then CON=400; NFACT=12; FACT=24; else CON=384; NFACT=12; FACT=36; fi
 else
   if test -n "$BOOTALLATONCE"; then CON=416; NFACT=16; FACT=24; else CON=400; NFACT=16; FACT=36; fi
 fi
 MAXCYC=$(($CON+($FACT+$NFACT/2)*$NOAZS+$NFACT*$NONETS+$FACT*$NOVMS))
 if test -n "$SECONDNET"; then let MAXCYC+=$(($NFACT*$NONETS+$NFACT*$NOVMS)); fi
 if test -n "$RESHUFFLE"; then let MAXCYC+=$((2*$NFACT*$NOVMS)); fi
 if test -n "$FULLCONN"; then let MAXCYC+=$(($NOVMS*$NOVMS/10)); fi
 # FIXME: We could check THISRUNSUCCESS instead?
 if test $VMERRORS = 0 -a $WAITERRORS = 0 -a $THISRUNTIME -gt $MAXCYC; then
    sendalarm 1 "SLOW PERFORMANCE" "Cycle time: $THISRUNTIME (max $MAXCYC)" $MAXCYC
    #waiterr $WAITERR
 fi
 allstats
 if test -n "$FULLCONN"; then CONNTXT="$CONNERRORS Conn Errors, "; else CONNTXT=""; fi
 if test -n "$LOADBALANCER"; then LBTXT="$LBERRORS LB Errors, "; else LBTXT=""; fi
 echo "This run: Overall $ROUNDVMS / ($NOVMS + $NOAZS) VMs, $APICALLS CLI calls: $(($(date +%s)-$MSTART))s, $VMERRORS VM login errors, $WAITERRORS VM timeouts, $APIERRORS API errors (of which $APITIMEOUTS API timeouts), $PINGERRORS Ping Errors, ${CONNTXT}${LBTXT}$(date +'%Y-%m-%d %H:%M:%S %Z')"
#else
#  usage
fi
let CUMAPIERRORS+=$APIERRORS
let CUMAPITIMEOUTS+=$APITIMEOUTS
let CUMVMERRORS+=$VMERRORS
let CUMLBERRORS+=$LBERRORS
let CUMPINGERRORS+=$PINGERRORS
let CUMWAITERRORS+=$WAITERRORS
let CUMCONNERRPRS+=$CONNERRORS
let CUMAPICALLS+=$APICALLS
let CUMVMS+=$ROUNDVMS
let RUNS+=1

if test -z "$OS_PROJECT_NAME"; then OPRJ="$OS_CLOUD"; else OPRJ="$OS_PROJECT_NAME"; fi

CDATE=$(date +%Y-%m-%d)
CTIME=$(date +%H:%M:%S)
if test -n "$FULLCONN"; then CONNTXT="$CUMCONNERRORS Conn Errors"; CONNST="|$CUMCONNERRORS"; else CONNTXT=""; CONNST=""; fi
if test -n "$LOADBALANCER"; then LBTXT="$CUMLBERRORS LB Errors"; LBST="|$CUMLBERRORS"; else LBTXT=""; LBST=""; fi
if test -n "$SENDSTATS" -a "$CDATE" != "$LASTDATE" || test $(($loop+1)) == $MAXITER; then
  sendalarm 0 "Statistics for $LASTDATE $LASTTIME - $CDATE $CTIME" "
$RPRE $VERSION on $HOSTNAME testing $STRIPLE:

$RUNS deployments ($SUCCRUNS successful, $CUMVMS/$(($RUNS*($NOAZS+$NOVMS))) VMs, $CUMAPICALLS CLI calls)
$CUMVMERRORS VM LOGIN ERRORS
$CUMWAITERRORS VM TIMEOUT ERRORS
$CUMAPIERRORS API ERRORS
$CUMAPITIMEOUTS API TIMEOUTS
$CUMPINGERRORS Ping failures
$CONNTXT
$LBTXT

$(allstats)

#TEST: $SHORT_DOMAIN|$VERSION|$RPRE|$HOSTNAME|$OPRJ|$OS_REGION_NAME
#STAT: $LASTDATE|$LASTTIME|$CDATE|$CTIME
#RUN: $RUNS|$SUCCRUNS|$CUMVMS|$((($NOAZS+$NOVMS)*$RUNS))|$CUMAPICALLS
#ERRORS: $CUMVMERRORS|$CUMWAITERRORS|$CUMAPIERRORS|$APITIMEOUTS|$CUMPINGERRORS$CONNST$LBST
$(allstats -m)
" 0
  echo "#TEST: $SHORT_DOMAIN|$VERSION|$RPRE|$HOSTNAME|$OPRJ|$OS_REGION_NAME
#STAT: $LASTDATE|$LASTTIME|$CDATE|$CTIME
#RUN: $RUNS|$CUMVMS|$CUMAPICALLS
#ERRORS: $CUMVMERRORS|$CUMWAITERRORS|$CUMAPIERRORS|$APITIMEOUTS|$CUMPINGERRORS$CONNST
$(allstats -m)" > Stats.$LASTDATA.$LASTTIME.$CDATE.$CTIME.psv
  TOTERR+=$(($CUMVMERRORS+$CUMAPIERRORS+$CUMAPITIMEOUTS+$CUMPINGERRORS+$CUMWAITERRORS+$CUMCONNERRORS))
  CUMVMERRORS=0
  CUMAPIERRORS=0
  CUMAPITIMEOUTS=0
  CUMPINGERRORS=0
  CUMWAITERRORS=0
  CUMCONNERRORS=0
  CUMAPICALLS=0
  CUMVMS=0
  LASTDATE="$CDATE"
  LASTTIME="$CTIME"
  RUNS=0
  SUCCRUNS=0
  # Reset stats
  NETSTATS=()
  FIPSTATS=()
  VOLSTATS=()
  NOVASTATS=()
  NOVABSTATS=()
  VOLCSTATS=()
  VOLDSTATS=()
  VMCSTATS=()
  LBCSTATS=()
  VMDSTATS=()
  TOTTIME=()
  WAITTIME=()
fi

# Clean up residuals, if any
if test $(($loop+1)) == $MAXITER -o $((($loop+1)%$ROUTERITER)) == 0; then waitnetgone; fi
#waitnetgone
let loop+=1
done
rm -f ${RPRE}Keypair_JH.pem ${RPRE}Keypair_VM.pem ~/.ssh/known_hosts.$RPRE ~/.ssh/known_hosts.$RPRE.old ${RPRE}user_data_JH.yaml ${RPRE}user_data_VM.yaml
if test "$REFRESHPRJ" != 0; then cleanprj; fi

exit $TOTERR
