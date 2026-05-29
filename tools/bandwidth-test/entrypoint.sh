#!/bin/sh

set -a
. /opt/iperf3.env
set +a


iperf3 -s -p $IPERF3_PORT 



