#!/bin/bash
# run_in_loop_garloff.sh
OS_CLOUD=${OS_CLOUD:-garloffcloud-test}
export OS_CLOUD
#export WAITLB=60
rm "$OS_CLOUD/stop-os-hm" 2>/dev/null
while true; do
	./run_garloff.sh -s -i 100
	if test -e "$OS_CLOUD/stop-os-hm"; then break; fi
	echo -n "Hit ^C to abort ..."
	sleep 15
	echo
done

