#!/bin/bash
# sap_978793.sh
# Testcase trying to reproduce the issue of bug 978793
# Creating a large number (30) of VMs, SAP HCP team observes API call timeouts
# (c) Kurt Garloff <kurt.garloff@t-systems.com>, 2/2017
# License: CC-BY-SA (2.0)
#
# General approach:
# - create VPC (router)
# - create two subnets
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


DATE=`date +s`
LOGFILE=sap_978793-$DATE.log
NUMVM=30
if test "$1" = "-n"; then NUMVM=$2; shift; shift; fi
if test "$1" = "-l"; then LOGFILE=$2; shift; shift; fi
if test "$1" = "help" -o "$1" = "-h"; then usage; fi


