"""Drive repeatable UART playback experiments from the host PC."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime
from pathlib import Path
import time

from parse_logs import parse_manifest
from scenarios import default_scenarios, scenario_by_name
from serial_driver import SerialConfig, SerialPort


def available_scenarios() -> dict[str, object]:
    """Return the default scenario set as a name-indexed mapping."""

    return {scenario.name: scenario for scenario in default_scenarios()}


def select_scenarios(names: list[str]) -> list[object]:
    """Resolve CLI scenario names into Scenario objects."""

    if not names:
        return default_scenarios()
    return [scenario_by_name(name) for name in names]


def append_manifest_row(manifest_path: Path, row: dict[str, object]) -> None:
    """Append one row to the run manifest."""

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    file_exists = manifest_path.exists() and manifest_path.stat().st_size > 0
    with manifest_path.open("a", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(row.keys()))
        if not file_exists:
            writer.writeheader()
        writer.writerow(row)


def run_trial(
    serial_port: SerialPort,
    *,
    algorithm: str,
    scenario,
    trial: int,
    raw_root: Path,
    manifest_path: Path,
) -> Path:
    """Run one scenario once and persist its raw log."""

    serial_port.drain_input()
    serial_port.wait_for_line("READY", timeout=5.0)

    raw_log = serial_port.stream_waveform(scenario.samples, timeout=90.0)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    raw_dir = raw_root / algorithm / scenario.name
    raw_dir.mkdir(parents=True, exist_ok=True)
    raw_path = raw_dir / f"trial_{trial:03d}_{timestamp}.txt"
    raw_path.write_text(raw_log, encoding="ascii")

    append_manifest_row(
        manifest_path,
        {
            "algorithm": algorithm,
            "scenario": scenario.name,
            "trial": trial,
            "target_text": scenario.target_text,
            "expected_elements": scenario.expected_elements,
            "change_element_index": (
                "" if scenario.change_element_index is None else scenario.change_element_index
            ),
            "raw_log_path": str(raw_path),
        },
    )
    return raw_path


def main() -> None:
    """CLI entry point for batch UART playback runs."""

    parser = argparse.ArgumentParser(description="Run UART playback experiments.")
    parser.add_argument("--port", required=True, help="Serial device, for example /dev/tty.usbserial-0001")
    parser.add_argument("--algorithm", required=True, help="Algorithm label for this flashed firmware.")
    parser.add_argument(
        "--scenario",
        action="append",
        default=[],
        help="Scenario name to run. Repeat the flag to select multiple scenarios.",
    )
    parser.add_argument("--trials", type=int, default=3, help="Trials per scenario.")
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        default=Path("artifacts"),
        help="Directory for manifests, raw logs, and parsed CSV files.",
    )
    parser.add_argument("--baudrate", type=int, default=9600, help="UART baudrate.")
    parser.add_argument("--slot-seconds", type=float, default=0.01, help="Playback tick duration.")
    parser.add_argument("--lead-ticks", type=int, default=48, help="Host-side ring buffer lead target.")
    args = parser.parse_args()

    selected_scenarios = select_scenarios(args.scenario)
    artifacts_dir = args.artifacts_dir
    manifest_path = artifacts_dir / "manifest.csv"
    raw_root = artifacts_dir / "raw"
    parsed_dir = artifacts_dir / "parsed"

    config = SerialConfig(
        port=args.port,
        baudrate=args.baudrate,
        slot_seconds=args.slot_seconds,
        lead_ticks=args.lead_ticks,
    )

    with SerialPort(config) as serial_port:
        for scenario in selected_scenarios:
            for trial in range(1, args.trials + 1):
                raw_path = run_trial(
                    serial_port,
                    algorithm=args.algorithm,
                    scenario=scenario,
                    trial=trial,
                    raw_root=raw_root,
                    manifest_path=manifest_path,
                )
                print(f"Saved raw log to {raw_path}")
                time.sleep(0.5)

    runs_csv, events_csv = parse_manifest(manifest_path, parsed_dir)
    print(f"Parsed runs: {runs_csv}")
    print(f"Parsed events: {events_csv}")


if __name__ == "__main__":
    main()
