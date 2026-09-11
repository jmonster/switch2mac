"""Exercise the release test shell runner without Apple's signing tools.

The command doubles select each OS branch and reach the real Python import.
Real Mach-O/signature validation remains in tests/release/run.sh on macOS CI.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseRunnerTests(unittest.TestCase):
    def test_no_generated_files_in_source_for_either_os_branch(self):
        for system in ("Linux", "Darwin"):
            with self.subTest(system=system), tempfile.TemporaryDirectory() as tmp:
                checkout = Path(tmp) / "checkout"
                suite = checkout / "tests/release"
                scripts = checkout / "scripts"
                tools = Path(tmp) / "bin"
                for path in (suite, scripts, tools):
                    path.mkdir(parents=True)
                shutil.copy2(ROOT / "tests/release/run.sh", suite / "run.sh")
                shutil.copy2(ROOT / "scripts/notarize-release.py", scripts / "notarize-release.py")
                # Isolate the shell runner; the complete unit suite runs separately.
                (suite / "test_release.py").write_text("print('unit-test placeholder')\n")
                doubles = {
                    "uname": f"#!/bin/sh\nprintf '%s\\n' '{system}'\n",
                    "clang": '#!/bin/sh\nwhile [ "$#" -gt 1 ]; do shift; done\n: > "$1"\n',
                    "codesign": "#!/bin/sh\nprintf 'Signature=adhoc\\n' >&2\n",
                }
                for name, content in doubles.items():
                    command = tools / name
                    command.write_text(content)
                    command.chmod(0o755)
                before = {p.relative_to(checkout) for p in checkout.rglob("*")}
                env = os.environ.copy()
                # The runner itself must protect every child interpreter, not
                # depend on a CI job or the invoking user's shell doing so.
                env.pop("PYTHONDONTWRITEBYTECODE", None)
                env.pop("PYTHONPYCACHEPREFIX", None)
                env["PATH"] = str(tools) + os.pathsep + env.get("PATH", "")
                result = subprocess.run(["bash", str(suite / "run.sh")], cwd=checkout,
                                        env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if system == "Darwin":
                    self.assertIn("ad-hoc signature rejection", result.stdout)
                after = {p.relative_to(checkout) for p in checkout.rglob("*")}
                self.assertEqual(after, before,
                                 "The test runner generated files in the source checkout")


if __name__ == "__main__":
    unittest.main()
