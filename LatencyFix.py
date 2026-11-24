#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class SysctlPlan:
    params: dict[str, str]


_SI_EXPONENTS: dict[str, int] = {
    "": 0,
    "k": 3,
    "m": 6,
    "g": 9,
    "t": 12,
    "p": 15,
}

_IEC_EXPONENTS: dict[str, int] = {
    "ki": 10,
    "mi": 20,
    "gi": 30,
    "ti": 40,
    "pi": 50,
}

# Matches e.g.:
#   "10g", "10gb", "10Gbps", "1.25GB/s", "500MiBps", "2500 Mbit", "100MB"
_RATE_RE = re.compile(
    r"^\s*(?P<num>(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*"
    r"(?P<prefix>(?:[KMGTPEkmgtp]i|[KMGTPEkmgtp]))?"
    r"(?P<unit>bytes?|byte|bps|b/s|bit|bits|Bps|B/s|b|B)?\s*"
    r"(?:/s|ps)?\s*$"
)


def parse_link_speed_bps(raw: str) -> float:
    """
    Parse a link speed string into bits per second (bps).
    Supports SI (k, M, G, T, P -> 10^n) and IEC (Ki, Mi, Gi, Ti, Pi -> 2^n),
    bits and bytes, with or without /s or ps suffixes.
    Bare numbers or prefix-only strings (e.g. '10g', '10gb') default to bits/sec.
    """
    match = _RATE_RE.match(raw)
    if not match:
        raise ValueError(f"Unrecognized link speed format: {raw!r}")

    value = float(match.group("num"))
    if value <= 0:
        raise ValueError(f"Link speed must be positive, got: {raw!r}")

    raw_prefix = match.group("prefix") or ""
    raw_unit = match.group("unit") or ""

    # Determine scale factor from IEC or SI prefix
    if len(raw_prefix) == 2 and raw_prefix[1].lower() == "i":
        iec_key = raw_prefix.lower()
        if iec_key not in _IEC_EXPONENTS:
            raise ValueError(f"Unsupported IEC prefix {raw_prefix!r} in {raw!r}")
        scale = float(1 << _IEC_EXPONENTS[iec_key])
    else:
        si_key = raw_prefix.lower()
        if si_key not in _SI_EXPONENTS:
            raise ValueError(f"Unsupported SI prefix {raw_prefix!r} in {raw!r}")
        scale = float(10 ** _SI_EXPONENTS[si_key])

    # Determine whether the unit denotes bytes (multiply by 8 for bits) or bits
    is_bytes = False
    if raw_unit in ("B", "Bps", "B/s") or raw_unit.lower().startswith("byte"):
        is_bytes = True
    elif raw_unit == "" and raw_prefix.endswith("B"):
        # e.g., "10GB" where 'B' was captured in prefix
        is_bytes = True
    elif raw_unit in ("", "b", "bps", "b/s") or raw_unit.lower().startswith("bit"):
        is_bytes = False
    else:
        raise ValueError(f"Unrecognized unit {raw_unit!r} in {raw!r}")

    bps = value * scale * (8.0 if is_bytes else 1.0)
    return bps


