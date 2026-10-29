#!/usr/bin/env python3
"""Check path decisions against the bundled config and the safety lists.

This mirrors PathPolicy.decision and bridge.js classify. It does not talk to
Instagram and it does not compile the iOS app.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "Insta" / "Resources" / "fallback-config.json"
SWIFT_PATH = ROOT / "Insta" / "Web" / "PathPolicy.swift"
JS_PATH = ROOT / "Insta" / "Resources" / "bridge.js"


def extract_quoted_block(text, marker):
    start = text.find(marker)
    if start < 0:
        raise SystemExit("missing marker: " + marker)
    equals = text.find("= [", start)
    if equals < 0:
        raise SystemExit("missing list after " + marker)
    bracket = equals + 2
    index = bracket + 1
    patterns = []
    while index < len(text):
        char = text[index]
        if char == "]":
            break
        if char == '"':
            index += 1
            buf = []
            while index < len(text):
                item = text[index]
                if item == "\\":
                    index += 1
                    if index < len(text):
                        buf.append(text[index])
                    index += 1
                    continue
                if item == '"':
                    patterns.append("".join(buf))
                    break
                buf.append(item)
                index += 1
        index += 1
    if not patterns:
        raise SystemExit("no patterns for " + marker)
    return patterns


def normalize(path):
    path = path.split("#", 1)[0].split("?", 1)[0]
    if not path:
        return "/"
    if not path.startswith("/"):
        path = "/" + path
    while len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    return path


def full_match(pattern, text):
    if not pattern:
        return False
    return re.fullmatch(pattern, text) is not None


def matches_any(patterns, path):
    return any(full_match(pattern, path) for pattern in patterns)


def allow_patterns(config, safety):
    reels = config["reels"]
    explore = config["explore"]
    patterns = list(safety)
    patterns.extend(config.get("allowedPaths") or [])
    if reels.get("allowReelPathPattern"):
        patterns.append(reels["allowReelPathPattern"])
    if reels.get("allowUserReelPathPattern"):
        patterns.append(reels["allowUserReelPathPattern"])
    if reels.get("postPathPattern"):
        patterns.append(reels["postPathPattern"])
    if reels.get("allowIdPaths", True) and reels.get("idPathPattern"):
        patterns.append(reels["idPathPattern"])
    mode = explore.get("mode") or "hideGridKeepSearch"
    if mode != "blockAll":
        patterns.extend(explore.get("alwaysAllowPathPatterns") or [])
    if not reels.get("allowIdPaths", True):
        banned_id = reels.get("idPathPattern")
        patterns = [item for item in patterns if item != banned_id]
    if mode == "blockAll":
        banned = set(explore.get("alwaysAllowPathPatterns") or [])
        patterns = [item for item in patterns if item not in banned]
    return patterns


def decide(raw_path, config, safety):
    path = normalize(raw_path)
    target = normalize(config["redirect"]["targetPath"])
    reels = config["reels"]
    explore = config["explore"]
    profile = config["profile"]
    if path == target:
        return "allow"
    if reels.get("blockFeed", True) and full_match(reels["feedPathPattern"], path):
        return "block"
    if not reels.get("allowIdPaths", True) and full_match(reels["idPathPattern"], path):
        return "block"
    if matches_any(allow_patterns(config, safety), path):
        return "allow"
    if profile.get("hideReelsTab", True) and full_match(profile["reelsTabPathPattern"], path):
        return "block"
    browse = explore.get("blockBrowsePathPatterns")
    if not isinstance(browse, list):
        browse = ["^/explore/tags(?:/.*)?$", "^/explore/locations(?:/.*)?$"]
    if matches_any(browse, path):
        return "block"
    mode = explore.get("mode") or "hideGridKeepSearch"
    if mode == "blockAll" and matches_any(explore.get("alwaysAllowPathPatterns") or [], path):
        return "block"
    if matches_any(config.get("blockedPaths") or [], path):
        return "block"
    return "allow"


def main():
    config = json.loads(CONFIG_PATH.read_text())
    swift = extract_quoted_block(SWIFT_PATH.read_text(), "static let safetyAllowPatterns")
    js = extract_quoted_block(JS_PATH.read_text(), "var SAFETY_FALLBACK")
    if swift != js:
        print("safety lists differ")
        print("swift", swift)
        print("js", js)
        return 1

    base_cases = [
        ("/", "allow"),
        ("/?variant=following", "allow"),
        ("/?variant=favorites", "allow"),
        ("/reels/", "block"),
        ("/reels", "block"),
        ("/reels/ABC123/", "allow"),
        ("/reel/ABC123/", "allow"),
        ("/reel/ABC123", "allow"),
        ("/someuser/reel/ABC123/", "allow"),
        ("/someuser/", "allow"),
        ("/someuser", "allow"),
        ("/someuser/reels/", "block"),
        ("/someuser/reels", "block"),
        ("/explore/", "allow"),
        ("/explore/search/", "allow"),
        ("/explore/search/keyword/", "allow"),
        ("/explore/tags/cats/", "block"),
        ("/explore/locations/12345/", "block"),
        ("/stories/someuser/123/", "allow"),
        ("/direct/inbox/", "allow"),
        ("/direct/t/123/", "allow"),
        ("/direct/requests/", "allow"),
        ("/accounts/login/", "allow"),
        ("/accounts/login/two_factor/", "allow"),
        ("/accounts/edit/", "allow"),
        ("/accounts/activity/", "allow"),
        ("/challenge/abc/", "allow"),
        ("/consent/", "allow"),
        ("/p/ABC123/", "allow"),
        ("/reel/", "allow"),
        ("/reels/abc/extra", "allow"),
    ]
    failures = 0
    for path, expected in base_cases:
        got = decide(path, config, swift)
        if got != expected:
            print(f"FAIL {path}: got {got}, expected {expected}")
            failures += 1

    blocked_explore = json.loads(json.dumps(config))
    blocked_explore["explore"]["mode"] = "blockAll"
    for path, expected in [
        ("/explore/", "block"),
        ("/explore/search/", "block"),
        ("/explore/tags/cats/", "block"),
        ("/accounts/login/", "allow"),
        ("/", "allow"),
        ("/reel/ABC/", "allow"),
    ]:
        got = decide(path, blocked_explore, swift)
        if got != expected:
            print(f"FAIL blockAll {path}: got {got}, expected {expected}")
            failures += 1

    no_id = json.loads(json.dumps(config))
    no_id["reels"]["allowIdPaths"] = False
    if decide("/reels/ABC/", no_id, swift) != "block":
        print("FAIL allowIdPaths false should block /reels/<id>")
        failures += 1
    if decide("/reel/ABC/", no_id, swift) != "allow":
        print("FAIL allowIdPaths false must still allow /reel/<id>")
        failures += 1

    show_tab = json.loads(json.dumps(config))
    show_tab["profile"]["hideReelsTab"] = False
    if decide("/someuser/reels/", show_tab, swift) != "allow":
        print("FAIL hideReelsTab false should allow the profile tab")
        failures += 1

    # A username-style allow must not unblock the feed. The feed check is first.
    broad = json.loads(json.dumps(config))
    broad["allowedPaths"] = list(broad["allowedPaths"]) + ["^/[^/]+$"]
    if decide("/reels/", broad, swift) != "block":
        print("FAIL broad allow regex unblocked the Reels feed")
        failures += 1
    if decide("/reel/", broad, swift) != "allow":
        print("FAIL /reel/ should not be treated as the feed")
        failures += 1

    if failures:
        print(f"{failures} failed")
        return 1
    print(f"ok {len(base_cases)} base cases; safety patterns match ({len(swift)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
