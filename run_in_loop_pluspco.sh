#!/bin/bash
# run_in_loop_pluspco.sh
#export WAITLB=60
rm stop-os-hm 2>/dev/null
while true; do
	./run_pluspco.sh -s -i 200
	if test -e stop-os-hm; then break; fi
	echo -n "Hit ^C to abort ..."
	sleep 15
	echo
done

