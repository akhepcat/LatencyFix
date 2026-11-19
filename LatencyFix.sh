#!/bin/bash
# (c) 2015 Leif Sawyer
# License: GPL 2.0 (see https://github.com/akhepcat/)
# Permanent home:  https://github.com/akhepcat/LatencyFix/
# Direct download: https://raw.githubusercontent.com/akhepcat/LatencyFix/master/LatencyFix.sh
# 
# shellcheck disable=SC2010

PROG="${0##*/}"
DEBUG=0
INFO=0
SYSCTL=""
KREL=$(uname -r)
KVER=${KREL%%.*}

usage() {
	printf "%s [--help|-h|--debug|-d|--info|-i|--sysctl|-s] {bandwidth}\n" "${PROG}"
	printf "\n"
	printf " * bandwidth can be specified as bare bits, KiB, KB, MiB, MB, GiB, and GB\n"
	printf " * commas are optional and will be stripped out\n"
	printf " * -s|--sysctl  output sysctl statements (defaults to bare values for adding to /etc/sysctl.d)\n"
	printf " * -i|--info	just print out the current state, don't show proposed changes\n"
	printf " * -d|--debug	prints extra debugging information during processing\n"
	printf "\n"
	printf "examples:\n"
	printf "     # %s  10GB\n" "${PROG}"
	printf "     # %s  100MiB\n" "${PROG}"
	printf "     # %s  100,000,000\n" "${PROG}"
	printf "     # %s  1000000\n" "${PROG}"
	printf "\n"
	printf "No changes will be made to the system, but suggested commands/values will be printed\n\n"
	printf "*** not seeing any suggestions?  You may be all tuned, or over-tuned.  Try disabling your existing tuning first!\n"
	printf "\n"
	exit 1
}

debug() {
	if [[ ${DEBUG} -gt 0 ]]
	then
		printf "#DBG- %s\n" "${*}" 1>&2;
	fi
}

inform() {
	printf "%s\n" "${*}" 1>&2;
}

inform_onoff() {
	local status="disabled"
	local var=$1
	shift
	
	if [[ ${var:-0} -eq 1 ]]
	then
		status=enabled
	fi

	printf "%s: ${status}\n" "${*}" 1>&2;
}

optspec=":dhis-"
while getopts "$optspec" optchar; do
    case "${optchar}" in
        -)
            case "${OPTARG}" in
                debug) DEBUG=1
                    ;;
                info) INFO=1
                    ;;
                sysctl) SYSCTL="sysctl -w "
                    ;;
                help)
                    usage
                    ;;
                *)
                    if [[ "$OPTERR" = 1 ]] && [[ "${optspec:0:1}" != ":" ]]; then
                        echo "Unknown option --${OPTARG}" >&2
                    fi
                    ;;
            esac
            ;;
        h)  usage
            ;;
        i)  INFO=1
            ;;
        d)  DEBUG=1
            ;;
        s)  SYSCTL="sysctl -w "
            ;;
        *)
            if [[ "$OPTERR" != 1 ]] || [[ "${optspec:0:1}" = ":" ]]; then
                echo "Non-option argument: '-${OPTARG}'" >&2
            fi
            ;;
    esac
done

