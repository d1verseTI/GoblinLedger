#!/usr/bin/env python3
"""
Rebuild the vendor database and publish it when it changed - meant to run on a schedule.

    python tools/publish_vendordb.py --repo <path to the GoblinLedger git repo>

1. Runs tools/build_vendordb.py (collects vendors recorded in game, rebuilds Data/VendorDB.lua).
2. Copies ONLY the database files into the repo: Data/VendorDB.lua, tools/recorded_vendors.json,
   tools/fojji_vendors.json. Other work-in-progress in the game folder is never touched.
3. If they changed, commits ("Update vendor database ...") and pushes.
A short log goes to tools/publish_vendordb.log.
"""
import datetime
import json
import pathlib
import shutil
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
ADDON = HERE.parent
FILES = ["Data/VendorDB.lua", "tools/recorded_vendors.json", "tools/fojji_vendors.json"]
LOG = HERE / "publish_vendordb.log"
# no console windows popping up when run by Task Scheduler
NO_WINDOW = {"creationflags": subprocess.CREATE_NO_WINDOW} if sys.platform == "win32" else {}


def log(msg):
    line = f"{datetime.datetime.now():%Y-%m-%d %H:%M} {msg}"
    print(line)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")
    # keep the log short
    lines = LOG.read_text(encoding="utf-8").splitlines()
    if len(lines) > 300:
        LOG.write_text("\n".join(lines[-200:]) + "\n", encoding="utf-8")


def git(repo, *args, check=True):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=check, **NO_WINDOW)


def main():
    if "--repo" not in sys.argv:
        raise SystemExit("usage: publish_vendordb.py --repo <path to the GoblinLedger git repo>")
    repo = pathlib.Path(sys.argv[sys.argv.index("--repo") + 1])
    if not (repo / ".git").exists():
        log(f"ERROR: {repo} is not a git repository")
        return 1

    build = subprocess.run([sys.executable, str(HERE / "build_vendordb.py")], capture_output=True, text=True, **NO_WINDOW)
    if build.returncode != 0:
        log("ERROR: build failed: " + (build.stderr or build.stdout).strip().splitlines()[-1])
        return 1

    for rel in FILES:
        src = ADDON / rel
        if src.exists():
            (repo / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, repo / rel)

    git(repo, "add", "--", *FILES)
    if git(repo, "diff", "--cached", "--quiet", check=False).returncode == 0:
        log("No changes to the vendor database.")
        return 0

    recorded = json.loads((ADDON / "tools/recorded_vendors.json").read_text(encoding="utf-8"))
    msg = f"Update vendor database ({len(recorded)} recorded vendors)"
    # commit only the database files, even if other things are staged in the repo
    commit = git(repo, "commit", "-m", msg, "--", *FILES, check=False)
    if commit.returncode != 0:
        log("ERROR: commit failed: " + (commit.stderr or commit.stdout).strip())
        return 1
    push = git(repo, "push", "-q", "origin", "HEAD", check=False)
    if push.returncode != 0:
        log("ERROR: push failed (will retry next run): " + push.stderr.strip())
        return 1
    log(f"Published: {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
