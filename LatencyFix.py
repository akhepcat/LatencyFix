#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class SysctlPlan:
    params: dict[str, str]
    suggested_modules: tuple[str, ...]
    notes: tuple[str, ...]


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

# Prefix case is flexible (e.g. G, g, Mi, mi), while unit suffix preserves case:
#   - 'B', 'Bps', 'B/s', 'Byte', 'Bytes' -> bytes (uppercase B)
#   - 'b', 'bps', 'b/s', 'bit', 'bits'   -> bits (lowercase b)
#   - omitted unit (e.g. '10g', '10G')     -> defaults to bits
_RATE_RE = re.compile(
    r"^\s*(?P<num>(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*"
    r"(?P<prefix>(?:[KMGTPEkmgtp]i|[KMGTPEkmgtp]))?"
    r"(?P<unit>(?:Bytes?|Bps|B/s|B|bits?|bps|b/s|b))?\s*"
    r"(?:/s|ps)?\s*$"
)

# the default file to write
DEF_SYSCTLF = "/etc/sysctl.d/99-network-tuning.conf"


def parse_link_speed_bps(raw: str) -> float:
    """
    Parse a link speed string into bits per second (bps).
    - Lowercase 'b' (b, bps, b/s, bit, bits) = bits
    - Uppercase 'B' (B, Bps, B/s, Byte, Bytes) = bytes
    - Omitted unit (e.g. '10g', '10G', '10Gi') = bits per second
    Supports SI (k, M, G, T, P -> 10^n) and IEC (Ki, Mi, Gi, Ti, Pi -> 2^n).
    """
    match = _RATE_RE.match(raw)
    if not match:
        raise ValueError(f"Unrecognized link speed format: {raw!r}")

    value = float(match.group("num"))
    if value <= 0:
        raise ValueError(f"Link speed must be positive, got: {raw!r}")

    raw_prefix = match.group("prefix") or ""
    raw_unit = match.group("unit") or ""

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

    if raw_unit.startswith("B"):
        is_bytes = True
    elif raw_unit == "" or raw_unit.startswith("b"):
        is_bytes = False
    else:
        raise ValueError(f"Unrecognized unit {raw_unit!r} in {raw!r}")

    return value * scale * (8.0 if is_bytes else 1.0)


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


def read_sysctl_value(key: str) -> str:
    path = "/proc/sys/" + key.replace(".", "/")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def get_available_congestion_controls() -> set[str]:
    avail = read_sysctl_value("net.ipv4.tcp_available_congestion_control").split()
    return {c.strip().lower() for c in avail if c.strip()}


def is_module_loaded(mod_name: str, proc_modules_path: str = "/proc/modules") -> bool:
    try:
        with open(proc_modules_path, "r", encoding="utf-8") as f:
            for line in f:
                if line.split(maxsplit=1)[0] == mod_name:
                    return True
    except OSError:
        pass
    return False


