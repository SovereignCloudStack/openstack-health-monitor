# Dashboards for the openstack-health-monitor

The openstack-health-monitor has a capability to report the results (errors
and execution times) to a local telegraf. This can be used to feed the results
to an influxdb which can feed grafana for dashboards.

This directory contains configuration files that can be used to setup a local
telegraf, influxdb and grafana setup. Note that this is for demonstration
purposes. You can disable the SSL setup and just use it locally by doing
an ssh port-forward of port 3000.

The default config in grafana.ini needs some work to complete the SSL setup
by having a DNS resolvable hostname (you can get one on sovereignit.cloud
from the SCS project if you want) and generate a valid cert for it.
It also enables Viewer access for SovereignCloudStack org members on github.

## The config files

* `telegraf.conf` is a default config file for [telegraf](https://www.influxdata.com/time-series-platform/telegraf/)
  from openSUSE 15.3 with minimal edits to work for us. The relevant pieces here are the
  `inputs.influxdb_listener` (on `:8186`) and the `outputs.influxdb` (to `localhost:8086`).
* `config.toml` is the default config file for [influxdb](https://www.influxdata.com/time-series-platform/)
  from openSUSE 15.3 without any edits.
* `grafana.ini` is the default config file for [grafana](https://grafana.com/)
  from openSUSE 15.3 with the admin password changed to `SCS_Admin` and `allow_signup` set to `false`.
  The configuration is prepared to be exposed to the internet -- to do so, change the admin password,
  fill in a hostname that you control (or reach out to SCS for getting a registration on sovereignit.cloud),
  generate SSL certs (e.g. via Let's Encrypt) and put them to `/etc/grafana/health-fullchain.pem`
  and `health-key.pem`. Note that all github users that belong to the SovereignCloudStack org
  have Viewer access to the dashboards.
* `openstack-health-dashboard.json` contains the dashboard exported to JSON and is the one piece here
  that has received significant work. Screenshots from the dashboard can be seen below. You can import
  the dashboard -- you will also need to create a influxdb datasource connecting to `localhost:8086` to
  the `telegraf` database.

## Screenshots

![](oshm-grafana-gxscs-20220923-1.png)
![](oshm-grafana-gxscs-20220923-2.png)
