# UART Playback Tests

This folder contains the host-side test harness for `/Users/herschel.liu/Downloads/LCD-interrupt-test.X`.

## Wiring

- Flash `LCD-interrupt-test.X` to the PIC18 board.
- Connect `RH0` to `RD0`.
- Share ground between the board and the USB-UART adapter.
- Connect the host serial adapter to `RC6/TX1` and `RC7/RX1`.

## Firmware Protocol

The board prints line-oriented ASCII logs:

- `READY`: board is idle and ready for another run.
- `DOT` / `DASH`: one Morse element was classified.
- ` = X`: one character was decoded.
- `DONE`: the byte stream reached `0xFF` and playback ended cleanly.
- `OVERRUN`: the host filled the RX ring buffer too aggressively.

The host sends raw bytes:

- `0x01`: drive `RH0` high for one 10 ms playback slot.
- `0x00`: drive `RH0` low for one 10 ms playback slot.
- `0xFF`: terminate the current run.

## Timing Validation

This harness is an on-device playback path, not an independent external signal generator.

- The playback ISR and decoder share the same MCU and clock.
- Both playback and the main decoder loop are quantized to 10 ms slots, so there is no extra host-side timing quantization mismatch.
- The main remaining bias is ISR overhead, which is kept constant across all baseline variants if the same harness logic is reused.
- `OVERRUN` is treated as a failed run and should be excluded or re-run.

## Suggested Workflow

1. Flash one algorithm variant.
2. Run the Python driver with `--algorithm <label>`.
3. Repeat for every baseline firmware.
4. Aggregate all manifests and analyze the combined dataset.

## Example Commands

```bash
python3 run_experiments.py \
  --port /dev/tty.usbserial-0001 \
  --algorithm ema_a075 \
  --trials 5
```

```bash
python3 analyze_results.py
```

## File Guide

- `serial_driver.py`: stdlib-only serial driver and paced waveform streamer.
- `scenarios.py`: repeatable Morse timing scenarios.
- `run_experiments.py`: batch experiment runner.
- `parse_logs.py`: UART log parser that emits `runs.csv` and `events.csv`.
- `analyze_results.py`: summary tables and plots.
- `resource_metrics.py`: ROM/RAM summaries from MPLAB map files.
