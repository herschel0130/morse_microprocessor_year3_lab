"""Serial utilities for the UART playback harness.

The harness consumes one waveform sample every 10 ms. The helpers in this file
keep the PIC ring buffer moderately full without overwhelming it, then wait for
the firmware's `DONE` marker before returning the captured log text.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
import select
import termios
import time
from typing import Iterable


BAUD_RATES = {
    9600: termios.B9600,
    19200: termios.B19200,
    38400: termios.B38400,
    57600: termios.B57600,
    115200: termios.B115200,
}


@dataclass(frozen=True)
class SerialConfig:
    """Configuration for the host serial connection."""

    port: str
    baudrate: int = 9600
    slot_seconds: float = 0.01
    lead_ticks: int = 48
    send_chunk_size: int = 8
    read_chunk_size: int = 4096


class SerialPort:
    """A small stdlib-only serial wrapper for macOS/Linux tty devices."""

    def __init__(self, config: SerialConfig) -> None:
        self.config = config
        self._fd: int | None = None
        self._saved_attrs: list | None = None

    def __enter__(self) -> "SerialPort":
        self.open()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    @property
    def fd(self) -> int:
        """Return the open file descriptor."""

        if self._fd is None:
            raise RuntimeError("Serial port is not open.")
        return self._fd

    def open(self) -> None:
        """Open the tty device in raw mode."""

        if self._fd is not None:
            return

        if self.config.baudrate not in BAUD_RATES:
            raise ValueError(f"Unsupported baudrate: {self.config.baudrate}")

        fd = os.open(self.config.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        attrs = termios.tcgetattr(fd)
        self._saved_attrs = attrs[:]

        attrs[0] = 0
        attrs[1] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[3] = 0
        attrs[4] = BAUD_RATES[self.config.baudrate]
        attrs[5] = BAUD_RATES[self.config.baudrate]
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 0

        termios.tcflush(fd, termios.TCIOFLUSH)
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        self._fd = fd

    def close(self) -> None:
        """Close the tty device and restore previous terminal settings."""

        if self._fd is None:
            return

        if self._saved_attrs is not None:
            try:
                termios.tcsetattr(self._fd, termios.TCSANOW, self._saved_attrs)
            except termios.error:
                pass

        os.close(self._fd)
        self._fd = None
        self._saved_attrs = None

    def write(self, payload: bytes) -> None:
        """Write every byte in payload to the serial device."""

        view = memoryview(payload)
        total_written = 0
        while total_written < len(payload):
            _, writable, _ = select.select([], [self.fd], [], 1.0)
            if not writable:
                continue
            written = os.write(self.fd, view[total_written:])
            total_written += written

    def read_available(self, timeout: float = 0.0) -> bytes:
        """Read any bytes currently available from the serial device."""

        readable, _, _ = select.select([self.fd], [], [], timeout)
        if not readable:
            return b""
        return os.read(self.fd, self.config.read_chunk_size)

    def drain_input(self, idle_seconds: float = 0.2, timeout: float = 2.0) -> str:
        """Drain pending device output until the line becomes quiet."""

        deadline = time.monotonic() + timeout
        quiet_deadline = time.monotonic() + idle_seconds
        chunks = bytearray()

        while time.monotonic() < deadline:
            chunk = self.read_available(timeout=0.05)
            if chunk:
                chunks.extend(chunk)
                quiet_deadline = time.monotonic() + idle_seconds
                continue
            if time.monotonic() >= quiet_deadline:
                break

        return chunks.decode("ascii", errors="ignore")

    def wait_for_line(self, expected: str, timeout: float) -> str:
        """Wait until a complete line exactly matches the expected token."""

        deadline = time.monotonic() + timeout
        text_buffer = ""

        while time.monotonic() < deadline:
            chunk = self.read_available(timeout=0.1)
            if not chunk:
                continue
            text_buffer += chunk.decode("ascii", errors="ignore")

            while "\n" in text_buffer:
                line, text_buffer = text_buffer.split("\n", 1)
                if line.rstrip("\r") == expected:
                    return expected

        raise TimeoutError(f"Timed out waiting for {expected!r}.")

    def stream_waveform(
        self,
        samples: Iterable[int],
        *,
        done_token: str = "DONE",
        timeout: float = 60.0,
    ) -> str:
        """Stream one waveform and return the captured ASCII log."""

        payload = bytes(samples)
        raw_log = bytearray()
        lead_ticks = max(1, self.config.lead_ticks)
        send_chunk_size = max(1, self.config.send_chunk_size)
        start = time.monotonic()
        sent = 0

        while sent < len(payload):
            raw_log.extend(self.read_available(timeout=0.0))

            elapsed_ticks = int((time.monotonic() - start) / self.config.slot_seconds)
            allowed = min(len(payload), elapsed_ticks + lead_ticks)
            if allowed <= sent:
                time.sleep(min(self.config.slot_seconds / 5.0, 0.002))
                continue

            chunk_end = min(allowed, sent + send_chunk_size)
            self.write(payload[sent:chunk_end])
            sent = chunk_end

        self.write(b"\xFF")
        return self._read_until_token(raw_log, done_token=done_token, timeout=timeout)

    def _read_until_token(
        self,
        raw_log: bytearray,
        *,
        done_token: str,
        timeout: float,
    ) -> str:
        """Read output until the firmware prints the requested line token."""

        deadline = time.monotonic() + timeout
        text_buffer = raw_log.decode("ascii", errors="ignore")
        lines = [line.rstrip("\r") for line in text_buffer.split("\n")]

        while time.monotonic() < deadline:
            chunk = self.read_available(timeout=0.1)
            if not chunk:
                continue

            raw_log.extend(chunk)
            text_buffer += chunk.decode("ascii", errors="ignore")
            lines = [line.rstrip("\r") for line in text_buffer.split("\n")]
            if done_token in lines:
                return raw_log.decode("ascii", errors="ignore")

        raise TimeoutError(f"Timed out waiting for {done_token!r}.")


def encode_samples(samples: Iterable[int]) -> bytes:
    """Convert an iterable of 0/1 ticks into bytes for the harness."""

    encoded = bytearray()
    for value in samples:
        if value not in (0, 1):
            raise ValueError(f"Waveform samples must be 0 or 1, got {value!r}.")
        encoded.append(value)
    return bytes(encoded)
