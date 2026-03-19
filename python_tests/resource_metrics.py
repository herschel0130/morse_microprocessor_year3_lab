"""Parse MPLAB map files into code and RAM summaries."""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
import re
from typing import Iterable


HEX_LENGTH_RE = re.compile(r"^\s+\S+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+([0-9A-Fa-f]+)\s+")


@dataclass(frozen=True)
class MapMetric:
    """Resource metrics extracted from one map file."""

    algorithm: str
    map_path: str
    code_bytes: int
    comram_bytes: int
    banked_ram_bytes: int
    total_tracked_ram_bytes: int


DEFAULT_MAPS = {
    "playback_harness": Path(
        "/Users/herschel.liu/Downloads/LCD-interrupt-test.X/dist/default/debug/LCD-interrupt-test.X.debug.map"
    ),
    "ema_a075": Path(
        "/Users/herschel.liu/Downloads/EMA (a=0.75).X/dist/default/debug/non-adaptive.X.debug.map"
    ),
    "dual_ema": Path(
        "/Users/herschel.liu/Downloads/alog develop/dual EMA.X/dist/default/debug/non-adaptive.X.debug.map"
    ),
    "non_adaptive": Path(
        "/Users/herschel.liu/Downloads/算法测试microprocessor/non-adaptive.X/dist/default/debug/non-adaptive.X.debug.map"
    ),
}


def _parse_class_lengths(lines: list[str], class_name: str) -> int:
    total = 0
    inside_class = False

    for line in lines:
        if line.startswith("        CLASS"):
            inside_class = class_name in line
            continue
        if inside_class:
            if not line.strip():
                continue
            if line.startswith("SEGMENTS"):
                break
            match = HEX_LENGTH_RE.match(line)
            if match:
                total += int(match.group(1), 16)

    return total


def parse_map_file(map_path: Path, algorithm: str) -> MapMetric:
    """Extract code and RAM figures from a MPLAB map file."""

    lines = map_path.read_text(encoding="ascii", errors="ignore").splitlines()
    code_bytes = _parse_class_lengths(lines, "CODE")
    comram_bytes = _parse_class_lengths(lines, "COMRAM")

    banked_ram_bytes = 0
    for bank_index in range(16):
        banked_ram_bytes += _parse_class_lengths(lines, f"BANK{bank_index}")

    return MapMetric(
        algorithm=algorithm,
        map_path=str(map_path),
        code_bytes=code_bytes,
        comram_bytes=comram_bytes,
        banked_ram_bytes=banked_ram_bytes,
        total_tracked_ram_bytes=comram_bytes + banked_ram_bytes,
    )


def collect_default_metrics() -> list[MapMetric]:
    """Parse every default map file that currently exists."""

    metrics: list[MapMetric] = []
    for algorithm, map_path in DEFAULT_MAPS.items():
        if map_path.exists():
            metrics.append(parse_map_file(map_path, algorithm))
    return metrics


def write_metrics_csv(metrics: Iterable[MapMetric], output_path: Path) -> Path:
    """Write parsed map metrics to CSV."""

    rows = [metric.__dict__ for metric in metrics]
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with output_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "algorithm",
                "map_path",
                "code_bytes",
                "comram_bytes",
                "banked_ram_bytes",
                "total_tracked_ram_bytes",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)
    return output_path


def main() -> None:
    """Parse known map files and print their output path."""

    import argparse

    parser = argparse.ArgumentParser(description="Parse MPLAB map files into CSV resource metrics.")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("artifacts/reports/resource_summary.csv"),
        help="CSV output path.",
    )
    args = parser.parse_args()

    metrics = collect_default_metrics()
    output = write_metrics_csv(metrics, args.output)
    print(output)


if __name__ == "__main__":
    main()
