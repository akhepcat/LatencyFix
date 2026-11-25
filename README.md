Just a dumb python script, trying to automate some of the easier portions of TCP tuning for long-haul high-latency networks.

This should work well for satellite connections, long-haul fiber (> 1000km)
and even local networks for high-speed (>=10gb) interfaces

This script will enable BBR (Bottleneck Bandwidth & RTT) congestion control,
as well as the fq scheduler, which for most server applications is better.

For endpoints behind DOCSIS or DSL modems, you can manually change to the
CAKE (Common Applications Kept Enhanced) scheduler if available on your
system.

Recently migrated from bash to python and modernized away from pre-2015
defaults.


* USAGE

    $  LatencyFix.py [-h] [--link-speed LINK_SPEED] [--rtt-ms RTT_MS]
                     [--meminfo-path MEMINFO_PATH] [--out-file OUT_FILE]
                     [--no-modprobe-check] [--apply]

Deterministically generate (and optionally apply) sysctl network tuning for
NMS nodes.

options:
  -h, --help            show this help message and exit
  --link-speed LINK_SPEED
                        Target interface speed with optional SI (k, M, G, T,
                        P) or IEC (Ki, Mi, Gi, Ti, Pi) prefix. Lowercase 'b' =
                        bits, uppercase 'B' = bytes (e.g., 10Gb, 10Gbps,
                        1.25GB/s, 900MiB/s, 10G). Default: 10Gb.
  --rtt-ms RTT_MS       Design round-trip time in milliseconds for BDP
                        calculation. Default: 50.0.
  --meminfo-path MEMINFO_PATH
                        Path to meminfo file (useful for unit tests). Default:
                        /proc/meminfo.
  --out-file OUT_FILE   Destination sysctl drop-in path when --apply is used.
                        Default: /etc/sysctl.d/99-network-tuning.conf
  --no-modprobe-check   Skip read-only `modprobe --dry-run` availability
                        checks.
  --apply               Write the sysctl file (does not apply changes to the
                        running kernel)


* EXAMPLES

	*** this script does not have to be run as root, typically, except on very locked-down systems.


	* $ LatencyFix.sh  --link-speed 10GB
	* $ LatencyFix.sh  --link-speed 100MiB
	* $ LatencyFix.sh  --link-speed 1000000 --apply

	*** '--apply' will put the auto-generated commands into /etc/sysctl.d *** be sure to review afterward!
	
* TIPS

	* No changes will be made to the system by the script itself, only suggested commands/values will be printed

	* Not seeing any suggestions?  You may be all tuned, or over-tuned.  Try disabling your existing tuning first!


* LEGACY
  The legacy bash script is still available, and it's README is [[Legacy.md]]
