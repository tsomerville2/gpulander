"""Console entry point: exec the bundled gpulander.sh with the user's args.

The tool itself is a battle-tested bash script (gpulander.sh) shipped as package
data. This thin wrapper just locates it and hands over the process via execv, so
`gpulander ...` behaves exactly like running the script directly — same stdout,
same exit codes (0 grabbed / 7 deadline / 2 error).
"""
import os
import shutil
import sys
from pathlib import Path


def script_path() -> Path:
    return Path(__file__).resolve().with_name("gpulander.sh")


def main() -> "int | None":
    if len(sys.argv) > 1 and sys.argv[1] == "watch":
        from gpulander import watch
        return watch.main(sys.argv[2:])
    sh = script_path()
    if not sh.exists():
        sys.stderr.write(f"gpulander: bundled script not found at {sh}\n")
        return 2
    bash = shutil.which("bash") or "/bin/bash"
    if not os.path.exists(bash):
        sys.stderr.write("gpulander: bash not found on PATH (needs bash + the AWS CLI)\n")
        return 2
    # execv replaces this process; exit code flows straight through to the caller.
    os.execv(bash, [bash, str(sh), *sys.argv[1:]])


if __name__ == "__main__":
    raise SystemExit(main())
