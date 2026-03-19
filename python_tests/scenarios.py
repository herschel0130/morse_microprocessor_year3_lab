"""Scenario definitions for the UART playback harness."""

from __future__ import annotations

from dataclasses import dataclass
import random
from typing import Callable


MORSE_TABLE = {
    "A": ".-",
    "B": "-...",
    "C": "-.-.",
    "D": "-..",
    "E": ".",
    "F": "..-.",
    "G": "--.",
    "H": "....",
    "I": "..",
    "J": ".---",
    "K": "-.-",
    "L": ".-..",
    "M": "--",
    "N": "-.",
    "O": "---",
    "P": ".--.",
    "Q": "--.-",
    "R": ".-.",
    "S": "...",
    "T": "-",
    "U": "..-",
    "V": "...-",
    "W": ".--",
    "X": "-..-",
    "Y": "-.--",
    "Z": "--..",
    "0": "-----",
    "1": ".----",
    "2": "..---",
    "3": "...--",
    "4": "....-",
    "5": ".....",
    "6": "-....",
    "7": "--...",
    "8": "---..",
    "9": "----.",
}


@dataclass(frozen=True)
class Scenario:
    """A repeatable timing scenario."""

    name: str
    target_text: str
    description: str
    samples: tuple[int, ...]
    expected_elements: str
    unit_schedule: tuple[int, ...]
    change_element_index: int | None = None

    @property
    def sample_count(self) -> int:
        """Return the number of 10 ms ticks in the waveform."""

        return len(self.samples)


def _normalize_text(text: str) -> str:
    normalized = " ".join(text.upper().split())
    unsupported = sorted({char for char in normalized if char != " " and char not in MORSE_TABLE})
    if unsupported:
        raise ValueError(f"Unsupported characters for Morse playback: {unsupported}")
    return normalized


def _append_ticks(samples: list[int], value: int, ticks: int) -> None:
    if ticks <= 0:
        raise ValueError("Every waveform duration must be at least one tick.")
    samples.extend([value] * ticks)


def _build_samples(
    text: str,
    unit_for_char: Callable[[int, str], int],
) -> tuple[tuple[int, ...], str, tuple[int, ...]]:
    text = _normalize_text(text)
    samples: list[int] = []
    expected_elements: list[str] = []
    unit_schedule: list[int] = []

    encoded_chars = [char for char in text if char != " "]
    char_index = 0

    for text_index, char in enumerate(text):
        if char == " ":
            if samples:
                _append_ticks(samples, 0, 7 * unit_schedule[-1])
            continue

        code = MORSE_TABLE[char]
        unit_ticks = int(unit_for_char(char_index, char))
        if unit_ticks <= 0:
            raise ValueError("Unit ticks must stay positive.")

        unit_schedule.append(unit_ticks)
        for symbol_index, symbol in enumerate(code):
            press_ticks = unit_ticks if symbol == "." else 3 * unit_ticks
            _append_ticks(samples, 1, press_ticks)
            expected_elements.append(symbol)

            if symbol_index < len(code) - 1:
                _append_ticks(samples, 0, unit_ticks)

        if text_index < len(text) - 1 and text[text_index + 1] != " ":
            _append_ticks(samples, 0, 3 * unit_ticks)

        char_index += 1

    return tuple(samples), "".join(expected_elements), tuple(unit_schedule)


def constant_speed(name: str, text: str, unit_ticks: int) -> Scenario:
    """Build a constant-speed Morse waveform."""

    samples, expected, unit_schedule = _build_samples(
        text,
        unit_for_char=lambda _index, _char: unit_ticks,
    )
    return Scenario(
        name=name,
        target_text=_normalize_text(text),
        description=f"Constant speed with {unit_ticks} ticks per dot unit.",
        samples=samples,
        expected_elements=expected,
        unit_schedule=unit_schedule,
    )


