#!/usr/bin/env python3
"""Prototype: count and classify prompt-cache rebuilds in local Claude Code transcripts.

Reference oracle for the Swift implementation (see the design doc, section 10).
Read-only. Usage:

    python3 -I prototype/drain.py --from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00Z

Rules (design doc sections 6.1-6.4):
  * only `type == "assistant"` lines with `message.usage`, deduplicated by `message.id`
    across all transcripts: resumed or forked sessions copy earlier calls into a new file,
    so each call is counted once, in its owner file (see `owners`)
  * a call is a rebuild when cache_creation >= 50,000 and cache_creation > cache_read
  * main-session rebuild causes, checked in order: session start (no earlier call in the
    file), after compaction, model changed, expired (gap > TTL of the previous call),
    version changed, unknown
  * cost is API-price-equivalent in units of base input: input 1, output 5,
    cache read 0.1, 5m cache write 1.25, 1h cache write 2
  * expired rebuilds split into short breaks (gap <= 3h) and long breaks (gap > 3h);
    only short breaks count as reducible (the user could have resumed before expiry)
"""
import argparse
import collections
import datetime
import glob
import json
import os

THRESHOLD = 50_000
WEIGHT = {"input": 1.0, "output": 5.0, "read": 0.1, "w5m": 1.25, "w1h": 2.0}
TTL = {"1h": 3600, "5m": 300}
SHORT_BREAK_HOURS = 3  # expired after a gap of at most this long: avoidable by resuming in time


def iso(ts):
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()


def ttl_of(usage, fallback):
    c = usage.get("cache_creation") or {}
    if c.get("ephemeral_1h_input_tokens", 0):
        return "1h"
    if c.get("ephemeral_5m_input_tokens", 0):
        return "5m"
    return fallback


def write_cost(usage):
    c = usage.get("cache_creation") or {}
    w1 = c.get("ephemeral_1h_input_tokens", 0)
    w5 = c.get("ephemeral_5m_input_tokens", 0)
    if not (w1 or w5):
        w1 = usage.get("cache_creation_input_tokens", 0)
    return w1 * WEIGHT["w1h"] + w5 * WEIGHT["w5m"]


def call_cost(usage):
    return (
        usage.get("input_tokens", 0) * WEIGHT["input"]
        + usage.get("output_tokens", 0) * WEIGHT["output"]
        + usage.get("cache_read_input_tokens", 0) * WEIGHT["read"]
        + write_cost(usage)
    )


def iter_calls(path):
    """Yield (message, usage, record) for real assistant API calls, in file order."""
    with open(path, "rb") as fh:
        for line in fh:
            if b"compact_boundary" in line:
                yield None, None, {"compact": True}
                continue
            if b'"usage"' not in line or b'"assistant"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") != "assistant" or not o.get("timestamp"):
                continue
            m = o.get("message") or {}
            u = m.get("usage") or {}
            if not u or not m.get("id") or m.get("model") == "<synthetic>":
                continue
            yield m, u, o


