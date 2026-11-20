#!/usr/bin/env python3
"""Check the app's anti-goals in the source tree:

    python3 -I scripts/check-anti-goals.py

- network: no network, process or IPC API anywhere in Sources/.
- package dependency: Package.swift declares no package dependencies.
- write outside the index database: the write APIs appear only in Indexer.swift and SQLite.swift, which
  write the index database. Nothing under ~/.claude is ever written.
- tracked transcript or index: git tracks no .jsonl, .sqlite(-wal/-shm) or .db file.
- transcript-like file outside fixtures: a tracked name containing .jsonl is a synthetic fixture under
  Tests/RunningOutCoreTests/Fixtures/.

Each pattern is matched against the whole file, so a call split over lines (`.write(` then `to:` on the
next line) is still found. Prints file:line and the rule for every violation and exits 1 if there are any.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = "Sources"
PACKAGE = "Package.swift"
INDEX_WRITERS = {"Sources/RunningOutCore/Indexer.swift", "Sources/RunningOutCore/SQLite.swift"}
FIXTURES = "Tests/RunningOutCoreTests/Fixtures/"


def call(name):
    """A call of `name`, allowing whitespace before the parenthesis."""
    return name + r"\s*\("


NETWORK = re.compile("|".join([
    "URLSession",
    "NSURLConnection",
    "CFNetwork",
    r"\bimport\s+(?:\w+\s+)?Network",  # import Network, import struct Network.NWConnection, NetworkExtension
    call("socket"),
    r"contentsOf:\s*URL\s*\(\s*string",
    call("Process"),
    "NSTask",
    "posix_spawn",
    "URLRequest",
    "WebKit",
    "WKWebView",
    "NSXPCConnection",
    "getaddrinfo",
    "CFSocket",
    "CFStream",
]))

DEPENDENCY = re.compile(r"\.package\s*\(")

WRITE = re.compile("|".join([
    "forWritingTo",
    "forWritingAtPath",
    "forUpdating",
    r"\.write\s*\(\s*to",  # write(to:), write(toFile:)
    call("createFile"),
    call("removeItem"),
    call("createDirectory"),
    call("moveItem"),
    call("copyItem"),
    "replaceItem",
    call("fopen"),
    "O_WRONLY",
    "O_RDWR",
    "O_CREAT",
    call("rename"),
    call("unlink"),
    call("mkdir"),
    call("creat"),
    call("truncate"),
    "createSymbolicLink",
    "linkItem",
    "trashItem",
    "setAttributes",
    "OutputStream",
    "NSFileCoordinator",
    "sqlite3_open",
]))

LOCAL_DATA = re.compile(r"\.(jsonl|sqlite|sqlite-wal|sqlite-shm|db)$", re.IGNORECASE)
JSONL = re.compile(r"\.jsonl", re.IGNORECASE)

violations = []


def report(location, rule, text):
    violations.append("{}: {}: {}".format(location, rule, text))


def read(relative):
    with open(os.path.join(ROOT, relative), "rb") as fh:
        return fh.read().decode("utf-8", errors="replace")


def scan(relative, content, rule, pattern):
    for match in pattern.finditer(content):
        line = content.count("\n", 0, match.start()) + 1
        report("{}:{}".format(relative, line), rule, " ".join(match.group(0).split()))


def source_files():
    found = []
    for directory, folders, files in os.walk(os.path.join(ROOT, SOURCES)):
        folders.sort()
        for name in sorted(files):
            found.append(os.path.relpath(os.path.join(directory, name), ROOT).replace(os.sep, "/"))
    return found


def tracked_files():
    try:
        result = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", b"") or b""
        sys.exit("check-anti-goals: git ls-files failed: {} {}".format(
            error, detail.decode("utf-8", errors="replace").strip()))
    return [path for path in result.stdout.decode("utf-8", errors="replace").split("\0") if path]


sources = source_files()
if not sources:
    sys.exit("check-anti-goals: no files under {}/".format(SOURCES))
for relative in sources:
    content = read(relative)
    scan(relative, content, "network", NETWORK)
    if relative not in INDEX_WRITERS:
        scan(relative, content, "write outside the index database", WRITE)

scan(PACKAGE, read(PACKAGE), "package dependency", DEPENDENCY)

tracked = tracked_files()
if not tracked:
    sys.exit("check-anti-goals: git ls-files listed no files")
for path in tracked:
    if LOCAL_DATA.search(path):
        report(path, "tracked transcript or index", "tracked by git")
    elif JSONL.search(path) and not path.startswith(FIXTURES):
        report(path, "transcript-like file outside fixtures", "only " + FIXTURES + " may hold .jsonl names")

if violations:
    print("\n".join(violations))
    print("check-anti-goals: {} violation(s)".format(len(violations)), file=sys.stderr)
    sys.exit(1)
print("check-anti-goals: ok ({} source files, {} tracked files)".format(len(sources), len(tracked)))
