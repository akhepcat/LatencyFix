#!/bin/bash
# (c) 2015 Leif Sawyer
# License: GPL 2.0 (see https://github.com/akhepcat/)
# Permanent home:  https://github.com/akhepcat/LatencyFix/
# Direct download: https://raw.githubusercontent.com/akhepcat/LatencyFix/master/LatencyFix.sh
# 


PROG="${0##*/}"
DEBUG=0
INFO=0
SYSCTL=""

usage() {
	printf "${PROG} [--help|-h|--debug|-d|--info|-i|--sysctl|-s] {bandwidth}\n"
	printf "\n"
	printf " * bandwidth can be specified as bare bits, KiB, KB, MiB, MB, GiB, and GB\n"
	printf " * commas are optional and will be stripped out\n"
	printf " * -s|--sysctl  output sysctl statements (defaults to bare values for adding to /etc/sysctl.d)\n"
	printf " * -i|--info	just print out the current state, don't show proposed changes\n"
	printf " * -d|--debug	prints extra debugging information during processing\n"
	printf "\n"
	printf "examples:\n"
	printf "     # ${PROG}  10GB\n"
	printf "     # ${PROG}  100MiB\n"
	printf "     # ${PROG}  100,000,000\n"
	printf "     # ${PROG}  1000000\n"
	printf "\n"
	printf "No changes will be made to the system, but suggested commands/values will be printed\n\n"
	printf "*** not seeing any suggestions?  You may be all tuned, or over-tuned.  Try disabling your existing tuning first!\n"
	printf "\n"
	exit 1
}

debug() {
	if [ ${DEBUG} -gt 0 ]
	then
		printf "#DBG- ${*}\n" 1>&2;
	fi
}

inform() {
	printf "${*}\n" 1>&2;
}

if [ -z "${1}" ]
then
	usage
fi

case "${1,,}" in
	-i|--info) shift; INFO=1 ;;
	-d|--debug) shift; DEBUG=1 ;;
	-s|--sysctl) shift; SYSCTL="sysctl -w " ;;
	-h|--help) usage ; 
esac