def can_load_module(mod_name: str) -> bool:
    """Read-only check via `modprobe --dry-run`; never loads a module."""
    if is_module_loaded(mod_name):
        return True
    try:
        res = subprocess.run(
            ["modprobe", "--dry-run", mod_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return res.returncode == 0
    except OSError:
        return False


def select_congestion_control(
    rtt_ms: float,
    available_cc: set[str] | None = None,
    allow_modprobe_check: bool = True,
) -> tuple[str, tuple[str, ...], str]:
    """
    Select TCP congestion control deterministically and return any modules
    that would be needed (without loading them).
    Returns (selected_cc, suggested_modules, reason).
    """
    avail = set(available_cc) if available_cc is not None else get_available_congestion_controls()
    suggested: list[str] = []

    if "bbr" in avail:
        return "bbr", (), f"bbr available in tcp_available_congestion_control (RTT={rtt_ms}ms)"

    if allow_modprobe_check and can_load_module("tcp_bbr"):
        if not is_module_loaded("tcp_bbr"):
            suggested.append("tcp_bbr")
        return "bbr", tuple(suggested), f"tcp_bbr is loadable; advising bbr (RTT={rtt_ms}ms)"

    if "cubic" in avail:
        return "cubic", (), f"bbr unavailable; advising cubic fallback (RTT={rtt_ms}ms)"

    if allow_modprobe_check and can_load_module("tcp_cubic"):
        if not is_module_loaded("tcp_cubic"):
            suggested.append("tcp_cubic")
        return "cubic", tuple(suggested), f"bbr unavailable; advising tcp_cubic fallback (RTT={rtt_ms}ms)"

    if avail:
        fallback = sorted(avail)[0]
        return fallback, (), f"advising first available cc: {fallback}"

    return "cubic", (), "advising default cc: cubic"


def select_default_qdisc(congestion_control: str) -> str:
    """Pair BBR with 'fq' for pacing; otherwise advise 'fq_codel'."""
    if congestion_control == "bbr":
        return "fq"
    return "fq_codel"


def build_sysctl_plan(
    link_speed_bps: float = 10e9,
    design_rtt_ms: float = 50.0,
    total_ram_bytes: int | None = None,
    page_size: int | None = None,
    max_tcp_ram_fraction: float = 0.15,
    max_single_socket_ram_fraction: float = 0.04,
    available_cc: set[str] | None = None,
    allow_modprobe_check: bool = True,
) -> SysctlPlan:
    if link_speed_bps <= 0 or design_rtt_ms <= 0:
        raise ValueError("link_speed_bps and design_rtt_ms must be positive")

    ram_bytes = total_ram_bytes if total_ram_bytes is not None else read_meminfo_bytes()
    pg_size = page_size if page_size is not None else get_page_size()

    # Bandwidth-Delay Product in bytes: (bits/sec / 8) * (rtt_ms / 1000)
    bdp_bytes = int((link_speed_bps / 8.0) * (design_rtt_ms / 1000.0))

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

    speed_factor = max(1.0, link_speed_bps / 10e9)
    netdev_backlog = clamp(
        int((ram_bytes / (1024**3)) * 16_384 * speed_factor),
        32_768,
        524_288,
    )

    cc, suggested_mods, cc_reason = select_congestion_control(
        rtt_ms=design_rtt_ms,
        available_cc=available_cc,
        allow_modprobe_check=allow_modprobe_check,
    )
    qdisc = select_default_qdisc(cc)

    params = {
        "net.core.rmem_default": str(core_rmem_default),
        "net.core.rmem_max": str(core_rmem_max),
        "net.core.wmem_default": str(core_wmem_default),
        "net.core.wmem_max": str(core_wmem_max),
        "net.core.netdev_max_backlog": str(netdev_backlog),
        "net.core.default_qdisc": qdisc,
        "net.ipv4.tcp_rmem": f"{tcp_rmem_min} {tcp_rmem_default} {tcp_rmem_max}",
        "net.ipv4.tcp_wmem": f"{tcp_wmem_min} {tcp_wmem_default} {tcp_wmem_max}",
        "net.ipv4.tcp_mem": f"{tcp_mem_low_pages} {tcp_mem_pressure_pages} {tcp_mem_high_pages}",
        "net.ipv4.tcp_congestion_control": cc,
        "net.ipv4.tcp_moderate_rcvbuf": "1",
        "net.ipv4.tcp_window_scaling": "1",
        "net.ipv4.tcp_timestamps": "1",
    }

    notes = (
        f"Link speed: {link_speed_bps / 1e9:.3f} Gbps | Design RTT: {design_rtt_ms} ms | MemTotal: {ram_bytes} bytes",
        cc_reason,
        f"advising default_qdisc={qdisc} for cc={cc}",
    )

    return SysctlPlan(
        params=params,
        suggested_modules=suggested_mods,
        notes=notes,
    )


def render_sysctl_conf(plan: SysctlPlan, advisory_only: bool = True) -> str:
    header = (
        "# Advisory only (no changes applied, no modules loaded)"
        if advisory_only
        else "# Managed by NMS sysctl auto-tuner (deterministic)"
    )
    lines = [header]
    for note in plan.notes:
        lines.append(f"# {note}")

    if plan.suggested_modules:
        mods_str = ", ".join(plan.suggested_modules)
        lines.append(f"# NOTICE: Suggested kernel modules not currently loaded: {mods_str}")
        lines.append(f"# To load manually: modprobe {' '.join(plan.suggested_modules)}")
    else:
        lines.append("# NOTICE: No additional kernel modules required.")

    lines.append("")
    for key in sorted(plan.params.keys()):
        lines.append(f"{key} = {plan.params[key]}")
    return "\n".join(lines) + "\n"


def apply_sysctl_conf(conf_text: str, path: str = DEF_SYSCTLF ) -> None:
    tmp_path = f"{path}.tmp.{os.getpid()}"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(conf_text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Deterministically generate (and optionally apply) sysctl network tuning for NMS nodes."
    )
    parser.add_argument(
        "--link-speed",
        default="10Gb",
        help=(
            "Target interface speed with optional SI (k, M, G, T, P) or IEC "
            "(Ki, Mi, Gi, Ti, Pi) prefix. Lowercase 'b' = bits, uppercase 'B' = bytes "
            "(e.g., 10Gb, 10Gbps, 1.25GB/s, 900MiB/s, 10G). Default: 10Gb."
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
        default=DEF_SYSCTLF,
        help="Destination sysctl drop-in path when --apply is used. Default: "+DEF_SYSCTLF,
    )
    parser.add_argument(
        "--no-modprobe-check",
        action="store_true",
        help="Skip read-only `modprobe --dry-run` availability checks.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write the sysctl file (does not apply changes to the running kernel)",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    advisory_only = not args.apply

    link_bps = parse_link_speed_bps(args.link_speed)
    ram_bytes = read_meminfo_bytes(args.meminfo_path)

    plan = build_sysctl_plan(
        link_speed_bps=link_bps,
        design_rtt_ms=args.rtt_ms,
        total_ram_bytes=ram_bytes,
        allow_modprobe_check=not args.no_modprobe_check,
    )
    conf_text = render_sysctl_conf(plan, advisory_only=advisory_only)

    if advisory_only:
        print(conf_text, end="")
    else:
        apply_sysctl_conf(conf_text, path=args.out_file)


if __name__ == "__main__":
    main()
