import unittest
from unittest.mock import patch
from step_experiment import Link, StabilityWindow, parse_report


LINE = ("T=+0020.600C,SP=+0030.000C,U=-025.0%,S=R,F=0,"
        "H=020.0%,R=1,E=1,Q=65535\r\n")


class FakePort:
    def __init__(self, lines):
        self.lines = iter(lines)
        self.sent = []

    def write(self, data):
        self.sent.append(data)
        return len(data)

    def readline(self, size):
        return next(self.lines, b"")


class ExperimentTests(unittest.TestCase):
    def test_parse_units_and_firmware_version(self):
        sample = parse_report(LINE)
        self.assertEqual(sample.temperature, 20.6)
        self.assertEqual(sample.pwm, -25)
        self.assertEqual(sample.heater_duty, 20)
        self.assertEqual(sample.sequence, 65535)
        self.assertIsNone(parse_report("T=+0020.600C,SP=+0030.000C,U=-025.0%,S=R,F=0"))

    def test_stable_duration_and_excursion(self):
        window = StabilityWindow(3, 0.3, 0.1)
        for second in range(3):
            self.assertFalse(window.update(second, 20, 20))
        self.assertTrue(window.update(3, 20, 20))
        self.assertFalse(window.update(4, 20.31, 20))
        self.assertFalse(window.update(5, 20, 20))

    def test_near_target_but_drifting_is_not_stable(self):
        window = StabilityWindow(3, 0.3, 0.1)
        for second in range(5):
            self.assertFalse(window.update(second, 20 + second * 0.01, 20))

    def test_sequence_wrap_duplicate_and_gap(self):
        first = LINE.encode()
        second = LINE.replace("65535", "00000").encode()
        gap = LINE.replace("65535", "00002").encode()
        link = Link(FakePort([first, first, second, gap]))
        self.assertTrue(link.read()[1])
        self.assertIsNone(link.read()[0])
        self.assertTrue(link.read()[1])
        self.assertFalse(link.read()[1])

    def test_fault_and_stale_abort(self):
        link = Link(FakePort([LINE.replace("F=0", "F=2").encode()]))
        with self.assertRaisesRegex(RuntimeError, "F=2"):
            link.read()
        link = Link(FakePort([]))
        with patch("step_experiment.time.monotonic", return_value=link.last_rx + 3):
            with self.assertRaisesRegex(RuntimeError, "fresh telemetry"):
                link.read()

    def test_stop_requires_all_outputs_off(self):
        off = ("T=+0020.600C,SP=+0030.000C,U=+000.0%,S=D,F=0,"
               "H=000.0%,R=0,E=0,Q=00000\r\n").encode()
        port = FakePort([off])
        self.assertTrue(Link(port).stop())
        self.assertEqual(port.sent[0], b"STOP\n")


if __name__ == "__main__":
    unittest.main()