RATE="${!OPTIND}"
RATE=${RATE,,}
RATE=${RATE//,/}

if [[ -z "${RATE%%[0-9]*ki*}" ]]; then
	debug "bandwidth in KiB/s"
	MULTI=1024
elif [[ -z "${RATE%%[0-9]*k*}" ]]; then
	debug "bandwidth in KB/s"
	MULTI=1000
elif [[ -z "${RATE%%[0-9]*mi*}" ]]; then
	debug "bandwidth in MiB/s"
	MULTI=$((1024 * 1024))
elif [[ -z "${RATE%%[0-9]*m*}" ]]; then
	debug "bandwidth in MB/s"
	MULTI=$((1000 * 1000))
elif [[ -z "${RATE%%[0-9]*gi*}" ]]; then
	debug "bandwidth in GiB/s"
	MULTI=$((1024 * 1024 * 1024))
elif [[ -z "${RATE%%[0-9]*g*}" ]]; then
	debug "bandwidth in GB/s"
	MULTI=$((1000 * 1000 * 1000))
elif [[ -n "${RATE//[^0-9]/}" ]]; then
	MULTI=1
fi

BANDWIDTH=${RATE//[^0-9]/}
BANDWIDTH=$((BANDWIDTH * MULTI))
if [[ ${BANDWIDTH:-0} -gt 0 ]]
then
	inform "# bandwidth set to %i bits per second" "${BANDWIDTH}"
fi

# Just in case we need it later, but for now it's unused
# DEFIF=$(awk 'BEGIN { IGNORECASE=1 } /^[a-z0-9]+[ \t]+00000000/ { print $1 }' /proc/net/route)

# Grab the current information
def_qdisc=$(sysctl -n -e net.core.default_qdisc)
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
# This was removed in linux !
#tcp_fack=$(sysctl -n -e net.ipv4.tcp_fack )

if [[ ${KVER} -lt 6 ]]
then
	tcp_rfc1337=$(sysctl -n -e net.ipv4.tcp_rfc1337 )
	tcp_sack=$(sysctl -n -e net.ipv4.tcp_sack )
	tcp_window_scaling=$(sysctl -n -e net.ipv4.tcp_window_scaling )
	tcp_timestamps=$(sysctl -n -e net.ipv4.tcp_timestamps)
fi

if [[ ${INFO:-0} -eq 1 ]] || [[ "$def_sys_rmem" != "$def_proc_rmem" ]]; then inform "# rmem_default:  sys($def_sys_rmem) vs proc($def_proc_rmem)"; fi
if [[ ${INFO:-0} -eq 1 ]] || [[ "$def_sys_wmem" != "$def_proc_wmem" ]]; then inform "# wmem_default:  sys($def_sys_wmem) vs proc($def_proc_wmem)"; fi
if [[ ${INFO:-0} -eq 1 ]] || [[ "$max_sys_rmem" != "$max_proc_rmem" ]]; then inform "#     rmem_max:  sys($max_sys_rmem) vs proc($max_proc_rmem)"; fi
if [[ ${INFO:-0} -eq 1 ]] || [[ "$max_sys_wmem" != "$max_proc_wmem" ]]; then inform "#     wmem_max:  sys($max_sys_wmem) vs proc($max_proc_wmem)"; fi

if [[ ${INFO:-0} -eq 1 ]]
then
	inform "#        qdisc: ${def_qdisc}"
	inform "# tcp_congestion_control: ${congestctl}"
	inform_onoff "${pmtu_disc}" "#         pmtu"
	inform_onoff "${tcp_ecn}" "#      tcp_ecn"
#	inform_onoff "${tcp_fack}" "#     tcp_fack"
	if [[ ${KVER} -lt 6 ]]
	then
		inform_onoff "${tcp_sack}" "#     tcp_sack"
		inform_onoff "${tcp_rfc1337}" "#  tcp_rfc1337"
		inform_onoff "${tcp_window_scaling}" "# tcp_window_scaling"
		inform_onoff "${tcp_timestamps}"     "# tcp_timestamps"
	fi
fi

inform "# Testing network for 10s to optimze latency numbers"
PING4=$(ping --help 2>&1 | grep -o -- "-4")
if [[ -z "${PING4}" ]]
then
	# assume that ping is ipv4 only, because there's no -4 flag for it
	PINGC="ping"
else
	# force ping to use ipv4
	PINGC="ping -4"
fi

# Only one of these needs to work, so we test to see which one does, and then it falls through to the real test
HOSTS="bing.com ip4.me google.com"
for PHOST in ${HOSTS}
do
        if ${PINGC} -n -c 1 -w 1 "${PHOST}" >/dev/null 2>&1; then
                break
        fi
done

# TCP Window Size to test (MSS) - stay within any gre/ipv6/vpn tunnel size
WINDOW=1200


PING=$(${PINGC} -n -c 10 -s ${WINDOW} "${PHOST}" | grep -iE '^(rtt|round-trip)' )
#+ PING='rtt min/avg/max/mdev = 11.001/15.618/20.264/3.189 ms'
#       'round-trip min/avg/max/stddev = 43.629/44.876/46.123/1.247 ms'

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

WINDOW_BYTES=$(( 2* BANDWIDTH * DELAY / MILLISECONDS / 8 ))  # 2x because end-to-end



debug "# Checking queuing discipline"
# Queuing disciplines: preferentially [ sch_cake, sch_codel, sch_fq_codel, sch_fq ]
aqdiscs=$(ls "/lib/modules/${KREL}/kernel/net/sched/" | grep -iE '_(fq|codel|cake).ko')
if [[ -n "${def_qdisc}" ]] && [[ -n "${def_qdisc##*cake*}" ]]; then
	# the qdisc is set, but it's not cake, so make sure we're using the best available
	if [[ -n "${aqdiscs}" ]]; then
		# We have some options, let's figure out which one
		if [[ -z "${aqdiscs##*cake*}"  ]]; then
			# cake is available, not yet enabled, let them eat cake!
			debug "# Prefer the cake queueing discipline instead of default fair-queue (fq)"
			inform "${SYSCTL}net.core.default_qdisc=cake"
		elif [[ -z "${aqdiscs##*fq_codel*}"  ]]; then
			# cake not available, but fq_codel is
			debug "# cake unavailable, using fq_codel"
			inform "${SYSCTL}net.core.default_qdisc=fq_codel"
		elif [[ -z "${aqdiscs##*codel*}"  ]]; then
			# neither cake nor fq_codel are available, but codel is...
			debug "# cake nor fq_codel unavailable, using limited codel"
			inform "${SYSCTL}net.core.default_qdisc=codel"
		else
			# No real options exist, so it's just kernel default
			debug "# no advanced queuing available, use this kernel's default"
		fi
	else
		# No real options exist, so it's just kernel default
		debug "# no advanced queuing available, use this kernel's default"
	fi
else
	# We're already using cake
	debug "# cake available and enabled, continuing to use it"
fi

debug "# Checking congestion control"

congestctls=$(ls "/lib/modules/${KREL}/kernel/net/ipv4/" | grep -oiE 'cubic|bbr|illinois')
congestctls="${congestctls} $(sysctl -n -e net.ipv4.tcp_available_congestion_control)"

if [[ ${KVER} -lt 6 ]]; then
	# only use TCP timestamps in low-latency situations
	if [[ $tcp_timestamps -ne 1 ]]; then inform "${SYSCTL}net.ipv4.tcp_timestamps=1"; fi
fi

# Congestion control
if [[ $DELAY -le 150 ]]; then
	# BBR(v1) is a good compromise control, though BBR(v2) will be better when available
	if [[ -z "${congestctl##*bbr*}" ]]; then 
		debug "# Typical delay (>${DELAY}ms) encountered, continuing to use bbr"
	else
		# Not using BBR currently, so figure out what's available
	        if [[ -z "${congestctls##*bbr*}" ]]; then
			debug "# Typical delay (>${DELAY}ms) encountered, using bbr congestion control"
			inform "${SYSCTL}net.ipv4.tcp_congestion_control=bbr"

	        elif [[ -z "${congestctls##*illinois*}" ]]; then
			debug "# Typical delay (>${DELAY}ms) encountered, bbr not available, using illinois"
			inform "${SYSCTL}net.ipv4.tcp_congestion_control=illinois"
		else
			debug "# Typical delay (>${DELAY}ms) encountered, no other options but CUBIC (default) available"
			inform "${SYSCTL}net.ipv4.tcp_congestion_control=cubic"
		fi
        fi

elif [[ $DELAY -ge 300 ]]; then
	if [[ -z "${congestctls##*hybla*}" ]] && [[ -n "${congestctl##*hybla*}" ]]; then
		debug "# Excessive delay (>${DELAY}ms) encountered, using hybla (satellite-smart) congestion control"
		inform "${SYSCTL}net.ipv4.tcp_congestion_control=hybla"
	fi
else
	if [[ ${KVER} -lt 6 ]]; then
		# Delay is between 150 and 300... disable tcp timestamps, but we can still use bbr
		if [[ $tcp_timestamps -ne 0 ]]; then inform "${SYSCTL}net.ipv4.tcp_timestamps=0"; fi
	fi

	# try PCC, then fall-back to BBR
        if [[ -z "${congestctls##*pcc*}" ]] && [[ -n "${congestctl##*pcc*}" ]]; then
                debug "# Higher delay (>${DELAY}ms) encountered, using PCC congestion control"
                inform "${SYSCTL}net.ipv4.tcp_congestion_control=pcc"

        elif [[ -z "${congestctls##*bbr*}" ]] && [[ -n "${congestctl##*bbr*}" ]]; then
                debug "# Higher delay (>${DELAY}ms) encountered, using bbr congestion control"
                inform "${SYSCTL}net.ipv4.tcp_congestion_control=bbr"
        fi

fi

if [[ $max_sys_rmem -lt ${WINDOW_BYTES} ]]; then inform "${SYSCTL}net.core.rmem_max=${WINDOW_BYTES}"; fi
if [[ $max_sys_wmem -lt ${WINDOW_BYTES} ]]; then inform "${SYSCTL}net.core.wmem_max=${WINDOW_BYTES}"; fi
if [[ $pmtu_disc -ne 0 ]]; then inform "${SYSCTL}net.ipv4.ip_no_pmtu_disc=0"; fi
if [[ $tcp_ecn  -ne 1 ]]; then inform "${SYSCTL}net.ipv4.tcp_ecn=1"; fi

#if [[ $tcp_fack  -ne 1 ]]; then inform "${SYSCTL}net.ipv4.tcp_fack=1"; fi
if [[ ${KVER} -lt 6 ]]; then
	# we force these in older kernels; newer kernels set sane defaults
	if [[ $tcp_rfc1337  -ne 1 ]]; then inform "${SYSCTL}net.ipv4.tcp_rfc1337=1"; fi
	if [[ $tcp_sack  -ne 1 ]]; then inform "${SYSCTL}net.ipv4.tcp_sack=1"; fi
	if [[ $tcp_window_scaling  -ne 1 ]]; then inform "${SYSCTL}net.ipv4.tcp_window_scaling=1"; fi
fi
