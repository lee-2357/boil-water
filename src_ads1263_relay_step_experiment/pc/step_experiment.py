"""Temperature staircase experiment for the B16 relay + ceramic heater firmware."""
import argparse
import csv
import math
import re
import statistics
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


REPORT = re.compile(
    r"T=([+-]\d+\.\d{3})C,SP=([+-]\d+\.\d{3})C,"
    r"U=([+-]\d+\.\d)%\,S=([WDRF]),F=(\d),"
    r"H=(\d+\.\d)%,R=([01]),E=([01]),Q=(\d+)"
)


@dataclass
class Sample:
    temperature: float
    target: float
    pwm: float
    state: str
    fault: int
    heater_duty: float
    relay_on: int
    enabled: int
    sequence: int


def parse_report(line):
    match = REPORT.fullmatch(line.strip())
    if not match:
        return None
    t, sp, pwm, state, fault, duty, relay, enabled, sequence = match.groups()
    sample = Sample(float(t), float(sp), float(pwm), state, int(fault),
                    float(duty), int(relay), int(enabled), int(sequence))
    if not (0 <= sample.sequence < 65536 and -80 <= sample.pwm <= 0
            and 0 <= sample.heater_duty <= 80):
        raise RuntimeError("Telemetry range mismatch; verify the relay firmware version")
    return sample


class StabilityWindow:
    def __init__(self, seconds, tolerance, slope_limit):
        self.seconds = seconds
        self.tolerance = tolerance
        self.slope_limit = slope_limit
        self.points = deque()

    def clear(self):
        self.points.clear()

    def update(self, now, temperature, target):
        if abs(temperature - target) > self.tolerance:
            self.clear()
            return False
        self.points.append((now, temperature))
        # Keep one point immediately preceding the window boundary.
        while len(self.points) > 2 and self.points[1][0] <= now - self.seconds:
            self.points.popleft()
        if len(self.points) < 3 or now - self.points[0][0] < self.seconds:
            return False
        origin = self.points[0][0]
        xs = [p[0] - origin for p in self.points]
        ys = [p[1] for p in self.points]
        xm, ym = statistics.mean(xs), statistics.mean(ys)
        denominator = sum((x - xm) ** 2 for x in xs)
        slope = sum((x - xm) * (y - ym) for x, y in zip(xs, ys)) / denominator
        return abs(slope * 60) <= self.slope_limit


class DemoBoard:
    """Offline demonstration, never opens a serial port. Not measured data."""
    def __init__(self):
        self.target = self.temperature = 20.0
        self.enabled = 0
        self.sequence = 0
        self.last = time.monotonic()

    def write(self, data):
        text = data.decode("ascii").strip()
        if text == "STOP":
            self.enabled = 0
        elif text == "RUN":
            self.enabled = 1
        elif text != "PING":
            self.target = float(text)

    def readline(self, size=512):
        time.sleep(0.05)
        now = time.monotonic()
        dt, self.last = now - self.last, now
        if self.enabled:
            self.temperature += (self.target - self.temperature) * (1 - math.exp(-dt * 10))
        duty = 20.0 if self.enabled else 0.0
        relay = int(self.enabled and now % 20 < 4)
        line = (f"T={self.temperature:+09.3f}C,SP={self.target:+09.3f}C,"
                f"U={-duty:+06.1f}%,S={'R' if self.enabled else 'D'},F=0,"
                f"H={duty:05.1f}%,R={relay},E={self.enabled},Q={self.sequence:05d}\r\n")
        self.sequence = (self.sequence + 1) % 65536
        return line.encode("ascii")

    def close(self):
        pass