def abrupt_shift(
    name: str,
    text_before: str,
    text_after: str,
    slow_unit_ticks: int,
    fast_unit_ticks: int,
) -> Scenario:
    """Build a two-phase speed shift scenario."""

    before = _normalize_text(text_before)
    after = _normalize_text(text_after)
    target_text = f"{before} {after}"
    change_element_index = len("".join(MORSE_TABLE[char] for char in before if char != " "))

    def unit_for_char(index: int, _char: str) -> int:
        split_index = len([char for char in before if char != " "])
        return slow_unit_ticks if index < split_index else fast_unit_ticks

    samples, expected, unit_schedule = _build_samples(target_text, unit_for_char)
    return Scenario(
        name=name,
        target_text=target_text,
        description=(
            f"Abrupt change from {slow_unit_ticks} ticks to {fast_unit_ticks} ticks "
            "per dot unit."
        ),
        samples=samples,
        expected_elements=expected,
        unit_schedule=unit_schedule,
        change_element_index=change_element_index,
    )


def gradual_shift(
    name: str,
    text: str,
    start_unit_ticks: int,
    end_unit_ticks: int,
) -> Scenario:
    """Build a linearly changing speed profile across the message."""

    normalized = _normalize_text(text)
    chars = [char for char in normalized if char != " "]
    total = max(len(chars) - 1, 1)

    def unit_for_char(index: int, _char: str) -> int:
        fraction = index / total
        ticks = round(start_unit_ticks + (end_unit_ticks - start_unit_ticks) * fraction)
        return max(1, ticks)

    samples, expected, unit_schedule = _build_samples(normalized, unit_for_char)
    return Scenario(
        name=name,
        target_text=normalized,
        description=(
            f"Gradual drift from {start_unit_ticks} ticks to {end_unit_ticks} ticks "
            "per dot unit."
        ),
        samples=samples,
        expected_elements=expected,
        unit_schedule=unit_schedule,
    )


def jittered(
    name: str,
    text: str,
    base_unit_ticks: int,
    jitter_fraction: float,
    seed: int,
) -> Scenario:
    """Build a waveform with per-character timing jitter."""

    rng = random.Random(seed)

    def unit_for_char(_index: int, _char: str) -> int:
        jitter = rng.uniform(-jitter_fraction, jitter_fraction)
        ticks = round(base_unit_ticks * (1.0 + jitter))
        return max(1, ticks)

    samples, expected, unit_schedule = _build_samples(text, unit_for_char)
    return Scenario(
        name=name,
        target_text=_normalize_text(text),
        description=(
            f"Jittered timing around {base_unit_ticks} ticks with +/-{jitter_fraction:.0%} "
            f"variation and seed {seed}."
        ),
        samples=samples,
        expected_elements=expected,
        unit_schedule=unit_schedule,
    )


def default_scenarios() -> list[Scenario]:
    """Return a balanced starter set for algorithm comparison."""

    return [
        constant_speed("const_sos", "SOS", unit_ticks=4),
        constant_speed("const_hello", "HELLO", unit_ticks=5),
        abrupt_shift(
            "shift_slow_to_fast",
            text_before="MORSE",
            text_after="TEST",
            slow_unit_ticks=7,
            fast_unit_ticks=3,
        ),
        abrupt_shift(
            "shift_fast_to_slow",
            text_before="TEST",
            text_after="MORSE",
            slow_unit_ticks=3,
            fast_unit_ticks=7,
        ),
        gradual_shift("gradual_ramp", "SIGNAL", start_unit_ticks=7, end_unit_ticks=3),
        jittered("jitter_20", "ADAPT", base_unit_ticks=5, jitter_fraction=0.20, seed=7),
    ]


def scenario_by_name(name: str) -> Scenario:
    """Look up a default scenario by name."""

    for scenario in default_scenarios():
        if scenario.name == name:
            return scenario
    raise KeyError(f"Unknown scenario: {name}")
