#!/usr/bin/env python3
"""Prototype: count and classify prompt-cache rebuilds in local Claude Code transcripts.

Reference oracle for the Swift implementation (see the design doc, section 10).
Read-only. Usage:

    python3 -I prototype/drain.py --from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00Z

Rules (design doc sections 6.1-6.4, with the 2-2 corrections in DECISIONS.md):
  * only `type == "assistant"` lines with `message.usage`, deduplicated by `message.id`
    across all transcripts: resumed or forked sessions copy earlier calls into a new file,
    so each call is counted once, in its owner file (see `owners`)
  * a message's first line in a file fixes its place, time, model and version; its last line
    in that file holds the final usage (Claude Code fills the usage in as the response streams)
  * `usage.iterations` splits a call into steps; an `advisor_message` step runs on its own model
    and is left out of the top-level input and output, so cost is the sum over the steps
  * a call with more than 1,000 steps or a token count outside 0..1e9 is malformed and skipped
  * odd shapes are read as the app reads them: a line, message or usage that is not an object, a
    non-string id, model or timestamp, or a count that is not an integer (7.0) means no call; steps of
    another shape mean the top-level usage; a step whose model is not a string is dropped; only the
    known keys of a cache breakdown are read
  * a step is a rebuild when it writes >= the threshold (default 50,000, --rebuild-threshold) cache
    tokens and more than it read; a call is a rebuild when one of its main-model steps is (advisor
    steps never are)
  * main-session rebuild causes, checked in order: session start (no earlier call in the
    file), after compaction, model changed, expired (gap > TTL of the previous call),
    version changed, unknown
  * cost is the API list price per model from the app's `pricing.json` (official pricing page),
    in integer nano-USD (tokens x thousandths of a USD per million tokens) so sums are exact;
    a model id matches a table key exactly or with a date suffix (-YYYYMMDD); Claude Haiku 5.5
    uses its long-context prices when a step's prompt is over 100,000 tokens; a model missing from
    the table is priced as claude-opus-5-5 and reported as unpriced
  * cost buckets (design 6.4): advisor steps go to advisor; the cache-write cost of the steps that
    rebuilt goes to the cause, the rest of that call to normal work; the rest of every subagent call
    goes to subagents
  * expired rebuilds split into short breaks (gap <= 3h) and long breaks (gap > 3h);
    only short breaks count as reducible (the user could have resumed before expiry)
"""
import argparse
import collections
import datetime
import glob
import json
import os
import re

THRESHOLD = 50_000
TOKEN_LIMIT = 1_000_000_000
ITERATION_LIMIT = 1_000
DEFAULT_MODEL = "claude-opus-5-5"
PRICING_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "RunningOutCore", "Resources", "pricing.json"
)
TTL = {"1h": 3600, "5m": 300}
SHORT_BREAK_HOURS = 3  # expired after a gap of at most this long: avoidable by resuming in time
TOKEN_KEYS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
# Only these keys of a cache breakdown are read; others, of any value, are ignored like the app does.
CACHE_KEYS = ("ephemeral_1h_input_tokens", "ephemeral_5m_input_tokens")
DATED = re.compile(r"^(.*)-\d{8}$")
TIMESTAMP = re.compile(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2}(?::\d{2})?)?")


def iso(ts):
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()


