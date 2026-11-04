#!/usr/bin/env python3
"""Exercise the trial entry points with a vendor-command fixture, without Wine."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(sys.argv.pop(1) if len(sys.argv) > 1 else "dylib/feats/compat_run.sh").resolve()


class TrialCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="notproton-trial-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "CrossOver Trial's App" / "CrossOver"
        self.vendor = self.source / "bin" / "wine"
        self.vendor.parent.mkdir(parents=True)
        self.vendor.write_text("""#!/bin/sh
set -e
[ -z "${WINEPREFIX+x}${WINELOADER+x}${WINESERVER+x}${CX_INITIALIZED+x}${CX_ENV+x}${CX_BOTTLE+x}${DYLD_INSERT_LIBRARIES+x}" ] || exit 91
[ "$LC_ALL" = C ] && [ "$LANG" = C ] || exit 92
printf '%s\\n' "$@" > "$TRIAL_TEST_ARGS"
if [ "${TRIAL_TEST_HANG:-0}" = 1 ]; then exec sleep 90; fi
printf '%s' "$TRIAL_TEST_OUTPUT"
exit "${TRIAL_TEST_EXIT:-0}"
""")
        self.vendor.chmod(0o755)
        self.runner = self.root / "runner" / "CrossOver"
        self.runner.mkdir(parents=True)
        self.marker = self.runner / "notproton-trial"
        self.args = self.root / "args"

    def invoke(self, *arguments, output="Demo version (7 days remaining)\n", status=0, hang=False):
        environment = dict(os.environ)
        environment.update({
            "TMPDIR": str(self.root),
            "TRIAL_TEST_ARGS": str(self.args),
            "TRIAL_TEST_OUTPUT": output,
            "TRIAL_TEST_EXIT": str(status),
            "TRIAL_TEST_HANG": "1" if hang else "0",
            "WINEPREFIX": "must-not-inherit",
            "WINELOADER": "must-not-inherit",
            "WINESERVER": "must-not-inherit",
            "CX_INITIALIZED": "must-not-inherit",
            "CX_ENV": "must-not-inherit",
            "CX_BOTTLE": "must-not-inherit",
        })
        return subprocess.run(
            ["/bin/sh", str(SCRIPT), *map(str, arguments)],
            env=environment, cwd=self.root, capture_output=True, text=True, timeout=40,
        )

    def check(self, **kwargs):
        return self.invoke("check-trial", self.source, "Steam", **kwargs)

    def test_active_status_and_environment(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "7\n")
        self.assertEqual(self.args.read_text().splitlines(), [
            "--bottle", "Steam", "--no-gui", "--no-update", "--no-lock", "--demo-status",
        ])

    def test_windows_newlines_and_blank_lines(self):
        result = self.check(output="\r\nDemo version (14 days remaining)\r\n\r\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "14\n")

    def test_expired_ambiguous_and_unknown_statuses_are_rejected(self):
        for output in [
            "Demo version (expired 1 days ago)\n",
            "Demo version (expired 0 days ago)\n",
            "Demo version (0 days remaining)\n",
            "Demo version (-1 days remaining)\n",
            "Demo version (+1 days remaining)\n",
            "Demo version (01 days remaining)\n",
            "Demo version (2147483648 days remaining)\n",
            "Standard version\n",
            "",
            "CrossOver could not be started\n",
            "Demo version (7 days remaining)\nStandard version\n",
            "Demo version (7 days remaining)\nDemo version (expired 1 days ago)\n",
            "Demo version (7 days remaining)\nDemo version (7 days remaining)\n",
        ]:
            with self.subTest(output=output):
                result = self.check(output=output)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_success_text_with_failed_command_is_rejected(self):
        result = self.check(status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_arguments_are_not_shell_code(self):
        bottle = "Steam; 'quoted' $(touch NEVER) `touch NEVER`"
        result = self.invoke("check-trial", self.source, bottle)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.args.read_text().splitlines()[1], bottle)
        self.assertFalse((self.root / "NEVER").exists())

    def test_missing_source_empty_bottle_and_multiline_inputs(self):
        for source, bottle in [
            (self.root / "missing", "Steam"),
            ("relative", "Steam"),
            (self.source, ""),
            (self.source, " \t "),
            (self.source, "Steam\nsecond line"),
            (self.source, "Steam\rsecond line"),
            (str(self.source) + "\n", "Steam"),
        ]:
            with self.subTest(source=source, bottle=bottle):
                self.assertNotEqual(self.invoke("check-trial", source, bottle).returncode, 0)
        self.assertFalse(self.args.exists())

    def test_absolute_bottle_must_already_be_initialized(self):
        bottle = self.root / "Existing Bottle"
        bottle.mkdir()
        self.assertNotEqual(self.invoke("check-trial", self.source, bottle).returncode, 0)
        self.assertFalse(self.args.exists())
        (bottle / "system.reg").write_text("fixture")
        self.assertEqual(self.invoke("check-trial", self.source, bottle).returncode, 0)

    def test_paid_runner_does_not_query_trial(self):
        result = self.invoke("check-trial-runner", self.runner)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertFalse(self.args.exists())

    def test_runner_rechecks_expiration(self):
        self.marker.write_text(f"{self.source}\nSteam\n")
        active = self.invoke("check-trial-runner", self.runner)
        self.assertEqual(active.returncode, 0, active.stderr)
        self.assertEqual(active.stdout, "7\n")
        expired = self.invoke("check-trial-runner", self.runner, output="Demo version (expired 1 days ago)\n")
        self.assertNotEqual(expired.returncode, 0)
        self.assertEqual(expired.stdout, "")

    def test_malformed_records_are_not_treated_as_paid(self):
        for body in ["", str(self.source), f"{self.source}\n", f"{self.source}\nSteam",
                     f"{self.source}\nSteam\n\n", f"{self.source}\nSteam\nextra",
                     f"{self.source}\n\n", f"{self.source}\n \t \n",
                     f"{self.source}\nSte\0am\n", "relative\nSteam\n"]:
            with self.subTest(body=body):
                self.marker.write_text(body)
                self.assertNotEqual(self.invoke("check-trial-runner", self.runner).returncode, 0)
        self.marker.unlink()
        self.marker.symlink_to(self.root / "missing-marker")
        self.assertNotEqual(self.invoke("check-trial-runner", self.runner).returncode, 0)
        self.marker.unlink()
        valid_marker = self.root / "valid-marker"
        valid_marker.write_text(f"{self.source}\nSteam\n")
        self.marker.symlink_to(valid_marker)
        self.assertNotEqual(self.invoke("check-trial-runner", self.runner).returncode, 0)

    def test_status_command_times_out(self):
        result = self.check(hang=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("timed out", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
