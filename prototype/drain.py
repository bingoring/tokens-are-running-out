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
  * cost is the API list price per model from the app's `pricing.json` (official pricing page),
    in integer nano-USD (tokens x thousandths of a USD per million tokens) so sums are exact;
    Claude Haiku 5.5 uses its long-context prices when the prompt is over 100,000 tokens;
    a model missing from the table is priced as claude-opus-5-5 and reported as unpriced
  * cost buckets (design 6.4): a rebuild's cache-write cost goes to its cause, the rest of
    that call to normal work; every subagent call goes to subagents
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
DEFAULT_MODEL = "claude-opus-5-5"
PRICING_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "RunningOutCore", "Resources", "pricing.json"
)
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


class Pricing:
    """USD per call from the official per-model list prices."""

    def __init__(self, path):
        with open(path) as fh:
            raw = json.load(fh)["models"]
        milli = lambda p: {k: round(v * 1000) for k, v in p.items() if k != "long_context" and k != "over_prompt_tokens"}
        self.models = {}
        for model, p in raw.items():
            entry = milli(p)
            if "long_context" in p:
                entry["long_context"] = {"over_prompt_tokens": p["long_context"]["over_prompt_tokens"], **milli(p["long_context"])}
            self.models[model] = entry
        self.unpriced = collections.Counter()

    def prices(self, model, prompt_tokens):
        matches = [k for k in self.models if model == k or model.startswith(k + "-")]
        if not matches:
            self.unpriced[model] += 1
            matches = [DEFAULT_MODEL]
        p = self.models[max(matches, key=len)]
        long_context = p.get("long_context")
        if long_context and prompt_tokens > long_context["over_prompt_tokens"]:
            return long_context
        return p

    def costs(self, model, usage):
        """Returns (cache-write cost, all other cost, cost of the written tokens as a cache read)."""
        inp = usage.get("input_tokens", 0)
        out = usage.get("output_tokens", 0)
        read = usage.get("cache_read_input_tokens", 0)
        written = usage.get("cache_creation_input_tokens", 0)
        c = usage.get("cache_creation") or {}
        w1 = c.get("ephemeral_1h_input_tokens", 0)
        w5 = c.get("ephemeral_5m_input_tokens", 0)
        if not (w1 or w5):
            w1 = written
        p = self.prices(model, inp + read + written)
        write = w1 * p["cache_write_1h"] + w5 * p["cache_write_5m"]
        other = inp * p["input"] + out * p["output"] + read * p["cache_read"]
        as_read = written * p["cache_read"]
        return write, other, as_read


def iter_calls(path):
    """Yield (message, usage, record) for real assistant API calls, in file order."""
    with open(path, "rb") as fh:
        for line in fh:
            maybe_compact = b"compact_boundary" in line
            maybe_call = b'"usage"' in line and b'"assistant"' in line
            if not (maybe_compact or maybe_call):
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            # The words can also appear inside message text, so check the record itself.
            if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
                yield None, None, {"compact": True}
                continue
            if o.get("type") != "assistant" or not o.get("timestamp"):
                continue
            m = o.get("message") or {}
            u = m.get("usage") or {}
            if not u or not m.get("id") or not m.get("model") or m.get("model") == "<synthetic>":
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
        seen = set()
        for m, _, o in iter_calls(path):
            if m is None or m["id"] in seen:
                continue
            seen.add(m["id"])  # the first line of a message in a file decides its rank
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
    p.add_argument("--pricing", default=PRICING_PATH)
    a = p.parse_args()
    lo, hi = iso(a.lo), iso(a.hi)

    files = glob.glob(f"{a.root}/*/*.jsonl") + glob.glob(f"{a.root}/*/*/subagents/agent-*.jsonl")
    pricing = Pricing(a.pricing)
    calls = 0
    tokens = collections.Counter()
    total_cost = 0
    rebuild_n = rebuild_tok = 0
    sub_rebuild_n = 0
    causes = collections.Counter()
    breaks = {"short break": [0, 0, 0], "long break": [0, 0, 0]}
    reducible = 0
    buckets = collections.Counter()
    bucket_of = {
        "session start": "session start & compaction",
        "after compaction": "session start & compaction",
        "model changed": "model change & update",
        "version changed": "model change & update",
        "unknown": "unknown",
    }

    owner = owners(files)

    for path in files:
        if os.path.getmtime(path) < lo:
            continue
        is_sub = "/subagents/" in path
        seen = set()
        last_t = last_model = last_version = None
        last_ttl = "5m" if is_sub else "1h"
        compacted = False
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
                write, other, as_read = pricing.costs(m["model"], u)
                total_cost += write + other
                is_rebuild = cc >= THRESHOLD and cc > cr

                if is_sub:
                    buckets["subagents"] += write + other
                    if is_rebuild:
                        rebuild_n += 1
                        rebuild_tok += cc
                        sub_rebuild_n += 1
                elif not is_rebuild:
                    buckets["normal work"] += write + other
                else:
                    rebuild_n += 1
                    rebuild_tok += cc
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
                    buckets["normal work"] += other
                    if cause == "expired":
                        kind = "short break" if (t - last_t) / 3600 <= SHORT_BREAK_HOURS else "long break"
                        breaks[kind][0] += 1
                        breaks[kind][1] += cc
                        breaks[kind][2] += write
                        buckets["rebuild after " + kind] += write
                        if kind == "short break":
                            reducible += write - as_read
                    else:
                        buckets[bucket_of[cause]] += write

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
    ordered = sorted(causes.items(), key=lambda kv: (-kv[1], kv[0]))
    print(f"  in main sessions  {sum(causes.values())}: " + ", ".join(f"{k} {v}" for k, v in ordered))
    for kind, (n, tok, _) in breaks.items():
        print(f"  expired, {kind:<12} {n} calls, {tok:,} tokens")
    print(f"cost (API list)     ${total_cost / 1e9:,.2f}")
    if total_cost:
        for name in ["normal work", "rebuild after short break", "rebuild after long break",
                     "session start & compaction", "subagents", "model change & update", "unknown"]:
            print(f"  {name:<27} {buckets[name] / total_cost:6.1%}  ${buckets[name] / 1e9:,.2f}")
        idle = breaks["short break"][2] + breaks["long break"][2]
        print(f"menu bar (idle rebuilds) {idle / total_cost:.1%}")
        print(f"reducible (short breaks) {reducible / total_cost:.1%}")
    if pricing.unpriced:
        print("unpriced models     " + ", ".join(f"{k} x{v}" for k, v in sorted(pricing.unpriced.items())))

if __name__ == "__main__":
    main()
