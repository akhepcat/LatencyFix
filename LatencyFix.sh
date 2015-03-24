#!/bin/bash

# TCP Window Size to test (MSS) -  IPv6 tunnels are 1266?
WINDOW=1200

PING=$(ping -c 10 -s ${WINDOW} plugbase.gci.net | grep ^rtt)
#+ PING='rtt min/avg/max/mdev = 11.001/15.618/20.264/3.189 ms'
RTT=${PING##*= }
#+ RTT='11.001/15.618/20.264/3.189 ms'
DELAY=${RTT%%.*}
#+ DELAY='11'   -- in milliseconds...

echo ${DELAY}

## bad assumption of 100mb/s of maximum throughput

BW=100000000
MILLISECONDS=1000

WINDOW_BYTES=$(( 2* $BW * $DELAY / $MILLISECONDS / 8 ))  # 2x because end-to-end

echo "TCP Window MAX should be ${WINDOW_BYTES}, minimum"

echo "rmem_default: $(cat /proc/sys/net/core/rmem_default)"
echo "wmwm_default: $(cat /proc/sys/net/core/wmem_default)"
echo "    rmem_max: $(cat /proc/sys/net/core/rmem_max)"
echo "    wmem_max: $(cat /proc/sys/net/core/wmem_max)"


echo "---- some other values"

# Some sysctl values for squeezing out performance
cat <<EOF
sysctl -w net.ipv4.ip_no_pmtu_disc=0
sysctl -w net.ipv4.tcp_ecn=0
sysctl -w net.ipv4.tcp_fack=1
sysctl -w net.ipv4.tcp_rfc1337=1
sysctl -w net.ipv4.tcp_sack=1
sysctl -w net.ipv4.tcp_window_scaling=1
sysctl -w net.ipv4.tcp_congestion_control=hybla

# Typically enabled for fast networks, adds 10bytes overhead, but provides better congestion control info
net.ipv4.tcp_timestamps = 0

# this should be uncommented only if it's not working well
net.ipv4.route.flush = 1

net.core.rmem_max = 33554432 
net.core.wmem_max = 33554432
net.core.rmem_default = 65536
net.core.wmem_default = 65536

net.ipv4.tcp_rmem = 4096 87380 16777216 
net.ipv4.tcp_wmem = 4096 87380 16777216 
EOF

if [ 0 ];
then
  cat <<EOF
# don't cache ssthresh from previous connection
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
# recommended to increase this for 1000 BT or higher
net.core.netdev_max_backlog = 2500


echo 6553500                 > /proc/sys/net/core/wmem_max
echo 6553500                 > /proc/sys/net/core/rmem_max
echo 4096 16384 6553500      > /proc/sys/net/ipv4/tcp_wmem
echo 8192 87380 6553500      > /proc/sys/net/ipv4/tcp_rmem
echo 6553500 6653500 6753500 > /proc/sys/net/ipv4/tcp_mem


EOF

fi
