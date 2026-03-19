"""Parse UART playback logs into CSV datasets."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import csv
import json
from pathlib import Path
import statistics
from typing import Iterable


@dataclass(frozen=True)
class RunMetadata:
    """Metadata recorded before a run starts."""

    algorithm: str
    scenario: str
    trial: int
    target_text: str
    expected_elements: str
    raw_log_path: str
    change_element_index: int | None = None


@dataclass(frozen=True)
class ParsedRun:
    """Summary metrics for one completed run."""

    algorithm: str
    scenario: str
    trial: int
    target_text: str
    decoded_text: str
    expected_elements: str
    observed_elements: str
    ready_seen: int
    done_seen: int
    overrun_seen: int
    character_exact: int
    character_accuracy: float
    element_accuracy: float
    char_edit_distance: int
    element_edit_distance: int
    adaptation_elements: int | None
    raw_log_path: str


def _normalize_text(text: str) -> str:
    return "".join(text.upper().split())


def levenshtein_distance(left: str, right: str) -> int:
    """Compute edit distance with a classic dynamic-programming table."""

    if left == right:
        return 0
    if not left:
        return len(right)
    if not right:
        return len(left)

    previous = list(range(len(right) + 1))
    current = [0] * (len(right) + 1)

    for left_index, left_char in enumerate(left, start=1):
        current[0] = left_index
        for right_index, right_char in enumerate(right, start=1):
            substitution_cost = 0 if left_char == right_char else 1
            current[right_index] = min(
                previous[right_index] + 1,
                current[right_index - 1] + 1,
                previous[right_index - 1] + substitution_cost,
            )
        previous, current = current, previous

    return previous[-1]


def _ratio_from_distance(distance: int, reference_length: int) -> float:
    if reference_length <= 0:
        return 1.0
    return max(0.0, 1.0 - (distance / reference_length))


def _adaptation_elements(
    expected: str,
    observed: str,
    *,
    change_index: int | None,
    window: int = 3,
) -> int | None:
    if change_index is None:
        return None

    limit = min(len(expected), len(observed))
    if change_index >= limit:
        return None

    stable_window = max(1, window)
    stop_index = max(change_index + 1, limit - stable_window + 2)
    for index in range(change_index, stop_index):
        if expected[index : index + stable_window] == observed[index : index + stable_window]:
            return index - change_index
    return None


def parse_run_log(metadata: RunMetadata, raw_text: str) -> tuple[ParsedRun, list[dict[str, object]]]:
    """Parse one raw UART transcript into event rows and a run summary."""

    lines = [line.strip("\r") for line in raw_text.splitlines()]
    decoded_chars: list[str] = []
    observed_elements: list[str] = []
    event_rows: list[dict[str, object]] = []

    ready_seen = 0
    done_seen = 0
    overrun_seen = 0

    for event_index, line in enumerate(lines):
        if not line:
            continue

        event_type = "other"
        value = line

        if line == "READY":
            ready_seen = 1
            event_type = "ready"
        elif line == "DONE":
            done_seen = 1
            event_type = "done"
        elif line == "OVERRUN":
            overrun_seen = 1
            event_type = "error"
        elif line == "DOT":
            observed_elements.append(".")
            event_type = "element"
            value = "."
        elif line == "DASH":
            observed_elements.append("-")
            event_type = "element"
            value = "-"
        elif line.startswith(" = ") and len(line) >= 4:
            decoded_chars.append(line[3])
            event_type = "char"
            value = line[3]

        event_rows.append(
            {
                "algorithm": metadata.algorithm,
                "scenario": metadata.scenario,
                "trial": metadata.trial,
                "event_index": event_index,
                "event_type": event_type,
                "value": value,
                "raw_log_path": metadata.raw_log_path,
            }
        )

    expected_text = _normalize_text(metadata.target_text)
    decoded_text = "".join(decoded_chars)
    observed_element_string = "".join(observed_elements)

    char_distance = levenshtein_distance(expected_text, decoded_text)
    element_distance = levenshtein_distance(metadata.expected_elements, observed_element_string)

    parsed = ParsedRun(
        algorithm=metadata.algorithm,
        scenario=metadata.scenario,
        trial=metadata.trial,
        target_text=expected_text,
        decoded_text=decoded_text,
        expected_elements=metadata.expected_elements,
        observed_elements=observed_element_string,
        ready_seen=ready_seen,
        done_seen=done_seen,
        overrun_seen=overrun_seen,
        character_exact=int(expected_text == decoded_text),
        character_accuracy=_ratio_from_distance(char_distance, max(len(expected_text), len(decoded_text))),
        element_accuracy=_ratio_from_distance(
            element_distance,
            max(len(metadata.expected_elements), len(observed_element_string)),
        ),
        char_edit_distance=char_distance,
        element_edit_distance=element_distance,
        adaptation_elements=_adaptation_elements(
            metadata.expected_elements,
            observed_element_string,
            change_index=metadata.change_element_index,
        ),
        raw_log_path=metadata.raw_log_path,
    )
    return parsed, event_rows


def write_rows_csv(path: Path, rows: Iterable[dict[str, object]]) -> None:
    """Write a list of dictionaries to a CSV file."""

    rows = list(rows)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="ascii")
        return

    with path.open("w", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def parse_manifest(manifest_path: Path, output_dir: Path) -> tuple[Path, Path]:
    """Parse every run in the manifest and export summary/event CSV files."""

    with manifest_path.open("r", newline="", encoding="ascii") as handle:
        manifest_rows = list(csv.DictReader(handle))

    parsed_runs: list[dict[str, object]] = []
    parsed_events: list[dict[str, object]] = []

    for row in manifest_rows:
        raw_log_path = Path(row["raw_log_path"])
        metadata = RunMetadata(
            algorithm=row["algorithm"],
            scenario=row["scenario"],
            trial=int(row["trial"]),
            target_text=row["target_text"],
            expected_elements=row["expected_elements"],
            raw_log_path=row["raw_log_path"],
            change_element_index=(
                int(row["change_element_index"]) if row["change_element_index"] else None
            ),
        )
        parsed_run, event_rows = parse_run_log(
            metadata,
            raw_log_path.read_text(encoding="ascii", errors="ignore"),
        )
        parsed_runs.append(asdict(parsed_run))
        parsed_events.extend(event_rows)

    runs_path = output_dir / "runs.csv"
    events_path = output_dir / "events.csv"
    write_rows_csv(runs_path, parsed_runs)
    write_rows_csv(events_path, parsed_events)
    return runs_path, events_path


def summarize_runs(runs_csv: Path) -> dict[str, float]:
    """Return a tiny health summary for quick smoke checks."""

    with runs_csv.open("r", newline="", encoding="ascii") as handle:
        rows = list(csv.DictReader(handle))

    if not rows:
        return {
            "run_count": 0,
            "mean_character_accuracy": 0.0,
            "mean_element_accuracy": 0.0,
        }

    char_acc = [float(row["character_accuracy"]) for row in rows]
    elem_acc = [float(row["element_accuracy"]) for row in rows]
    return {
        "run_count": float(len(rows)),
        "mean_character_accuracy": statistics.fmean(char_acc),
        "mean_element_accuracy": statistics.fmean(elem_acc),
    }


def main() -> None:
    """Parse a manifest passed on the command line."""

    import argparse

    parser = argparse.ArgumentParser(description="Parse UART playback logs into CSV files.")
    parser.add_argument("manifest", type=Path, help="Manifest CSV generated by run_experiments.py")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("artifacts/parsed"),
        help="Directory for runs.csv and events.csv",
    )
    parser.add_argument(
        "--summary-json",
        type=Path,
        default=None,
        help="Optional JSON file for a short smoke-test summary.",
    )
    args = parser.parse_args()

    runs_path, _ = parse_manifest(args.manifest, args.output_dir)
    summary = summarize_runs(runs_path)
    if args.summary_json is not None:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(json.dumps(summary, indent=2), encoding="ascii")
    else:
        print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
