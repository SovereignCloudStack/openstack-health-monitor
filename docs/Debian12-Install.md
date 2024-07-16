# Guide: Setting up openstack-health-monitor on Debian 12
Kurt Garloff, 2024-02-20

## Intro
The development of [openstack-health-monitor](https://github.com/SovereignCloudStack/openstack-health-monitor/) was done on [openSUSE 15.x images](https://kfg.images.obs-website.eu-de.otc.t-systems.com/), just because the author is very familiar with it and has some of the needed tools preinstalled. That said, the setup is not depending on anything specific from openSUSE and should work on every modern Linux distribution.

Setting it up again in a different environment using Debian 12 images avoids a few of the shortcuts that were used and thus should be very suitable instructions to get it working in general. The step by step instructions are covered here.

Note: This is a rather classical snowflake setup -- we create a VM and do some manual configuration to get everything configured. Having it well documented here should make this more replicatable, and is an important precondition for more automation, but larger steps to full automate this using ansible or helm charts (in a containerized variant) are not addressed here. As we expect a [successor project](https://github.com/SovereignCloudStack/scs-health-monitor) for the increasingly hard to maintain shell code, this may not be worth the trouble.

openstack-health-monitor implements a scripted scenario test with a large shell-script that uses the openstackclient tools to set up the scenario, test it and tear everything down again in a loop. Any errors are recorded, as well as timings and some very basic benchmarks. The script sets up some virtual network infrastructure (routers, networks, subnets, floating IPs), security groups, keypairs, volumes and finally boots some VMs. Access to these is tested (ensuring metadata injection works) and connectivity between them tested and measured. A loadbalancer (optionally) is set up with a health-monitor and access via it before and after killing some backends is tested.
The scenario is described in a bit more detail in the [repository's README.md](https://github.com/SovereignCloudStack/openstack-health-monitor/blob/main/README.md) file.

The openstack-health-monitor is not the intended long-term solution for monitoring your infrastructure. The SCS project has a project underway that will create more modern, flexible, and more maintainable monitoring infrastructure; the concepts are described on the [monitoring section](https://docs.scs.community/docs/category/monitoring) of the project's documentation. The openstack-health-monitor will thus not see any significant enhancements any more; it will be maintained and kept alive as long as there are users. This guide exclusively focuses on how to set it up.

## Setting up the driver VM

So we start a `Debian 12` image on a cloud of our choice. This should work on any OpenStack cloud that is reasonably standard;
the instructions use flavor names and image names from the SCS standards.
For many, the simplest way may be to use the Web-UI of their cloud (e.g. horizon for OpenStack).

### Internal vs external monitoring

There are pros and cons to run the driver VM in the same cloud that is also under test. We obviously don't test the external reachability of the cloud (more precisely its API endpoints and VMs) if we run it on the same cloud -- which may or may not be desirable. Having the tests happily continuing to collect data  may actually be valuable in times when external access is barred. If the cloud goes down, we will no longer see API calls against it, although the information of them not being available does not reveal much in terms of insight into the reasons for the outage. Also, the driver VM is the only long-lived VM in the openstack-health-monitor setup, so it may be useful to have it in the same cloud to reveal any issues that do not occur on the short-lived resources created and deleted by the health-monitor.

The author tends to see running it internally as advantageous -- ideally combined with a simple API reachability test from the outside that sends alarms as needed to detect any reachability problems.

### Unprivileged operation

Nothing in this test requires admin privileges on the cloud where the driver runs nor on the cloud under test. We do install and configure a few software packages in the driver VM, which requires sudo power there, but the script should just run as a normal user. For the cloud under test it is recommended to use a user (or an application credential) with a normal tenant member role to access the cloud under test. If you can, give it an OpenStack project on its own.

If `openstack availability zone list --compute` fails for you without admin rights, please fix your openstack client, e.g. by applying the [patch](https://raw.githubusercontent.com/SovereignCloudStack/openstack-health-monitor/main/docs/openstackclient-az-list-fallback-f3207bd.diff) I mentioned in [this issue](https://storyboard.openstack.org/#!/story/2010989). (Versions 6.3.0 and 6.4.0 are broken.) Do not consider giving the OpenStack Health-Monitor admin power. (Note: It has a workaround for the broken AZ listing using curl now.)

### Driver VM via openstack CLI

The author prefers to setup the VM via `openstack` CLI tooling. He has working entries for all clouds he uses in his `~/.config/openstack/clouds.yaml` and `secure.yaml` and has exported the `OS_CLOUD` environment variable to point to the cloud he is working on to set up the driver VM. The author uses the `bash` shell. All of this of course could be scripted.

So here we go

1. Create the network setup for a VM in a network `oshm-network` with an IPv4 subnet, connected to a router that connects (and by default SNATs) to the public network.
```
PUBLIC=$(openstack network list --external -f value -c Name)
openstack router create oshm-router
openstack router set --external-gateway $PUBLIC oshm-driver-router
openstack network create oshm-network
openstack subnet create --subnet-range 192.168.192.0/24 --network oshm-network oshm-subnet
openstack router add subnet oshm-router oshm-subnet
```

2. Create a security group that allows ssh and ping access
```
openstack security group create sshping
openstack security group rule create --ingress --ethertype ipv4 --protocol tcp --dst-port 22 sshping
openstack security group rule create --ingress --ethertype ipv4 --protocol icmp --icmp-type 8 sshping
```

3. Being at it, we also create the security group for grafana
```
openstack security group create grafana
openstack security group rule create --ingress --ethertype ipv4 --protocol tcp --dst-port 3000 grafana
```

4. To connect to the VM via ssh later, we create an SSH keypair
```
openstack keypair create --private-key ~/.ssh/oshm-key.pem oshm-key
chmod og-r ~/.ssh/oshm-key.pem 
```
Rather than creating a new key (and storing and protecting the private key), we could have passed `--public-key` and used an existing keypair.

5. Look up Debian 12 image UUID.
```
IMGUUID=$(openstack image list --name "Debian 12" -f value -c ID | tr -d '\r')
echo $IMGUUID
```
Sidenote: The `tr` command is there to handle broken tooling that embeds a trailing `\r` in the output.

6. Boot the driver VM
```
openstack server create --network oshm-network --key-name oshm-key --security-group default --security-group sshping --security-group grafana --flavor SCS-2V-4 --block-device boot_index=0,uuid=$IMGUUID,source_type=image,volume_size=10,destination_type=volume,delete_on_termination=true oshm-driver
```
Chose a flavor that exists on your cloud. Here we have used  one without root disk and asked nova to create a volume on the fly by passing `--block-device`. See [diskless flavor blog article](https://scs.community/2023/08/21/diskless-flavors/). For flavors with local root disks, you could have used the `--image $IMGUUID` parameter instead.

7. Wait for it to boot (optional)
You can look at the boot log with `openstack console log show oshm-driver` or connect to it via VNC at the URL given by `openstack console url show oshm-driver`. You can of course also query openstack on the status `openstack server list` or `openstack server show oshm-driver`. You can also just create a simple loop:
```
declare -i ctr=0 RC=0
while [ $ctr -le 120 ]; do
  STATUS="$(openstack server list --name oshm-driver -f value -c Status)"
  if [ "$STATUS" = "ACTIVE" ]; then echo "$STATUS"; break; fi 
  if [ "$STATUS" = "ERROR" ]; then echo "$STATUS"; RC=1; break; fi
  if [ -z "$STATUS" ]; then echo "No such VM"; RC=2; break; fi
  sleep 2
  let ctr+=1
done
# return $RC
if [ $RC != 0 ]; then false; fi
```

8. Attach a floating IP so it's reachable from the outside.
```
FIXEDIP=$(openstack server list --name oshm-driver -f value -c Networks |  sed "s@^[^:]*:[^']*'\([0-9\.]*\)'.*\$@\1@")
FIXEDPORT=$(openstack port list --fixed-ip ip-address=$FIXEDIP,subnet=oshm-subnet -f value -c ID)
echo $FIXEDIP $FIXEDPORT
openstack floating ip create --port $FIXEDPORT $PUBLIC
FLOATINGIP=$(openstack floating ip list --fixed-ip-address $FIXEDIP -f value -c "Floating IP Address")
echo "Floating IP: $FLOATINGIP"
```
Remember this floating IP address.

9. Connect to it via ssh
```
ssh -i ~/.ssh/oshm-key.pem debian@$FLOATINGIP
```
On the first connection, you need to accept the new ssh host key. (Very careful people would compare the fingerprint with the console log output.)

**All the following commands are performed on the newly started driver VM.**

### Configuring openstack CLI on the driver VM

We need to install the openstack client utilities.
```
sudo apt-get update
sudo apt-get install python3-openstackclient
sudo apt-get install python3-cinderclient python3-octaviaclient python3-swiftclient python3-designateclient
```

Configure your cloud access in `~/.config/openstack/clouds.yaml`
```yaml
clouds:
  CLOUDNAME:
    interface: public
    identity-api-version: 3
    #region_name: REGION
    auth:
      auth_url: KEYSTONE_ENDPOINT
      project_id: PROJECT_UUID
      #alternatively project_name and project_domain_name
      user_domain_name: default
      # change to your real domain
```
and `secure.yaml` (in the same directory)
```yaml
clouds:
  CLOUDNAME:
    auth:
      username: USERNAME
      password: PASSWORD
```
The `CLOUDNAME` can be freely chosen. This is the value passed to the openstack CLI with `--os-cloud` or exported to your environment in `OS_CLOUD`. The other uppercase words need to be adjusted to match your cloud. Hint: horizon typically lets you download a sample `clouds.yaml` file that works (but lacks the password).

Protect your `secure.yaml` from being read by others: `chmod 0600 ~/.config/openstack/secure.yaml`.

If you are using application credentials instead of username, password to authenticate, you don't need to specify `project_id` nor project's nor user's domain names in `clouds.yaml`. Just (in `secure.yaml`):
```yaml
clouds:
  CLOUDNAME:
    auth_type: v3applicationcredential
    auth:
      application_credential_id: APPCRED_ID
      application_credential_secret: "APPCRED_SECRET"
```

Configure this to be your default cloud:
```bash
export OS_CLOUD=CLOUDNAME
```
You might consider adding this to your `~/.bashrc` for convenience. Being at it, you might want to add `export CLIFF_FIT_WIDTH=1` there as well to make openstack command output tables more readable (but sometimes less easy to cut'n'paste).

Verify that your openstack CLI works:
```
openstack catalog list
openstack server list
```

You can use the same project as you use for your driver VM (and possibly other workloads). The openstack-health-monitor is carefully designed to not clean up anything that it has not created. There is however some trickiness, as not all resources have names (floating IPs for example do not) and sometimes names need to be assigned after creation of a resource (volumes of diskless flavors), so in case there are API errors, some heuristics is used to identify resources which may not be safe under all circumstances. So ideally, you have an extra project created just for the health-monitor and configure the credentials for it here, so you can not possibly hit any wrong resource in the script's extensive efforts to clean up in error cases.

### Custom CA

If your cloud API's endpoints don't use TLS certificates that are signed by an official CA, you need to provide your CA to this VM and configure it. (On a SCS Cloud-in-a-Box system, you find it on the manager node in `/etc/ssl/certs/ca-certificates.crt`. You may extract the last cert or just leave them all together.) Copy the CA file to your driver VM and ensure it's readable by the `debian` user.

Add it to your `clouds.yaml`
```
clouds:
  CLOUDNAME:
    cacert: /PATH/TO/CACERT.CRT
    [...]
```

If you want to allow `api_monitor.sh` to be able to talk to the service endpoints directly to avoid getting a fresh token from keystone for each call, you also need to export it to your environment:
```bash
export OS_CACERT=/PATH/TO/CACERT.CRT
```
Consider adding this to your `~/.bashrc` as well.

## Your first `api_monitor.sh` iteration

Checkout openstack-health-monitor:
```bash
sudo apt-get install git bc jq netcat-traditional tmux zstd
git clone https://github.com/SovereignCloudStack/openstack-health-monitor
cd openstack-health-monitor
```

You may want to start a `tmux` (or `screen`) session now, so you can do multiple things in parallel (e.g. for debugging) and reconnect.

The script `api_monitor.sh` is the main worker of openstack-health-monitor and runs one to many iterations of a cycle where resources are created, tested and torn down. Its operation is described in the [README.md](https://github.com/SovereignCloudStack/openstack-health-monitor/blob/main/README.md) file.

It is good practice to use `tmux`. This allows you to return (reattach) to console sessions and to open new windows to investigate things. Traditional people may prefer to `screen` over `tmux`.

You should be ready to run one iteration of the openstack-health-monitor now. Run it like this:
```bash
export IMG="Debian 12"
export JHIMG="Debian 12"
./api_monitor.sh -O -C -D -n 6 -s -b -B -M -T -LL -i 1
```
Leave out the `-LL` if you don't have a working loadbalancer service or replace `-LL` with `-LO` if you want to test the ovn loadbalancer instead of amphorae (saving quite some resources).

Feel free to study the meaning of all the command line parameters by looking at the [README.md](https://github.com/SovereignCloudStack/openstack-health-monitor/blob/main/README.md). (Note: Many of the things enabled by the parameters should be default, but are not for historic reasons. This would change if we rewrite this whole thing in python.)

This will run for ~7 minutes, depending on the performance of your OpenStack environment. You should not get any error. (The amber-colored outputs `DOWN`, `BUILD`, `creating` are not errors. Nothing in red should be displayed.) Studying the console output may be instructive to follow the script's progress. You may also open another window (remember the tmux recommendation above) and look at the resources with the usual `openstack RESOURCE list` and `openstack RESOURCE show NAME` and `RESOURCE` being something like `router`, `network`, `subnet`, `port`, `volume`, `server`, `floating ip`, `loadbalancer`, `loadbalancer pool`, `loadbalancer listener`, `security group`, `keypair`, `image`, ...)

The `api_monitor.sh` uses and `APIMonitor_TIMESTAMP` prefix for all OpenStack resource names. This allows to identify the created resources and clean them up even if things go wrong.
`TIMESTAMP` is an integer number representing the seconds after 1970-01-01 00:00:00 UTC (Unix time). 

This may be the time to check that you have sufficient quota to create the resources. While we only create 6+N VMs (and volumes) with the above call (N being the number of AZs), we would want to increase this number for larger clouds. For single-AZ deployments, we would want to still use 2 networks at least `-N 2` to test the ability of the router to route traffic between networks. So expect `-n 6` to become `-N 2 -n 6` for a very small single-AZ cloud or `-n 12` for a large 3 AZ cloud region. So, re-run the `api_monitor.sh` with the target sizing.

### Resource impact and charging

Note that `api_monitor.sh` uses small flavors (`SCS-1V-2` for the N jump hosts and `SCS-1L-1` for the other VMs) to keep the impact on your cloud (and on your invoice if you are not monitoring your own cloud) small. You can change the flavors.

If you have to pay for this, also consider that some clouds are not charging by the minute but may count by the started hour. So when you run `api_monitor.sh` in a loop (which you will) with say 10 VMs (e.g. `-N 2 -n 8`) in each iteration and run this for an hour with 8 iterations, you will never have more than 10 VMs in parallel and they only are alive a bit more than half of the time, but rather than being charged for ~6 VM hours, you end up being charged for ~80 VM hours. Similar for volumes, routers, floating IPs. This makes a huge difference.

Sometimes the cloud under test has issues. That's why we do monitoring ... One thing that might happen is that loadbalancers and volumes (and other resources, but those two are the most prone to this) end up in a broken state that can not be cleaned up by the user any more. Bad providers may charge for these anyhow, although this will never stand a legal dispute. (IANAL, but charging for providing something that is not working is not typically supported by civil law in most jurisdictions and T&Cs that would say so would not normally be legally enforceable.) If this happens, I recommend to keep records of the broken state (store the output of `openstack volume list`, `openstack volume show BROKEN_VOLUME`, `openstack loadbalancer list`, `openstack loadbalancer show BROKEN_LB`.)

Using `-w -1` makes `api_monitor.sh` wait for interactive input whenever an error occurs; this can be convenient for debugging.

Once you have single iterations working nicely, we can proceed.

## Automating startup and cleanup
Typically, we run `api_monitor.sh` with a limited amount of iterations (200) and then restart it. For each restart, we also output some statistics, compress the log file and look at any leftovers that did not get cleaned up. The latter happens in the start script that we create here.

```
#!/bin/bash
# run_CLOUDNAME.sh
# Do some global settings
export IMG="Debian 12"
export JHIMG="Debian 12"
#export OS_CACERT=/home/debian/ca-certificates.pem
# Additional settings to override flavors or to
# configure email addresses for sending alarms can be set here

# Does openstack CLI work?
openstack server list >/dev/null || exit 1
# Upload log files to this swift container (which you need to create)
#export SWIFTCONTAINER=OS-HM-Logfiles

# CLEANUP
echo "Finding resources from previous runs to clean up ..."
# Find Floating IPs
FIPLIST=""
FIPS=$(openstack floating ip list -f value -c ID)
for fip in $FIPS; do
        FIP=$(openstack floating ip show $fip | grep -o "APIMonitor_[0-9]*")
        if test -n "$FIP"; then FIPLIST="${FIPLIST}${FIP}_
"; fi
done
FIPLIST=$(echo "$FIPLIST" | grep -v '^$' | sort -u)
# Cleanup previous interrupted runs
SERVERS=$(openstack server  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
KEYPAIR=$(openstack keypair list | grep -o "APIMonitor_[0-9]*_" | sort -u)
VOLUMES=$(openstack volume  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
NETWORK=$(openstack network list | grep -o "APIMonitor_[0-9]*_" | sort -u)
LOADBAL=$(openstack loadbalancer list | grep -o "APIMonitor_[0-9]*_" | sort -u)
ROUTERS=$(openstack router  list | grep -o "APIMonitor_[0-9]*_" | sort -u)
SECGRPS=$(openstack security group list | grep -o "APIMonitor_[0-9]*_" | sort -u)
echo CLEANUP: FIPs $FIPLIST Servers $SERVERS Keypairs $KEYPAIR Volumes $VOLUMES Networks $NETWORK LoadBalancers $LOADBAL Routers $ROUTERS SecGrps $SECGRPS
for ENV in $FIPLIST; do
  echo "******************************"
  echo "CLEAN $ENV"
  bash ./api_monitor.sh -o -T -q -c CLEANUP $ENV
  echo "******************************"
done
TOCLEAN=$(echo "$SERVERS
$KEYPAIR
$VOLUMES
$NETWORK
$LOADBAL
$ROUTERS
$SECGRPS
" | grep -v '^$' | sort -u)
for ENV in $TOCLEAN; do
  echo "******************************"
  echo "CLEAN $ENV"
  bash ./api_monitor.sh -o -q -LL -c CLEANUP $ENV
  echo "******************************"
done

# Now run the monitor
#exec ./api_monitor.sh -O -C -D -N 2 -n 6 -s -M -LO -b -B -a 2 -t -T -R -S ciab "$@"
exec ./api_monitor.sh -O -C -D -N 2 -n 6 -s -M -LO -b -B -T "$@"
```
Compared to the previous run, we have explicitly set two networks here `-N 2` and rely on the iterations being passed in as command line arguments. Add parameter `-t` if your cloud is slow to increase timeouts. We have enabled the ovtavia loadbalancer (`-LO`) in this example rather than the amphora based one (`-LL`).

You may use one of the existing `run_XXXX.sh` scripts as example. Beware: eMail alerting with `ALARM_EMAIL_ADDRESS` and `NOTE_EMAIL_ADDRESS` (and limiting with `-a` and `-R` ) and reporting data to telegraf (option `-S`) may be present in the samples. Make this script executable (`chmod +x run_CLOUDNAME.sh`).

We wrap a loop around this in `run_in_loop.sh`:
```
#!/bin/bash
# run_in_loop.sh
rm stop-os-hm 2>/dev/null
while true; do
  ./run_CLOUDNAME.sh -i 200
  if test -e stop-os-hm; then break; fi
  echo -n "Hit ^C to abort ..."
  sleep 15; echo
done
```

Also make this executable (`chmod +x run_in_loop.sh`).
To run this automatically in a tmux window whenever the system starts, we follow the steps in the [startup README.md](https://github.com/SovereignCloudStack/openstack-health-monitor/blob/main/startup/README.md)

Change `OS_CLOUD` in `startup/run-apimon-in-tmux.sh`. (If you need to set `OS_CACERT`, also add it in this file and pass it into the windows.)

Activate everything:
```
mkdir -p ~/.config/systemd/user/
cp -p startup/apimon.service ~/.config/systemd/user/
systemctl --user enable apimon
systemctl --user start apimon
sudo loginctl enable-linger debian
tmux attach oshealthmon
```

This assumes that you are using the user `debian` for this monitoring and have checked out the repository at `~/openstack-health-monitor/`. Adjust the paths and user name otherwise. (If for whatever reason you have chosen to install things as root, you will have to install the systemd service unit in the system paths and ensure it's not started too early in the boot process.)

### Changing parameters and restarting

If you want to change the parameters passed to `api_monitor.sh`, you best do this by editing `run_CLOUDNAME.sh`, potentially after testing it with one iteration before.

To make the change effective, you can wait until the current 200 iterations are completed and the `run_in_loop.sh` calls `run_CLOUDNAME.sh` again. You can also hit `^C` in the tmux window that has`api_monitor.sh` running. The script will then exit after the current iteration. Note that sending this interrupt is handled by the script, so it does still continue the current iteration and do all the cleanup work. However, you may interrupt an API call and thus cause a spurious error (which may in the worst case lead to a couple more spurious errors). If you want to avoid this, hit `^C` during the wait/sleep phases of the script (after having done all the tests or after having completed the iteration). If you hit `^C` twice, it will abort the the current iteration, but still try to clean up. Then the outer script will also exit and you have to restart by manually calling `./run_in_loop.sh` again.

You can also issue the `systemctl --user stop apimon` command; it will basically do the same thing: Send `^C` and then wait for everything to be completed and tear down the tmux session.
After waiting for that to complete, you can start it again with `systemctl --user start apimon`.

### Multiple instances

You can run multiple instances of `api_monitor.sh` on the same driver VM. In this case, you should rename `run_in_loop.sh` to e.g. `run_in_loop_CLOUDNAME1.sh` and call `run_CLOUDNAME1.sh` from there. Don't forget to adjust `startup/run-apimon-in-tmux.sh` and `startup/kill-apimon-in-tmux.sh` to start more windows. 

It is not recommended to run multiple instances against the same OpenStack project however. While the `api_monitor.sh` script carefully keeps track of its own resources and avoids to delete things it has not created, this is not the case for the `run_CLOUDNAME.sh` script, which is explicitly meant to identify anything in the target project that was created by a health monitor and clean it up. If it hits the resources that are currently in use by another health mon instance, this will create spurious errors. This will happen every ~200 iterations, so you could still have some short-term coexistence when you are performing debug operations.

## Alarming and Logs
### eMail
If wanted, the `api_monitor.sh` can send statistics and error messages via email, so operator personnel is informed about the state of the monitoring. This email notification service potentially results in many emails; one error may produce several mails. So in case of a systematic problem, expect to receive dozens of mails per hour. This can be reduced a bit using the `-a N` and `-R` options. In order to enable sending emails from the driver VM, it needs to have `postfix` (or another MTA) installed and configured and outgoing connections for eMail need to be allowed. Note that many operators prefer not to use the eMail notifications but rather rely on looking at the dashboards (see further down) regularly.

Once you have configured `postfix`, you can enable eMail notifications using the option `-e`. Using it twice allows you to differentiate between notes (statistical summaries) and errors. If you want to send mails to more than one recipient, you can do so by passing `ALARM_EMAIL_ADDRESSES` and `NOTE_EMAIL_ADDRESSES` environment variables to `api_monitor.sh`, e.g. by setting it in the `run_CLOUDNAME.sh`.

### Log files
`api_monitor.sh` writes a log file with the name `APIMonitor_TIMESTAMP.log`. It contains a bit of information to see the progress of the script; more importantly, it logs every single openstack CLI call along with parameters and results. (`TIMESTAMP` is the Unix time, i.e. seconds since 1970-01-01 00:00:00 UTC.)

Note that `api_monitor.sh` does take some care not to expose secrets -- since v1.99, it does also redact issued tokens (which would otherwise give you up to 24hrs of access). But the Log files still may contain moderately sensitive information, so we suggest to not share it with untrusted parties.

The log file is written to the file system. After finishing the 200 iterations, the log file is compressed. If the environment variable `SWIFTCONTAINER` has been set (in `run_COULDNAME.sh`) when starting `api_monitor.sh`. the log file will be uploaded to a container with that name if it exists and if the swift object storage service is supported by the cloud. So create the container (a bucket in S3 speak) before if you want to use this: `export SWIFTCONTAINER=OSHM_Logs; openstack container create $SWIFTCONTAINER`

After the 200 iterations, a `.psv` file (pipe-separated values) is created `Stats.STARTTIME-ENDTIME.psv` (with times as calendar dates) which contains a bit of statistics on the last 200 iterations. This one will also be uploaded to $SWIFTCONTAINER (if configured).

## Data collection and dashboard
See https://github.com/SovereignCloudStack/openstack-health-monitor/blob/main/dashboard/README.md

### telegraf
To install telegraf on Debian 12, we need to add the apt repository provided by InfluxData:
```bash
sudo curl -fsSL https://repos.influxdata.com/influxdata-archive_compat.key -o /etc/apt/keyrings/influxdata-archive_compat.key
echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive_compat.key] https://repos.influxdata.com/debian stable main" | sudo tee /etc/apt/sources.list.d/influxdata.list
sudo apt update
sudo apt -y install telegraf
```

In the config file `/etc/telegraf/telegraf.conf`, we enable
```
[[inputs.influxdb_listener]]
  service_address = ":8186"

[[outputs.influxdb]]
  urls = ["http://127.0.0.1:8086"]
```
and restart the service (`sudo systemctl restart telegraf`).
Enable it on system startup: `sudo systemctl enable telegraf`.

### influxdb

We proceed to influxdb:
```
sudo apt-get install influxdb
```
In the configuration file `/etc/influxdb/influxdb.conf`, ensure that the http interface on port 8086 is enabled.
```
[http]
  enabled = true
  bind-address = ":8086"
```
Restart influxdb as needed with `sudo systemctl restart influxdb`.
Also enable it on system startup: `sudo systemctl enable influxdb`.

### Add `-S CLOUDNAME` to your `run_CLOUDNAME.sh` script

You need to tell the monitor that it should send data via telegraf to influxdb by adding the parameter `-S CLOUDNAME` to the `api_monitor.sh` call in `run_CLOUDNAME.sh`. Restart it (see above) to make the change effective immediately (and not only after 200 iterations complete).

### Grafana

#### Install Grafana

We follow https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/ and setup the stable APT repository:

```shell
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | sudo tee -a /etc/apt/sources.list.d/grafana.list
```

And install it:

```shell
sudo apt update
sudo apt -y install grafana
```

#### Basic config

The config file `/etc/grafana/grafana.ini` needs some adjustments.

We're going to deploy Grafana behind a reverse proxy (Caddy) and configure it as such.

Therefore, in the `[server]` section:

```ini
[server]
protocol = http
http_addr = 127.0.0.1
http_port = 3003
domain = health.YOURCLOUD.sovereignit.cloud
root_url = https://%(domain)s:3000/
```

Please replace `health.YOURCLOUD.sovereignit.cloud` with your actual domain.
You can use a hostname of your liking, but we will need to create TLS certificates for this host.
The `sovereignit.cloud` domain is controlled by the SCS project team and has been used for a number
of health mon instances.

Next, in the `[security]` section, set:

```ini
[security]
admin_user = admin
admin_password = SOME_SECRET_PASS
secret_key = SOME_SECRET_KEY
data_source_proxy_whitelist = localhost:8088 localhost:8086
cookie_secure = true
```

Please replace `SOME_SECRET_PASS` and `SOME_SECRET_KEY` with secure passwords (for example, you can use `pwgen -s 20`).

Finally, in the `[users]` section, set:

```ini
[users]
allow_sign_up = false
allow_org_create = false
```

We do the OIDC connection in the section `[auth.github]` later.

We can now restart the service: `sudo systemctl restart grafana-server`.
Being at it, also enable it on system startup: `sudo systemctl enable grafana-server`.

You should now be able to access your dashboard on `https://health.YOURCLOUD.sovereignit.de:3000` and log in via the configured username `admin` and your `SOME_SECRET_PASS` password.

#### Enable influx database in grafana

In the dashboard, go to Home, Connections, choose InfluxDB and Add new datasource. The defaults (database name, InfluxQL query language) work. You need to explicitly set the URL to `http://localhost:8086` (despite this being the suggestion). Set the database name to `telegraf`. Save&test should succeed.

#### Importing the dashboard

Go to Home, Dashboards, New, Import.
Upload the dashboard [.json file](https://github.com/SovereignCloudStack/openstack-health-monitor/blob/main/dashboard/openstack-health-dashboard.json) from the repository, user the [Grafana-10 variant](https://github.com/SovereignCloudStack/openstack-health-monitor/blob/main/dashboard/openstack-health-dashboard-10.json) if you use Grafana 10 or newer.

In the dashboard, go to the settings gear wheel, variables, mycloud and add CLOUDNAME to the list of clouds that can be displayed. (There are some existing SCS clouds in that list.)
Save.

Now choose CLOUDNAME as cloud (top of the dashboard, rightmost dropdown for the mycloud filter variable).

#### No data displayed?

Sometimes, you may see a panel displaying "no data" despite the fact that the first full iteration of data has been sent to influx already. This may be a strange interaction between the browser and Grafana -- we have not analyzed whether that is a bug in Grafana.

One way to work around is to go into the setting of the panel (the three dots in the upper right corner), go to edit and start changing one aspect of the query. Apply. Change it back to the original. Apply. The data will appear. Save to be sure it's conserved.

#### Dashboard features

Look at the top line filters: You can filter to only see certain API calls or certain resources; the graphs are very crowded and filtering to better see what you want to focus on is very well intended.

The first row of panels give a health impression; there are absolute numbers as well as percentage numbers and the panels turn amber and red in case you have too many errors. Note that the colors on the panels with absolute numbers can not take into account whether you look at just a few hours or at weeks. Accordingly, consider the colors a reasonable hint if things are green or not when looking at a ~24 hours interval. This limitation does not affect the colors on the percentage graph, obviously.

You can change the time interval and zoom in also by marking an interval with the mouse. Zooming out to a few months can be a very useful feature to see trends and watch e.g. your API performance, your resource creation times or the benchmarks change over the long term.

#### github OIDC integration

The SCS providers do allow all github users that belong to the SovereignCloudStack organization to get Viewer access to the dashboards by adding a `client_id` and `client_secret` in the ``[auth.github]`` section that you request from the SCS github admins (github's oauth auth). This allows to exchange experience and to get a feeling for the achievable stability. (Hint: A single digit number of API call fails per week and no other failures is achievable on loaded clouds.)

## Alternative approach to install and configure the dashboard behind a reverse proxy

Install influxdb via apt: https://docs.influxdata.com/influxdb/v1/introduction/install/#installing-influxdb-oss
Install telegraf (same apt repo as influxdb): `sudo apt update && sudo apt install telegraf`
Install grafana: https://grafana.com/docs/grafana/latest/setup-grafana/installation/debian/#install-from-apt-repository

Prepare configuration by using the config files from the repository as an alternative to doing the changes manually (as described above):
```
sudo cp dashboard/telegraf.conf /etc/telegraf && sudo chown root:root /etc/telegraf/telegraf.conf && sudo chmod 0644 /etc/telegraf/telegraf.conf
sudo cp dashboard/config.toml /etc/influxdb && sudo chown root:influxdb /etc/influxdb/config.toml && sudo chmod 0640 /etc/influxdb/config.toml
sudo cp dashboard/grafana.ini /etc/grafana && sudo chown root:grafana /etc/grafana/grafana.ini && sudo chmod 0640 /etc/grafana/grafana.ini
```
These config files should work as long as the versions of telegraf, influxdb and grafana don't evolve too far from the ones used in the repository. (Otherwise refer to above instructions how to tweak the default config files.)

Changes to `/etc/grafana/grafana.ini` as we do tls termination at the reverse proxy:
- set `protocol = http`
- comment out `domain` option (? FIXME) or set it to the hostname
- comment out `cert_*` options

Also change the admin password in `grafana.ini`.

Changes to `/etc/grafana/grafana.ini` if github auth should not be used yet:
- comment out whole `[auth.github]` section for now (can be enabled later)

Restart services: `sudo systemctl restart telegraf && sudo systemctl restart influxdb && sudo systemctl restart grafana-server`

Configuration in grafana web gui:
- Login to grafana `http(s)://<domain>:3000` with user admin and default password from `/etc/grafana/grafana.ini` and change password.
- Create influxdb datasource with url `http://localhost:8086` and database name `telegraf`.
- Finally import dashboard `dashboard/openstack-health-dashboard.json` to grafana.

TODO:
* Reverse proxy (aka ingress) with Let's Encrypt cert
* Github auth as described above

## Maintenance

The driver VM is a snowflake: A manually set up system (unless you automate all the above steps, which is possible of course) that holds data and is long-lived. As such it's important to be maintained.

### Unattended upgrades

It is recommended to ensure maintenance updates are deployed automatically. These are unlikely to negatively impact the openstack-health-monitor. See https://wiki.debian.org/UnattendedUpgrades. If you decide against unattended upgrades, it is recommended to install updates manually regularly and especially watch out for issues that affect the services that are exposed to the world: sshd (port 22) and grafana (port 3000).

### Updating openstack-health-monitor

You can just do a `git update` in the `openstack-health-monitor` directory to get the latest improvements. Note that these will only become effective after the 200 iterations have completed. You can speed this up by injecting a `^C`, see above in the restart section.

### Backup

The system holds two things that you might consider valuable for long-term storage:
(1) The log files. These are compressed and uploaded to object storage if you enable the `SWIFTCONTAINER` setting, which probably means that these do not need any additional backing up then.
(2) The influx time series data. Back up the data in `/var/lib/influxdb`.

Obviously, if you want to recover quickly from a crash, you might consider to also back up telegraf, influx and grafana config files as well as the edited startup scripts, `clouds.yaml`, etc. Be careful not to expose sensitive data by granting too generous access to your backed up files.

## Troubleshooting

### Debugging issues
In case there is trouble with your cloud, the normal course of action to analyze is as follows:
* Look at the dashboard (see above)
* Connect to the driver VM and attach to the tmux session and look at the console output of `api_monitor.sh`
* Analyze the logfile (locally on the driver VM or grab it from the object storage)

### Analyzing failures

When VM instances are created successfully, but then end up in `ERROR` state, the `api_monitor.sh` does an explicit `openstack server show`, so you will find some details in the tmux session, in the alarm emails (if you use those) and in the log files.

Sometimes the VMs end up being `ACTIVE` as wanted but then they can't be accessed via ssh. More often than not, this is a problem with meta-data service on a compute host. Without metadata, not ssh key is injected and login will fail.

To gather more details, you can look at the console output `openstack console log show VM` (where `VM` is the name of the uuid of the affected VM instance). The cloud-init output is often enough to see what has gone wrong. You can log in to the VMs: The jumphosts are directly accessible via `ssh -i APIMonitor_XXXXX_JH.pem debian@FIP`, whereas the JumpHost does port forwarding to the other VMs that don't have their own floating IP address: `ssh -i APIMonitor_XXXXX_VM.pem -p 222 debian@FIP`. Replace `XXXXX` with the number in your current APIMonitor prefix, `FIP` with the floating IP address of the responsible JumpHost and `debian` with the user name used by the images you boot. Use `223` to connect to the second VM in the network, `224` the third etc.

When logged in, look at `/var/log/cloud-init-output.log` and `/var/log/cloud-init.log`. You can find the metadata in `/var/lib/cloud/instance/`.

You will not have much time to look around -- the still running `api_monitor.sh` script does continue and clean things up again. So you might want to suspend it with `^Z` (and continue it later with `fg`). Another option is to not stop the regular monitoring, but start a second instance manually; see above notes for running multiple instances though. If you start a second instance manually against the same project, do NOT use the `run_CLOUDNAME.sh` script as it would do cleanup against the running instance, but rather copy the `api_monitor.sh` command line from the bottom (without the `exec`), reduce the iterations to a few (unless you need a lot to trigger the issue again) and attach `-w -1` to make the script stop its operation (and wait for Enter) once it hits an error. Of course, you still will face cleanup when the continuing main script hits its 200th iteration and you have chosen to run this second instance against the same project in the same cloud. After analyzing, do not forget to go back to the tmux window where the stopped script is running and do hit Enter, so it can continue and do its cleanup work.

### Cleaning things up

If you are unlucky, the script fails to clean something up. A volume may not have been named (because of a cinder failure) or all the logic may have gone wrong, e.g. the heuristic to avoid leaking floating IPs. You can try to clean this up using the normal openstack commands (or horizon dashboard).

There are a few things that may need support from a cloud admin:
* Volumes may end up permanently in a `deleting` or `reserved` state or may be `in-use`, attached to a VM that has long gone. The admin needs to set the state to `error` and then delete them.
* Loadbalancers may end up in a `PENDING_XXX` state (`XXX` being `CREATE`, `UPDATE` or `DELETE`) without ever changing. This also needs the cloud admin to set the status to `ERROR`, so it can be cleaned up. amphorae are more prone to this than ovn LBs.

More like these may happen, but those two are the only ones that have been observed to happen occasionally. Some services seem to be less robust than others against an event in the event queue (rabbitmq) being lost or an connection to be interrupted.