class Link:
    def __init__(self, port):
        self.port = port
        self.last_rx = time.monotonic()
        self.last_ping = 0
        self.sequence = None

    def send(self, text):
        data = (text + "\n").encode("ascii")
        written = self.port.write(data)
        if written is not None and written != len(data):
            raise RuntimeError("Incomplete serial write")

    def read(self, allow_fault=False):
        now = time.monotonic()
        if now - self.last_ping >= 0.5 and now - self.last_rx < 1.5:
            self.send("PING")
            self.last_ping = now
        data = self.port.readline(512)
        sample = parse_report(data.decode("ascii", errors="replace"))
        now = time.monotonic()
        if now - self.last_rx > 2:
            raise RuntimeError("No fresh telemetry for 2 seconds; stopping experiment")
        if sample is None:
            return None, False
        if sample.sequence == self.sequence:
            return None, False
        continuous = self.sequence is None or sample.sequence == (self.sequence + 1) % 65536
        self.sequence = sample.sequence
        self.last_rx = now
        if sample.fault and not allow_fault:
            raise RuntimeError(f"FPGA fault F={sample.fault}; inspect hardware and reset KEY1")
        return sample, continuous

    def confirm(self, predicate, timeout, description):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            sample, _ = self.read()
            if sample is not None and predicate(sample):
                return sample
        raise RuntimeError("FPGA did not confirm " + description)

    def stop(self):
        """Wait for an explicit, fresh output-off report before closing."""
        deadline = time.monotonic() + 2
        self.send("STOP")
        last_send = time.monotonic()
        while time.monotonic() < deadline:
            sample, _ = self.read(allow_fault=True)
            if sample is not None and sample.enabled == 0 and sample.relay_on == 0 \
                    and sample.heater_duty == 0 and sample.pwm == 0:
                return True
            if time.monotonic() - last_send >= 0.5:
                self.send("STOP")
                last_send = time.monotonic()
        return False


def run_stage(link, target, args, raw_writer, raw_file, start):
    link.send(f"{target:.3f}")
    link.confirm(lambda s: abs(s.target - target) < 0.0005, 3, "setpoint")
    link.send("RUN")
    link.confirm(lambda s: s.enabled == 1 and s.state == "R", 3, "RUN")
    window = StabilityWindow(args.stable_seconds, args.tolerance,
                             args.max_slope_c_per_minute)
    deadline = time.monotonic() + args.stage_timeout
    sampling_since = None
    records = []
    last_message = 0
    print(f"Target {target:.3f} C: waiting for {args.stable_seconds:g} s stable temperature")
    while time.monotonic() < deadline:
        sample, continuous = link.read()
        if sample is None:
            continue
        now = time.monotonic()
        if sample.enabled != 1 or sample.state != "R":
            raise RuntimeError("FPGA stopped or lost valid temperature during experiment")
        if abs(sample.target - target) > 0.0005:
            raise RuntimeError("Setpoint changed unexpectedly; check other serial senders/reset")
        if not continuous:
            window.clear()
            sampling_since = None
            records.clear()
        stable = window.update(now, sample.temperature, target)
        if sampling_since is not None and not stable:
            print("Temperature left stability criteria; discarding partial sample and waiting again")
            sampling_since = None
            records.clear()
        if stable and sampling_since is None:
            sampling_since = now
            print(f"Target {target:g} C stable; collecting {args.sample_seconds:g} s")
        phase = "sample" if sampling_since is not None else "stabilize"
        raw_writer.writerow([datetime.now().isoformat(timespec="milliseconds"),
            f"{now-start:.3f}", target, phase, sample.temperature, sample.target,
            sample.pwm, sample.heater_duty, sample.relay_on, sample.enabled,
            sample.state, sample.fault, sample.sequence])
        raw_file.flush()
        if sampling_since is not None:
            records.append((now, sample))
            if now - sampling_since >= args.sample_seconds and len(records) >= 3:
                return summarize(target, records)
        if now - last_message >= 5:
            print(f"T={sample.temperature:.3f} C, ceramic PWM={-sample.pwm:.1f}%, "
                  f"relay window duty={sample.heater_duty:.1f}%, phase={phase}")
            last_message = now
    raise RuntimeError(f"Target {target:g} C did not finish before stage timeout; "
                       "both actuators heat only, so lower targets require natural cooling")


