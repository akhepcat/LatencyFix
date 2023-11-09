Just a dumb script, trying to automate some of the easier portions of TCP tuning for long-haul high-latency networks.

Because satellite services are dumb, and most of the TCP tuning documents are for linux 2.4, and not the 3.12+ that is 'modern'


* USAGE
	LatencyFix.sh [--help|-h|--debug|-d|-s|--sysctl] {bandwidth}

	 * bandwidth can be specified as bare bits, KiB, KB, MiB, MB, GiB, and GB
	 * commas are optional and will be stripped out
	 * -s|--sysctl  output sysctl statements (defaults to bare values for adding to /etc/sysctl.d)
	
	examples:
	     # LatencyFix.sh  10GB
	     # LatencyFix.sh  100MB
	     # LatencyFix.sh  100,000,000
	     # LatencyFix.sh  1000000
	
	No changes will be made to the system, but suggested commands/values will be printed

	*** not seeing any suggestions?  You may be all tuned, or over-tuned.  Try disabling your existing tuning first!