def owners(files):
    """Pick one owning file per message.id.

    Resumed or forked sessions copy earlier messages into a new transcript, so the same
    message.id can appear in several files. Each call is counted once, in its owner:
    prefer the file whose name matches the line's sessionId (main transcripts only),
    then the file created first, then the path.
    """
    best = {}
    for path in files:
        is_sub = "/subagents/" in path
        file_sid = os.path.basename(path)[:-6]
        born = os.stat(path).st_birthtime
        for m, _, o in iter_calls(path):
            if m is None:
                continue
            key = (0 if (not is_sub and o.get("sessionId") == file_sid) else 1, born, path)
            mid = m["id"]
            if mid not in best or key < best[mid]:
                best[mid] = key
    return {mid: key[2] for mid, key in best.items()}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--from", dest="lo", required=True, help="inclusive, ISO 8601 UTC")
    p.add_argument("--to", dest="hi", required=True, help="exclusive, ISO 8601 UTC")
    p.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    a = p.parse_args()
    lo, hi = iso(a.lo), iso(a.hi)

    files = glob.glob(f"{a.root}/*/*.jsonl") + glob.glob(f"{a.root}/*/*/subagents/*.jsonl")
    calls = 0
    tokens = collections.Counter()
    total_cost = 0.0
    rebuild_n = rebuild_tok = 0
    sub_rebuild_n = 0
    causes = collections.Counter()
    expired_tok = 0
    expired_write_cost = expired_reducible = 0.0
    breaks = {"short break": [0, 0, 0.0], "long break": [0, 0, 0.0]}

    owner = owners(files)

    for path in files:
        if os.path.getmtime(path) < lo:
            continue
        is_sub = "/subagents/" in path
        seen = set()
        last_t = last_model = last_version = None
        last_ttl = "5m" if is_sub else "1h"
        compacted = False
        if True:
            for m, u, o in iter_calls(path):
                if m is None:
                    compacted = True
                    continue
                mid = m["id"]
                if mid in seen:
                    continue
                seen.add(mid)
                t = iso(o["timestamp"])

                # Copied calls (owned by another file) still set this file's context,
                # but are counted only in their owner.
                if lo <= t < hi and owner.get(mid) == path:
                    calls += 1
                    cc = u.get("cache_creation_input_tokens", 0)
                    cr = u.get("cache_read_input_tokens", 0)
                    tokens["input"] += u.get("input_tokens", 0)
                    tokens["output"] += u.get("output_tokens", 0)
                    tokens["cache_read"] += cr
                    tokens["cache_write"] += cc
                    total_cost += call_cost(u)

                    if cc >= THRESHOLD and cc > cr:
                        rebuild_n += 1
                        rebuild_tok += cc
                        if is_sub:
                            sub_rebuild_n += 1
                        else:
                            if last_t is None:
                                cause = "session start"
                            elif compacted:
                                cause = "after compaction"
                            elif m.get("model") != last_model:
                                cause = "model changed"
                            elif t - last_t > TTL[last_ttl]:
                                cause = "expired"
                            elif o.get("version") != last_version:
                                cause = "version changed"
                            else:
                                cause = "unknown"
                            causes[cause] += 1
                            if cause == "expired":
                                wc = write_cost(u)
                                expired_tok += cc
                                expired_write_cost += wc
                                gap_h = (t - last_t) / 3600
                                kind = "short break" if gap_h <= SHORT_BREAK_HOURS else "long break"
                                breaks[kind][0] += 1
                                breaks[kind][1] += cc
                                breaks[kind][2] += wc
                                if kind == "short break":
                                    expired_reducible += wc - cc * WEIGHT["read"]

                last_t = t
                last_model = m.get("model")
                last_version = o.get("version")
                last_ttl = ttl_of(u, last_ttl)
                compacted = False

    print(f"window              {a.lo} .. {a.hi}")
    print(f"api calls           {calls:,}")
    print("tokens              " + " ".join(f"{k}={v:,}" for k, v in tokens.items()))
    share = rebuild_tok / tokens["cache_write"] if tokens["cache_write"] else 0
    print(f"rebuilds            {rebuild_n} calls, {rebuild_tok:,} tokens ({share:.1%} of cache writes)")
    print(f"  in subagents      {sub_rebuild_n}")
    print(f"  in main sessions  {sum(causes.values())}: " + ", ".join(f"{k} {v}" for k, v in causes.most_common()))
    if total_cost:
        print(f"expired rebuilds    {causes['expired']} calls, {expired_tok:,} tokens, cache-write cost {expired_write_cost / total_cost:.1%} of all cost")
        for kind, (n, tok, wc) in breaks.items():
            print(f"  {kind:<17} {n} calls, {tok:,} tokens, cache-write cost {wc / total_cost:.1%}")
        print(f"  reducible         {expired_reducible / total_cost:.1%} of all cost (short breaks only)")


if __name__ == "__main__":
    main()
