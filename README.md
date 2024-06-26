Just a dumb script, trying to automate some of the easier portions of TCP tuning for long-haul high-latency networks.

This should work well for satellite connections, long-haul fiber (> 1000km)
and even local networks for high-speed (>=10gb) interfaces

This script will enable BBR (Bottleneck Bandwidth & RTT) congestion control,
as well as the CAKE (Common Applications Kept Enhanced) scheduler (if available)

* USAGE

	LatencyFix.sh [--help|-h|--debug|-d|--info|-i|--sysctl|-s] {bandwidth}

	 * bandwidth can be specified as bare bits, KiB, KB, MiB, MB, GiB, and GB
	 * commas are optional and will be stripped out

	 * -s|--sysctl  output sysctl statements (defaults to bare values for adding to /etc/sysctl.d)
	 * -i|--info    just print out the current state, don't show proposed changes
	 * -d|--debug   prints extra debugging information during processing



* EXAMPLES

	*** this script does not have to be run as root, typically, except on very locked-down systems.


	* $ LatencyFix.sh  10GB
	* $ LatencyFix.sh  100MiB
	* $ LatencyFix.sh  100,000,000
	* $ LatencyFix.sh  1000000

	*** put the auto-generated commands into /etc/sysctl.d *** be sure to review afterward!  

	* $ LatencyFix.sh 10GB | sudo tee -a /etc/sysctl.d/92-latencyfix.conf
	
* TIPS

	* No changes will be made to the system by the script itself, only suggested commands/values will be printed

	* Not seeing any suggestions?  You may be all tuned, or over-tuned.  Try disabling your existing tuning first!

