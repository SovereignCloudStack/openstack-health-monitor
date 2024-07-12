#!/bin/bash
rm stop-os-hm 2>/dev/null
while true; do
  ./run_poc-wgcloud.sh -i 50
  if test -e stop-os-hm; then break; fi
  echo -n "Hit ^C to abort ..."
  sleep 30; echo
done
