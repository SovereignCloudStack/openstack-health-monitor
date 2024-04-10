#!/usr/bin/sed -f
/"influxdb",$/{
s/,$//
n
d
}