def line_time(ts):
    """Seconds since 1970 of a line's timestamp, or None when it is not one the prototype reads.

    The fraction may have 1 to 9 digits, as in the app, and reads the same on every Python version
    (3.9's fromisoformat takes only 3 or 6). Without a time zone the time is local, which the app does
    not accept (a known difference).
    """
    match = TIMESTAMP.fullmatch(ts) if isinstance(ts, str) else None
    if match is None:
        return None
    whole, fraction, zone = match.groups()
    try:
        seconds = datetime.datetime.fromisoformat(whole + (zone or "").replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None
    return (int(seconds) * 10**9 + int((fraction or "").ljust(9, "0"))) / 10**9


def text_or_none(v):
    return v if isinstance(v, str) else None


def ttl_of(usage, fallback):
    c = usage.get("cache_creation") or {}
    if c.get("ephemeral_1h_input_tokens") or 0:
        return "1h"
    if c.get("ephemeral_5m_input_tokens") or 0:
        return "5m"
    return fallback


def counts(step):
    c = step.get("cache_creation") or {}
    return [step.get(k) or 0 for k in TOKEN_KEYS] + [
        c.get("ephemeral_1h_input_tokens") or 0, c.get("ephemeral_5m_input_tokens") or 0
    ]


def is_count(v):
    return type(v) is int


def steps_of(usage):
    """The iterations, or None when the field is missing, empty or not the expected shape."""
    its = usage.get("iterations")
    if not isinstance(its, list) or not its or not all(isinstance(i, dict) for i in its):
        return None
    for i in its:
        c = i.get("cache_creation")
        if c is not None and not isinstance(c, dict):
            return None
        values = [i.get(k) for k in TOKEN_KEYS] + ([c.get(k) for k in CACHE_KEYS] if c else [])
        if any(v is not None and not is_count(v) for v in values):
            return None
    return its


def parts(model, usage):
    """(kind, model, step) per step; the top-level usage is one step when there are no iterations.

    A step whose model is not a string is dropped, and the top-level usage is used when no step is left.
    A missing or empty model is the call's model; a type other than "advisor_message" is a main step.
    """
    its = [i for i in steps_of(usage) or [] if i.get("model") is None or isinstance(i.get("model"), str)]
    if not its:
        return [("message", model, usage)]
    return [
        ("advisor" if i.get("type") == "advisor_message" else "message", i.get("model") or model, i) for i in its
    ]


def rebuilt(kind, step, threshold=THRESHOLD):
    write = step.get("cache_creation_input_tokens") or 0
    return kind == "message" and write >= threshold and write > (step.get("cache_read_input_tokens") or 0)


def positive_int(text):
    # Digits only, like the app's CLI: no signs, spaces or underscores.
    if not text.isdigit() or int(text) < 1:
        raise argparse.ArgumentTypeError("must be a whole number of tokens, 1 or more")
    return int(text)


class Pricing:
    """Nano-USD per step from the official per-model list prices."""

    KEYS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")

    def __init__(self, path):
        with open(path) as fh:
            raw = json.load(fh)["models"]

        def milli(model, p):
            out = {}
            for k in self.KEYS:
                v = p[k]
                if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
                    raise SystemExit(f"{model}: {k} must be a non-negative number")
                if abs(round(v * 1000) - v * 1000) >= 1e-6:
                    raise SystemExit(f"{model}: {k} has more than three decimals")
                out[k] = round(v * 1000)
            return out

        self.models = {}
        for model, p in raw.items():
            entry = milli(model, p)
            if p.get("long_context"):
                lc = p["long_context"]
                entry["long_context"] = {"over_prompt_tokens": lc["over_prompt_tokens"], **milli(model, lc)}
            self.models[model] = entry
        if DEFAULT_MODEL not in self.models:
            raise SystemExit(f"pricing table lacks the fallback model {DEFAULT_MODEL}")

    def prices(self, model, prompt_tokens):
        """Returns (prices, known)."""
        key = model if model in self.models else None
        if key is None:
            dated = DATED.match(model)
            key = dated.group(1) if dated and dated.group(1) in self.models else None
        p = self.models[key or DEFAULT_MODEL]
        long_context = p.get("long_context")
        if long_context and prompt_tokens > long_context["over_prompt_tokens"]:
            return long_context, key is not None
        return p, key is not None

    def costs(self, model, step):
        """Returns (cache-write cost, all other cost, cost of the written tokens as a cache read, known)."""
        inp, out, read, written, _, w5 = counts(step)
        w5 = min(w5, written)
        w1 = written - w5  # writes the TTL breakdown does not cover are priced as one-hour writes
        p, known = self.prices(model, inp + read + written)
        write = w1 * p["cache_write_1h"] + w5 * p["cache_write_5m"]
        other = inp * p["input"] + out * p["output"] + read * p["cache_read"]
        return write, other, written * p["cache_read"], known


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
            # A line of another shape is not a call, like in the app: skip it rather than fail.
            if not isinstance(o, dict):
                continue
            # The words can also appear inside message text, so check the record itself.
            if o.get("type") == "system" and o.get("subtype") == "compact_boundary":
                yield None, None, {"compact": True}
                continue
            if o.get("type") != "assistant" or line_time(o.get("timestamp")) is None:
                continue
            m = o.get("message")
            u = m.get("usage") if isinstance(m, dict) else None
            if not isinstance(u, dict) or not u:
                continue
            mid, model = m.get("id"), m.get("model")
            if not isinstance(mid, str) or not mid or not isinstance(model, str) or not model:
                continue
            if model == "<synthetic>":
                continue
            c = u.get("cache_creation")
            if c is not None and not isinstance(c, dict):
                continue
            top = [u.get(k) for k in TOKEN_KEYS] + ([c.get(k) for k in CACHE_KEYS] if c else [])
            if any(v is not None and not is_count(v) for v in top):
                continue
            # More than 1,000 steps or a count outside 0..1e9 is not real usage: the line is malformed and
            # skipped. Together they keep one call's cost far inside the app's Int64 sums.
            its = steps_of(u)
            if its is not None and len(its) > ITERATION_LIMIT:
                continue
            values = counts(u) + [v for _, _, s in parts(m["model"], u) for v in counts(s)]
            if any(v < 0 or v > TOKEN_LIMIT for v in values):
                continue
            yield m, u, o


def read_file(path):
    """Events in file order (None for a compaction mark, else (message, record) at the message's
    first line), and the final usage of each message in this file."""
    events, final = [], {}
    for m, u, o in iter_calls(path):
        if m is None:
            events.append(None)
            continue
        if m["id"] not in final:
            events.append((m, o))
        final[m["id"]] = u
    return events, final


def owners(files, root):
    """Pick one owning file per message.id.

    Resumed or forked sessions copy earlier messages into a new transcript, so the same
    message.id can appear in several files. Each call is counted once, in its owner:
    prefer the file whose name matches the line's sessionId (main transcripts only),
    then the file created first, then the path.
    """
    best = {}
    for path in files:
        is_sub = "subagents" in os.path.relpath(path, root).split(os.sep)
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
    p.add_argument("--rebuild-threshold", type=positive_int, default=THRESHOLD)
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
    advisor = [0, 0, 0, 0]  # calls, input, output, cost
    unpriced = collections.Counter()
    bucket_of = {
        "session start": "session start & compaction",
        "after compaction": "session start & compaction",
        "model changed": "model change & update",
        "version changed": "model change & update",
        "unknown": "unknown",
    }

    owner = owners(files, a.root)

    for path in files:
        is_sub = "subagents" in os.path.relpath(path, a.root).split(os.sep)
        last_t = last_model = last_version = None
        last_ttl = "5m" if is_sub else "1h"
        compacted = False
        events, final = read_file(path)
        for event in events:
            if event is None:
                compacted = True
                continue
            m, o = event
            mid = m["id"]
            u = final[mid]
            t = line_time(o["timestamp"])
            steps = parts(m["model"], u)
            is_rebuild = any(rebuilt(kind, step, a.rebuild_threshold) for kind, _, step in steps)

            # Copied calls (owned by another file) still set this file's context,
            # but are counted only in their owner.
            if lo <= t < hi and owner.get(mid) == path:
                calls += 1
                cc = u.get("cache_creation_input_tokens") or 0
                tokens["input"] += u.get("input_tokens") or 0
                tokens["output"] += u.get("output_tokens") or 0
                tokens["cache_read"] += u.get("cache_read_input_tokens") or 0
                tokens["cache_write"] += cc
                cost = rb_write = rb_tok = rb_as_read = advisor_cost = 0
                consulted = False
                missing = set()
                for kind, model, step in steps:
                    write, other, as_read, known = pricing.costs(model, step)
                    if not known:
                        missing.add(model)
                    cost += write + other
                    if kind == "advisor":
                        consulted = True
                        advisor[1] += step.get("input_tokens") or 0
                        advisor[2] += step.get("output_tokens") or 0
                        advisor[3] += write + other
                        advisor_cost += write + other
                    if is_rebuild and rebuilt(kind, step, a.rebuild_threshold):
                        rb_write += write
                        rb_tok += step.get("cache_creation_input_tokens") or 0
                        rb_as_read += as_read
                advisor[0] += consulted
                for model in missing:
                    unpriced[model] += 1
                total_cost += cost
                buckets["advisor"] += advisor_cost

                if is_sub:
                    buckets["subagents"] += cost - advisor_cost
                    if is_rebuild:
                        rebuild_n += 1
                        rebuild_tok += rb_tok
                        sub_rebuild_n += 1
                elif not is_rebuild:
                    buckets["normal work"] += cost - advisor_cost
                else:
                    rebuild_n += 1
                    rebuild_tok += rb_tok
                    if last_t is None:
                        cause = "session start"
                    elif compacted:
                        cause = "after compaction"
                    elif m.get("model") != last_model:
                        cause = "model changed"
                    elif t - last_t > TTL[last_ttl]:
                        cause = "expired"
                    elif text_or_none(o.get("version")) != last_version:
                        cause = "version changed"
                    else:
                        cause = "unknown"
                    causes[cause] += 1
                    buckets["normal work"] += cost - rb_write - advisor_cost
                    if cause == "expired":
                        kind = "short break" if (t - last_t) / 3600 <= SHORT_BREAK_HOURS else "long break"
                        breaks[kind][0] += 1
                        breaks[kind][1] += rb_tok
                        breaks[kind][2] += rb_write
                        buckets["rebuild after " + kind] += rb_write
                        if kind == "short break":
                            reducible += rb_write - rb_as_read
                    else:
                        buckets[bucket_of[cause]] += rb_write

            last_t = t
            last_model = m.get("model")
            last_version = text_or_none(o.get("version"))
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
                     "session start & compaction", "subagents", "advisor", "model change & update", "unknown"]:
            print(f"  {name:<27} {buckets[name] / total_cost:6.1%}  ${buckets[name] / 1e9:,.2f}")
        if advisor[0]:
            print(f"advisor calls       {advisor[0]}, input={advisor[1]:,} output={advisor[2]:,}")
        idle = breaks["short break"][2] + breaks["long break"][2]
        print(f"menu bar (idle rebuilds) {idle / total_cost:.1%}")
        print(f"reducible (short breaks) {reducible / total_cost:.1%}")
    if unpriced:
        print("unpriced models     " + ", ".join(f"{k} x{v}" for k, v in sorted(unpriced.items())))

if __name__ == "__main__":
    main()
