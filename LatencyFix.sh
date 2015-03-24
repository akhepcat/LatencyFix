#!/bin/bash

DEFIF=$(awk 'BEGIN { IGNORECASE=1 } /^[a-z0-9]+[ \t]+00000000/ { print $1 }' /proc/net/route)

# Grab the current information
congestctls=$(sysctl -ne net.ipv4.tcp_available_congestion_control)
def_sys_rmem=$(sysctl -en net.core.rmem_default)
def_proc_rmem=$(cat /proc/sys/net/core/rmem_default)
def_sys_wmem=$(sysctl -en net.core.wmem_default)
def_proc_wmem=$(cat /proc/sys/net/core/wmem_default)
max_sys_rmem=$(sysctl -en net.core.rmem_max)
max_proc_rmem=$(cat /proc/sys/net/core/rmem_max)
max_sys_wmem=$(sysctl -en net.core.wmem_max)
max_proc_wmem=$(cat /proc/sys/net/core/wmem_max)
pmtu_disc=$(sysctl -ne net.ipv4.ip_no_pmtu_disc)
tcp_ecn=$(sysctl -ne net.ipv4.tcp_ecn )
tcp_fack=$(sysctl -ne net.ipv4.tcp_fack )
tcp_rfc1337=$(sysctl -ne net.ipv4.tcp_rfc1337 )
tcp_sack=$(sysctl -ne net.ipv4.tcp_sack )
tcp_window_scaling=$(sysctl -ne net.ipv4.tcp_window_scaling )
tcp_timestamps=$(sysctl -ne net.ipv4.tcp_timestamps)

if [ $def_sys_rmem != $def_proc_rmem ]; then echo "rmem_default:  sys($def_sys_rmem) vs proc($def_proc_rmem)"; fi
if [ $def_sys_wmem != $def_proc_wmem ]; then echo "wmem_default:  sys($def_sys_wmem) vs proc($def_proc_wmem)"; fi
if [ $max_sys_rmem != $max_proc_rmem ]; then echo "    rmem_max:  sys($max_sys_rmem) vs proc($max_proc_rmem)"; fi
if [ $max_sys_wmem != $max_proc_wmem ]; then echo "    wmem_max:  sys($max_sys_wmem) vs proc($max_proc_wmem)"; fi

# TCP Window Size to test (MSS) -  IPv6 tunnels are 1266?
WINDOW=1200

PING=$(ping -c 10 -s ${WINDOW} www.google.com | grep ^rtt)
#+ PING='rtt min/avg/max/mdev = 11.001/15.618/20.264/3.189 ms'
RTT=${PING##*= }
#+ RTT='11.001/15.618/20.264/3.189 ms'
DELAY=${RTT%%.*}
#+ DELAY='11'   -- in milliseconds...

# echo ${DELAY}

## bad assumption of 100mb/s of maximum throughput

BW=100000000
MILLISECONDS=1000

WINDOW_BYTES=$(( 2* $BW * $DELAY / $MILLISECONDS / 8 ))  # 2x because end-to-end

if [ $max_sys_rmem -ge ${WINDOW_BYTES} ]; then echo "TCP Window max_rmrm should be ${WINDOW_BYTES}, minimum"; fi
if [ $max_sys_wmem -ge ${WINDOW_BYTES} ]; then echo "TCP Window max_wmrm should be ${WINDOW_BYTES}, minimum"; fi

if [ $pmtu_disc -ne 0 ]; then echo "sysctl -w net.ipv4.ip_no_pmtu_disc=0"; fi
if [ $tcp_ecn  -ne 0 ]; then echo "sysctl -w net.ipv4.tcp_ecn=0"; fi
if [ $tcp_fack  -ne 1 ]; then echo "sysctl -w net.ipv4.tcp_fack=1"; fi
if [ $tcp_rfc1337  -ne 1 ]; then echo "sysctl -w net.ipv4.tcp_rfc1337=1"; fi
if [ $tcp_sack  -ne 1 ]; then echo "sysctl -w net.ipv4.tcp_sack=1"; fi
if [ $tcp_window_scaling  -ne 1 ]; then echo "sysctl -w net.ipv4.tcp_window_scaling=1"; fi


if [ $DELAY -le 150 ]
then
	if [ $tcp_timestamps -ne 1 ]; then echo "sysctl -w net.ipv4.tcp_timestamps=1"; fi
elif [ $DELAY -ge 300 ]
then
	if [ -z "${congestctls##*hybla*}" ]; then echo "sysctl -w net.ipv4.tcp_congestion_control=hybla"; fi
# else
#       Delay is between 150 and 300... nothing to do for mid-range congestion changes
fi



if [ 0 -eq 1 ]
then

echo "---- some other values"

# Some sysctl values for squeezing out performance
cat <<EOF

# this should be uncommented only if it's not working well
net.ipv4.route.flush = 1

# Increase Linux autotuning TCP buffer limits
# Set max to 16MB for 1GE and 32M (33554432) or 54M (56623104) for 10GE
# Don't set tcp_mem itself! Let the kernel scale it based on RAM.
net.core.rmem_max = 33554432 
net.core.wmem_max = 33554432
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.core.optmem_max = 40960
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Make room for more TIME_WAIT sockets due to more clients,
# and allow them to be reused if we run out of sockets
# Also increase the max packet backlog
net.core.netdev_max_backlog = 50000
net.ipv4.tcp_max_syn_backlog = 30000
net.ipv4.tcp_max_tw_buckets = 2000000

# If your servers talk UDP, also up these limits
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 2500
EOF

if [ 0 -eq 1 ];
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

fi