def read_meminfo_bytes(proc_meminfo_path: str = "/proc/meminfo") -> int:
    """Read MemTotal (reported in kB, i.e., KiB, in /proc/meminfo) as bytes."""
    with open(proc_meminfo_path, "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                parts = line.split()
                if len(parts) < 2:
                    raise RuntimeError(f"Malformed MemTotal line: {line!r}")
                kb = int(parts[1])
                return kb * 1024
    raise RuntimeError(f"MemTotal not found in {proc_meminfo_path}")


def get_page_size() -> int:
    page_size = os.sysconf("SC_PAGE_SIZE")
    return page_size if page_size > 0 else 4096


def clamp(val: int, low: int, high: int) -> int:
    return max(low, min(high, val))


def build_sysctl_plan(
    link_speed_bps: float = 10e9,
    design_rtt_ms: float = 50.0,
    total_ram_bytes: int | None = None,
    page_size: int | None = None,
    max_tcp_ram_fraction: float = 0.15,
    max_single_socket_ram_fraction: float = 0.04,
) -> SysctlPlan:
    if link_speed_bps <= 0 or design_rtt_ms <= 0:
        raise ValueError("link_speed_bps and design_rtt_ms must be positive")

    ram_bytes = total_ram_bytes if total_ram_bytes is not None else read_meminfo_bytes()
    pg_size = page_size if page_size is not None else get_page_size()

    # Bandwidth-Delay Product in bytes: (bits/sec / 8) * (rtt_ms / 1000)
    bdp_bytes = int((link_speed_bps / 8.0) * (design_rtt_ms / 1000.0))

    # Scale minimum floor gently for sub-1GbE links while keeping >= 4 MiB on >= 1GbE
    min_socket_floor = 4 * 1024 * 1024 if link_speed_bps >= 1e9 else 1 * 1024 * 1024

    hard_per_socket_cap = min(
        256 * 1024 * 1024,
        int(ram_bytes * max_single_socket_ram_fraction),
    )
    socket_max = clamp(
        int(bdp_bytes * 1.5),
        min_socket_floor,
        max(min_socket_floor, hard_per_socket_cap),
    )

    tcp_rmem_min = pg_size
    tcp_rmem_default = clamp(262_144, tcp_rmem_min, socket_max)
    tcp_rmem_max = socket_max

    tcp_wmem_min = pg_size
    tcp_wmem_default = clamp(131_072, tcp_wmem_min, socket_max)
    tcp_wmem_max = socket_max

    core_rmem_max = tcp_rmem_max
    core_wmem_max = tcp_wmem_max
    core_rmem_default = tcp_rmem_default
    core_wmem_default = tcp_wmem_default

    # tcp_mem is measured in PAGES (not bytes)
    max_tcp_bytes = int(ram_bytes * max_tcp_ram_fraction)
    tcp_mem_high_pages = max(1024, max_tcp_bytes // pg_size)
    tcp_mem_pressure_pages = max(512, int(tcp_mem_high_pages * 0.75))
    tcp_mem_low_pages = max(256, int(tcp_mem_high_pages * 0.50))

    # Scale netdev_max_backlog with both RAM and link speed
    speed_factor = max(1.0, link_speed_bps / 10e9)
    netdev_backlog = clamp(
        int((ram_bytes / (1024**3)) * 16_384 * speed_factor),
        32_768,
        524_288,
    )

    params = {
        "net.core.rmem_default": str(core_rmem_default),
        "net.core.rmem_max": str(core_rmem_max),
        "net.core.wmem_default": str(core_wmem_default),
        "net.core.wmem_max": str(core_wmem_max),
        "net.core.netdev_max_backlog": str(netdev_backlog),
        "net.ipv4.tcp_rmem": f"{tcp_rmem_min} {tcp_rmem_default} {tcp_rmem_max}",
        "net.ipv4.tcp_wmem": f"{tcp_wmem_min} {tcp_wmem_default} {tcp_wmem_max}",
        "net.ipv4.tcp_mem": f"{tcp_mem_low_pages} {tcp_mem_pressure_pages} {tcp_mem_high_pages}",
        "net.ipv4.tcp_moderate_rcvbuf": "1",
        "net.ipv4.tcp_window_scaling": "1",
    }
    return SysctlPlan(params=params)


def render_sysctl_conf(plan: SysctlPlan, link_speed_bps: float, rtt_ms: float, ram_bytes: int) -> str:
    lines = [
        "# Managed by NMS sysctl auto-tuner (deterministic)",
        f"# Link speed: {link_speed_bps / 1e9:.3f} Gbps | Design RTT: {rtt_ms} ms | MemTotal: {ram_bytes} bytes",
        "",
    ]
    for key in sorted(plan.params.keys()):
        lines.append(f"{key} = {plan.params[key]}")
    return "\n".join(lines) + "\n"


def apply_sysctl_conf(conf_text: str, path: str = "/etc/sysctl.d/99-nms-10g-tuning.conf") -> None:
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(conf_text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, path)
    subprocess.run(["sysctl", "--system"], check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deterministically generate and apply sysctl network tuning for NMS nodes."
    )
    parser.add_argument(
        "--link-speed",
        default="10Gbps",
        help=(
            "Target interface speed with optional SI (k, M, G, T, P) or IEC "
            "(Ki, Mi, Gi, Ti, Pi) prefix and bits/bytes unit (e.g., 10Gbps, 10g, "
            "1.25GB/s, 950MiBps, 2500Mbps). Default: 10Gbps."
        ),
    )
    parser.add_argument(
        "--rtt-ms",
        type=float,
        default=50.0,
        help="Design round-trip time in milliseconds for BDP calculation. Default: 50.0.",
    )
    parser.add_argument(
        "--meminfo-path",
        default="/proc/meminfo",
        help="Path to meminfo file (useful for unit tests). Default: /proc/meminfo.",
    )
    parser.add_argument(
        "--out-file",
        default="/etc/sysctl.d/99-network-tuning.conf",
        help="Destination sysctl drop-in path. Default: /etc/sysctl.d/99-network-tuning.conf.",
    )
    parser.add_argument(
        "--save",
        action="store_true",
        help="Save generated sysctl config to the out-file, default prints.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    link_bps = parse_link_speed_bps(args.link_speed)
    ram_bytes = read_meminfo_bytes(args.meminfo_path)

    plan = build_sysctl_plan(
        link_speed_bps=link_bps,
        design_rtt_ms=args.rtt_ms,
        total_ram_bytes=ram_bytes,
    )
    conf_text = render_sysctl_conf(plan, link_bps, args.rtt_ms, ram_bytes)

    if args.save:
        apply_sysctl_conf(conf_text, path=args.out_file)
    else:
        print(conf_text)


if __name__ == "__main__":
    main()