def summarize(target, records):
    samples = [s for _, s in records]
    temperatures = [s.temperature for s in samples]
    duration = records[-1][0] - records[0][0]
    # Left-hold integration of 0.5 s status samples is an estimate of actual ON time.
    relay_seconds = sum((t2 - t1) * s1.relay_on
                        for (t1, s1), (t2, _) in zip(records, records[1:]))
    return [target, len(samples), duration, statistics.mean(temperatures),
        statistics.pstdev(temperatures), min(temperatures), max(temperatures),
        statistics.mean(-s.pwm for s in samples),
        statistics.mean(s.heater_duty for s in samples), 100 * relay_seconds / duration]


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", help="FPGA PL USB-UART port, e.g. COM7")
    parser.add_argument("--targets", default="20,30,40,50,60,70")
    parser.add_argument("--stable-seconds", type=float, default=120)
    parser.add_argument("--sample-seconds", type=float, default=60)
    parser.add_argument("--tolerance", type=float, default=0.3)
    parser.add_argument("--max-slope-c-per-minute", type=float, default=0.1)
    parser.add_argument("--stage-timeout", type=float, default=1800)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "logs")
    parser.add_argument("--demo", action="store_true", help="offline synthetic data")
    args = parser.parse_args()
    try:
        args.targets = [float(t) for t in args.targets.split(",")]
    except ValueError:
        parser.error("targets must be comma-separated temperatures")
    if not args.targets or not all(math.isfinite(t) and 10 <= t <= 75 and
            abs(t * 1000 - round(t * 1000)) < 1e-6 for t in args.targets):
        parser.error("targets must be 10..75 C with at most 3 decimal places")
    if any(b <= a for a, b in zip(args.targets, args.targets[1:])):
        parser.error("targets must be strictly increasing")
    durations = [args.stable_seconds, args.sample_seconds, args.tolerance,
                 args.max_slope_c_per_minute, args.stage_timeout]
    if not all(math.isfinite(x) and x > 0 for x in durations):
        parser.error("durations and stability thresholds must be positive and finite")
    if not args.demo and (args.stable_seconds < 2 or args.sample_seconds < 2):
        parser.error("use at least 2 seconds for real-hardware stability/sampling")
    if args.stage_timeout <= args.stable_seconds + args.sample_seconds:
        parser.error("stage timeout must exceed stability plus sampling duration")
    if not args.demo and not args.port:
        parser.error("--port COMx required for hardware, or use --demo")
    return args


def main():
    args = arguments()
    name = datetime.now().strftime("%Y%m%d_%H%M%S_%f") + ("_DEMO" if args.demo else "")
    output = args.output / name
    output.mkdir(parents=True, exist_ok=False)
    if args.demo:
        port = DemoBoard()
        print("DEMO: synthetic data only")
    else:
        import serial
        port = serial.Serial(args.port, 115200, timeout=0.1, write_timeout=0.5)
    link = Link(port)
    exit_code = 0
    try:
        link.send("STOP")
        link.confirm(lambda s: s.state == "D" and s.enabled == 0, 10, "sensor-ready stopped state")
        start = time.monotonic()
        with (output / "raw.csv").open("w", newline="", encoding="utf-8-sig") as raw_file, \
                (output / "summary.csv").open("w", newline="", encoding="utf-8-sig") as summary_file:
            raw_writer, summary_writer = csv.writer(raw_file), csv.writer(summary_file)
            raw_writer.writerow(["time", "elapsed_s", "stage_target_C", "phase", "temperature_C",
                "board_setpoint_C", "ceramic_signed_PWM_percent", "relay_window_percent",
                "relay_on", "armed", "state", "fault", "sequence"])
            summary_writer.writerow(["target_C", "samples", "sample_duration_s", "mean_temperature_C",
                "std_temperature_C", "min_temperature_C", "max_temperature_C",
                "mean_ceramic_PWM_percent", "mean_relay_window_percent", "estimated_relay_ON_percent"])
            for target in args.targets:
                result = run_stage(link, target, args, raw_writer, raw_file, start)
                summary_writer.writerow(result)
                summary_file.flush()
                print(f"Recorded target {target:g} C: ceramic={result[7]:.2f}%, relay={result[8]:.2f}%")
    except KeyboardInterrupt:
        exit_code = 130
        print("Interrupted; stopping both heaters")
    except Exception as error:
        exit_code = 1
        print("Experiment aborted:", error)
    finally:
        try:
            if not link.stop():
                print("Output-off acknowledgement missing; FPGA heartbeat watchdog expires after 3 s")
                exit_code = exit_code or 1
            else:
                print("FPGA confirmed both heater outputs OFF")
        except Exception as error:
            print("STOP could not be confirmed:", error, "; FPGA watchdog requires 3 s without heartbeat")
            exit_code = exit_code or 1
        port.close()
    print("Results:", output)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