RATE=${1,,}
RATE=${RATE//,/}

if [ -z "${RATE%%[0-9]*ki*}" ]
then
	debug "bandwidth in KiB/s"
	MULTI=1024
elif [ -z "${RATE%%[0-9]*k*}" ]
then
	debug "bandwidth in KB/s"
	MULTI=1000
elif [ -z "${RATE%%[0-9]*mi*}" ]
then
	debug "bandwidth in MiB/s"
	MULTI=$((1024 * 1024))
elif [ -z "${RATE%%[0-9]*m*}" ]
then
	debug "bandwidth in MB/s"
	MULTI=$((1000 * 1000))
elif [ -z "${RATE%%[0-9]*gi*}" ]
then
	debug "bandwidth in GiB/s"
	MULTI=$((1024 * 1024 * 1024))
elif [ -z "${RATE%%[0-9]*g*}" ]
then
	debug "bandwidth in GB/s"
	MULTI=$((1000 * 1000 * 1000))
elif [ -n "${RATE//[^0-9]/}" ]
then
	MULTI=1
fi
BANDWIDTH=${RATE//[^0-9]/}
BANDWIDTH=$((BANDWIDTH * $MULTI))
inform "# bandwidth set to ${BANDWIDTH} bits per second"

DEFIF=$(awk 'BEGIN { IGNORECASE=1 } /^[a-z0-9]+[ \t]+00000000/ { print $1 }' /proc/net/route)

# Grab the current information
def_qdisc=$(sysctl -n -e net.core.default_qdisc)
congestctls=$(sysctl -n -e net.ipv4.tcp_available_congestion_control)
congestctl=$(sysctl -n -e net.ipv4.tcp_congestion_control)
def_sys_rmem=$(sysctl -n -e net.core.rmem_default)
def_proc_rmem=$(cat /proc/sys/net/core/rmem_default)
def_sys_wmem=$(sysctl -n -e net.core.wmem_default)
def_proc_wmem=$(cat /proc/sys/net/core/wmem_default)
max_sys_rmem=$(sysctl -n -e net.core.rmem_max)
max_proc_rmem=$(cat /proc/sys/net/core/rmem_max)
max_sys_wmem=$(sysctl -n -e net.core.wmem_max)
max_proc_wmem=$(cat /proc/sys/net/core/wmem_max)
pmtu_disc=$(sysctl -n -e net.ipv4.ip_no_pmtu_disc)
tcp_ecn=$(sysctl -n -e net.ipv4.tcp_ecn )
tcp_fack=$(sysctl -n -e net.ipv4.tcp_fack )
tcp_rfc1337=$(sysctl -n -e net.ipv4.tcp_rfc1337 )
tcp_sack=$(sysctl -n -e net.ipv4.tcp_sack )
tcp_window_scaling=$(sysctl -n -e net.ipv4.tcp_window_scaling )
tcp_timestamps=$(sysctl -n -e net.ipv4.tcp_timestamps)

if [ ${INFO:-0} -eq 1 -o $def_sys_rmem != $def_proc_rmem ]; then inform "# rmem_default:  sys($def_sys_rmem) vs proc($def_proc_rmem)"; fi
if [ ${INFO:-0} -eq 1 -o $def_sys_wmem != $def_proc_wmem ]; then inform "# wmem_default:  sys($def_sys_wmem) vs proc($def_proc_wmem)"; fi
if [ ${INFO:-0} -eq 1 -o $max_sys_rmem != $max_proc_rmem ]; then inform "#     rmem_max:  sys($max_sys_rmem) vs proc($max_proc_rmem)"; fi
if [ ${INFO:-0} -eq 1 -o $max_sys_wmem != $max_proc_wmem ]; then inform "#     wmem_max:  sys($max_sys_wmem) vs proc($max_proc_wmem)"; fi

inform "# Testing network for 10s to optimze latency numbers"

# Only one of these needs to work, so we test to see which one does, and then it falls through to the real test
HOSTS="bing.com ip4.me google.com"
for PHOST in ${HOSTS}
do
        ping -4 -n -c 1 -w 1 ${PHOST} >/dev/null 2>&1
        if [ $? -eq 0 ]
        then
                break
        fi
done

# TCP Window Size to test (MSS) - stay within any gre/ipv6/vpn tunnel size
WINDOW=1200


PING=$(ping -4 -n -c 10 -s ${WINDOW} ${PHOST} | grep ^rtt)
#+ PING='rtt min/avg/max/mdev = 11.001/15.618/20.264/3.189 ms'
RTT=${PING##*= }
#+ RTT='11.001/15.618/20.264/3.189 ms'
DELAY=${RTT%%.*}
#+ DELAY='11'   -- in milliseconds...

if [[ ${INFO:-0} -eq 1 ]]
then
	# just for the delay output, we'll exit right after
        DEBUG=1
fi

debug "delay to ${PHOST} calculated at ${DELAY} ms"

if [[ ${INFO:-0} -eq 1 ]]
then
	exit 0
fi

# -------

debug "lack of output below this line means no changes are recommended at this time"

# 1000ms  to the second
MILLISECONDS=1000

WINDOW_BYTES=$(( 2* $BANDWIDTH * $DELAY / $MILLISECONDS / 8 ))  # 2x because end-to-end

if [ $max_sys_rmem -lt ${WINDOW_BYTES} ]; then inform "${SYSCTL}net.core.rmem_max=${WINDOW_BYTES}"; fi
if [ $max_sys_wmem -lt ${WINDOW_BYTES} ]; then inform "${SYSCTL}net.core.wmem_max=${WINDOW_BYTES}"; fi

if [ $pmtu_disc -ne 0 ]; then inform "${SYSCTL}net.ipv4.ip_no_pmtu_disc=0"; fi
if [ $tcp_ecn  -ne 0 ]; then inform "${SYSCTL}net.ipv4.tcp_ecn=0"; fi
if [ $tcp_fack  -ne 1 ]; then inform "${SYSCTL}net.ipv4.tcp_fack=1"; fi
if [ $tcp_rfc1337  -ne 1 ]; then inform "${SYSCTL}net.ipv4.tcp_rfc1337=1"; fi
if [ $tcp_sack  -ne 1 ]; then inform "${SYSCTL}net.ipv4.tcp_sack=1"; fi
if [ $tcp_window_scaling  -ne 1 ]; then inform "${SYSCTL}net.ipv4.tcp_window_scaling=1"; fi


aqdiscs=$(ls /lib/modules/`uname -r`/kernel/net/sched/ | grep -iE '_(fq|cake).ko')
if [ \( -n "${aqdiscs}" -a -z "${aqdiscs##*cake*}" \) -a \( -n "${def_qdisc}" -a -n "${def_qdisc##*cake*}" \) ]
then
	# cake is available, not yet enabled, let them eat cake!
	debug "# Prefer the cake queueing discipline instead of default fair-queue (fq)"
	inform "${SYSCTL}net.core.default_qdisc=cake"
fi

if [ $DELAY -le 150 ]
then
	# only use TCP timestamps in low-latency situations
	if [ $tcp_timestamps -ne 1 ]; then inform "${SYSCTL}net.ipv4.tcp_timestamps=1"; fi

	# BBR(v1) is a good compromise control, though BBR(v2) will be better when available
        if [ -z "${congestctls##*bbr*}" -a -n "${congestctl##*bbr*}" ]
        then
                debug "# Typical delay (>${DELAY}ms) encountered, using bbr congestion control"
                inform "${SYSCTL}net.ipv4.tcp_congestion_control=bbr"
        fi

elif [ $DELAY -ge 300 ]
then
	if [ -z "${congestctls##*hybla*}" -a -n "${congestctl##*hybla*}" ]
	then
		debug "# Excessive delay (>${DELAY}ms) encountered, using hybla (satellite-smart) congestion control"
		inform "${SYSCTL}net.ipv4.tcp_congestion_control=hybla"
	fi
else
#       Delay is between 150 and 300... disable tcp timestamps, but we can still use bbr
	if [ $tcp_timestamps -ne 0 ]; then inform "${SYSCTL}net.ipv4.tcp_timestamps="; fi

	# try PCC, then fall-back to BBR
        if [ -z "${congestctls##*pcc*}" -a -n "${congestctl##*pcc*}" ]
        then
                debug "# Higher delay (>${DELAY}ms) encountered, using PCC congestion control"
                inform "${SYSCTL}net.ipv4.tcp_congestion_control=pcc"

        elif [ -z "${congestctls##*bbr*}" -a -n "${congestctl##*bbr*}" ]
        then
                debug "# Higher delay (>${DELAY}ms) encountered, using bbr congestion control"
                inform "${SYSCTL}net.ipv4.tcp_congestion_control=bbr"
        fi

fi



if [ 0 -eq 1 ]
then

	inform "---- some other values"

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
