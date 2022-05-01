# Dashboards for the openstack-health-monitor

The openstack-health-monitor has a capability to report the results (errors
and execution times) to a local telegraf. This can be used to feed the results
to an influxdb which can feed grafana for dashboards.

This directory contains configuration files that can be used to setup a local
telegraf, influxdb and grafana setup. Note that this is purely for demonstration
purposes. In real life, you want to containerize the setup, put an SSL terminating
reverse proxy (ingress) in front of the grafana and think a bit about user
management. In particular, you would not want to expose the grafana with the
default config here to the internet without changing the admin password (`SCS_Admin`)
and enabling SSL.

For demo purposes on the other hand, running everything in the same VM (even
without containers) can be done -- I use ssh port forwarding to access the
Grafana in the host that runs the openstack-health-monitor.
`ssh -f -L 3000:localhost:3000 linux@host sleep 10800`
to get 3 hours of Grafana access via localhost:3000 protected by the
ssh acceess controls.


