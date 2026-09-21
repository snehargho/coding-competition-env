#!/usr/bin/env python3
"""NexGen Coding Competition 2026 - environment verification.

Checks Python, the required libraries, the C toolchain, and a compile smoke
test. Prints PASS/FAIL lines and appends them to setup-report.txt.

Usage:
    python3 verify.py [report-file]

Exit code 0 = all required checks passed, 1 = something needs attention.
Optional tools (git, bash, curl) only warn.
"""

import importlib.util
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import warnings

REQUIRED_IMPORTS = [
    ("PIL", "Pillow"),
    ("pygame", "pygame"),
    ("pandas", "pandas"),
    ("matplotlib", "matplotlib"),
    ("requests", "requests"),
    ("bs4", "beautifulsoup4"),
]
REQUIRED_COMMANDS = ["gcc", "make"]
OPTIONAL_COMMANDS = ["git", "bash", "curl"]

lines = []
failures = 0


def log(message, level="INFO"):
    global failures
    if level == "FAIL":
        failures += 1
    line = "[%s] %s" % (level, message)
    lines.append(line)
    print(line)


def run(cmd, cwd=None, timeout=180):
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            text=True,
        )
        return proc.returncode, (proc.stdout or "").strip()
    except FileNotFoundError:
        return 127, "not found"
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    except OSError as exc:
        return 126, str(exc)


def main():
    report_path = (
        sys.argv[1]
        if len(sys.argv) > 1
        else os.path.join(os.path.dirname(os.path.abspath(__file__)), "setup-report.txt")
    )

    os.environ.setdefault("MPLBACKEND", "Agg")
    mpl_cache = os.path.join(os.path.expanduser("~"), ".nexgen", "mplcache")
    try:
        os.makedirs(mpl_cache, exist_ok=True)
        os.environ.setdefault("MPLCONFIGDIR", mpl_cache)
    except OSError:
        pass
    os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
    os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
    os.environ.setdefault("PYGAME_HIDE_SUPPORT_PROMPT", "1")
    warnings.filterwarnings("ignore")

    log("verify.py on %s (%s)" % (platform.platform(), platform.machine()))

    if sys.version_info >= (3, 8):
        log("Python %s at %s" % (sys.version.split()[0], sys.executable), "PASS")
    else:
        log("Python 3.8+ required, found %s" % sys.version.split()[0], "FAIL")

    rc, out = run([sys.executable, "-m", "pip", "--version"])
    if rc == 0:
        log("pip: %s" % out.splitlines()[0], "PASS")
    else:
        log("pip is not available for this interpreter", "FAIL")

    for module, dist in REQUIRED_IMPORTS:
        try:
            imported = __import__(module)
            version = getattr(imported, "__version__", None)
            if version is None:
                try:
                    from importlib import metadata

                    version = metadata.version(dist)
                except Exception:
                    version = "installed"
            log("%s (%s) %s" % (module, dist, version), "PASS")
        except Exception as exc:
            log("%s (%s) import failed: %s" % (module, dist, exc), "FAIL")

    for command in REQUIRED_COMMANDS:
        path = shutil.which(command)
        if not path:
            log("%s not found on PATH" % command, "FAIL")
            continue
        rc, out = run([command, "--version"])
        first = out.splitlines()[0] if out else path
        log("%s: %s" % (command, first), "PASS" if rc == 0 else "FAIL")

    for command in OPTIONAL_COMMANDS:
        path = shutil.which(command)
        if not path:
            log("%s not found (optional, needed for some rounds)" % command, "WARN")
        else:
            log("%s present: %s" % (command, path))

    tmp = tempfile.mkdtemp(prefix="nexgen-check-")
    source = os.path.join(tmp, "hello.c")
    with open(source, "w", encoding="utf-8") as handle:
        handle.write('#include <stdio.h>\nint main(void) { puts("NEXGEN OK"); return 0; }\n')

    binary = os.path.join(tmp, "hello.exe" if platform.system() == "Windows" else "hello")
    gcc = shutil.which("gcc")
    if gcc:
        rc, out = run([gcc, "-o", binary, source])
        if rc != 0:
            log("gcc compile failed: %s" % out, "FAIL")
        else:
            rc, out = run([binary])
            if rc == 0 and "NEXGEN OK" in out:
                log("gcc compile and run smoke test", "PASS")
            else:
                log("gcc compiled but the program failed to run: %s" % out, "FAIL")

    makefile = os.path.join(tmp, "Makefile")
    with open(makefile, "w", encoding="utf-8") as handle:
        handle.write("hello: hello.c\n\tgcc -o hello hello.c\n")

    make = shutil.which("make")
    if make:
        rc, out = run([make], cwd=tmp)
        produced = os.path.join(tmp, "hello")
        if not os.path.exists(produced) and os.path.exists(produced + ".exe"):
            produced += ".exe"
        if rc == 0 and os.path.exists(produced):
            log("make smoke test (built hello)", "PASS")
        else:
            log("make smoke test failed: %s" % out, "FAIL")

    if failures:
        log("Summary: %d required check(s) failed" % failures, "FAIL")
    else:
        log("Summary: all required checks passed", "PASS")

    try:
        folder = os.path.dirname(report_path)
        if folder:
            os.makedirs(folder, exist_ok=True)
        with open(report_path, "a", encoding="utf-8") as handle:
            handle.write("\n== verify.py ==\n")
            handle.write("\n".join(lines) + "\n")
    except OSError as exc:
        print("could not write report: %s" % exc, file=sys.stderr)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
