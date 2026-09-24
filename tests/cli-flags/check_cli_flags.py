#!/usr/bin/env python3
"""Find CLI flags that the pinned version of a tool no longer accepts.

Why this exists
---------------
The workflow steps run in alpine/k8s:1.35.8, which ships Helm 4. Helm 4 removed
``helm list -a``. Nothing in a YAML linter, shellcheck or kubeconform looks at
the flags inside a command, so a removed flag reaches a cluster and fails a step
at run time, halfway through a Day 0 deployment. This check reads the commands
out of the repository and compares their flags with a rules file.

Two modes
---------
``--rules``       (default) apply tests/cli-flags/rules.yaml. Needs no binaries.
``--against-cli`` additionally ask each installed binary for its own flags
                  (``<tool> <subcommand> --help``) and report every flag the
                  repository uses that the binary does not know. This catches
                  changes nobody has written a rule for yet. Tools that are not
                  installed are skipped, so the check is safe in CI.

What is scanned
---------------
``*.sh``            command lines, with backslash continuations joined
``*.yaml``/``*.yml`` the same, over the raw text (Go templates make these files
                    unparsable as YAML, and a command is a command either way)
``*.md``            fenced code blocks and inline code spans

Exit status: 0 when nothing at error severity was found, 1 otherwise.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the repository already requires PyYAML
    sys.exit("PyYAML is required: pip install pyyaml")

SCAN_SUFFIXES = (".sh", ".yaml", ".yml", ".md", ".bash")
SKIP_DIRS = {".git", ".work", "node_modules", "__pycache__"}

# Splitting a shell line into the commands it runs. Good enough for the shapes
# that appear here: pipelines, && / || lists and ; separators.
SPLIT = re.compile(r"\|\||&&|[|;]|\$\(|`|\n")
FLAG = re.compile(r"^-{1,2}[A-Za-z0-9]")


class Finding:
    def __init__(self, path, line, rule_id, severity, text, message, fix):
        self.path, self.line, self.rule_id = path, line, rule_id
        self.severity, self.text = severity, text
        self.message, self.fix = message, fix

    def __str__(self):
        out = [
            f"{self.path}:{self.line}: {self.severity.upper()} [{self.rule_id}]",
            f"    command: {self.text.strip()[:160]}",
            f"    {' '.join(self.message.split())}",
        ]
        if self.fix:
            out.append(f"    fix: {' '.join(self.fix.split())}")
        return "\n".join(out)


# --------------------------------------------------------------- extraction
def fragments(path, text):
    """Yield (line_number, command_text) for every command-looking fragment."""
    suffix = os.path.splitext(path)[1]
    lines = text.splitlines()

    if suffix == ".md":
        regions, in_fence, start = [], False, 0
        buf = []
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith("```"):
                if in_fence:
                    regions.append((start, buf))
                    buf, in_fence = [], False
                else:
                    in_fence, start = True, n + 1
                continue
            if in_fence:
                buf.append(line)
            else:
                # inline code spans, e.g. `helm list -a`
                for span in re.findall(r"`([^`]+)`", line):
                    regions.append((n, [span]))
        if in_fence:
            regions.append((start, buf))
        for first, block in regions:
            yield from _join(first, block)
        return

    yield from _join(1, lines)


def _join(first_line, lines):
    """Join backslash continuations, then split into single commands."""
    buf, buf_line = "", first_line
    for offset, line in enumerate(lines):
        n = first_line + offset
        if not buf:
            buf_line = n
        stripped = line.rstrip()
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        buf += stripped
        for part in SPLIT.split(buf):
            part = part.strip()
            if part:
                yield buf_line, part
        buf = ""
    if buf.strip():
        for part in SPLIT.split(buf):
            if part.strip():
                yield buf_line, part.strip()


def tokenize(fragment):
    try:
        return shlex.split(fragment, comments=True, posix=False)
    except ValueError:
        return fragment.split()


def invocations(tokens, tools):
    """Yield (tool_name, subcommand, flags, args) for each tool call in tokens."""
    names = {}
    for name, cfg in tools.items():
        names[name] = name
        for alias in cfg.get("aliases") or []:
            names[alias] = name

    i = 0
    while i < len(tokens):
        raw = tokens[i].strip("\"'")
        base = raw.rsplit("/", 1)[-1]
        tool = names.get(base)
        # "helm()" or "h()" is a function definition, not a call
        if tool is None or raw.endswith("()") or (i + 1 < len(tokens) and tokens[i + 1].startswith("()")):
            i += 1
            continue
        cfg = tools[tool]
        value_flags = set(cfg.get("value_flags") or [])
        j, sub, flags, args = i + 1, None, [], []
        while j < len(tokens):
            t = tokens[j].strip("\"'")
            if FLAG.match(t):
                flags.append(t)
                if sub is None and t in value_flags:
                    j += 1  # its value, not the subcommand
            elif sub is None:
                sub = t
            else:
                args.append(t)
            j += 1
        yield tool, sub, flags, args
        i = j


# --------------------------------------------------------------- rule engine
def flag_matches(used, wanted):
    """-a matches -a and -abc?  No: only the exact flag, or --flag=value."""
    name = wanted.split("=", 1)[0]
    if "=" in wanted:
        return used == wanted
    return used == name or used.startswith(name + "=")


def apply_rules(path, rules, tools):
    findings = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    for line, fragment in fragments(path, text):
        tokens = tokenize(fragment)
        if not tokens:
            continue
        for tool, sub, flags, args in invocations(tokens, tools):
            for rule in rules:
                if rule["tool"] != tool:
                    continue
                subs = rule.get("subcommands") or ["*"]
                if "*" not in subs and sub not in subs:
                    continue
                for want in rule.get("flags") or []:
                    if any(flag_matches(f, want) for f in flags):
                        findings.append(Finding(path, line, rule["id"], rule.get("severity", "error"),
                                                fragment, rule["message"], rule.get("fix", "")))
                        break
                pattern = rule.get("arg_forbid")
                if pattern:
                    for candidate in args + flags:
                        if re.search(pattern, candidate):
                            findings.append(Finding(path, line, rule["id"], rule.get("severity", "error"),
                                                    fragment, rule["message"], rule.get("fix", "")))
                            break
    return findings


# --------------------------------------------------- flags of the real binary
def known_flags(tool, sub):
    """Flags reported by `tool [sub] --help`, or None when it cannot be asked."""
    cmd = [tool] + ([sub] if sub else []) + ["--help"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    out = proc.stdout + proc.stderr
    if not out.strip():
        return None
    found = set(re.findall(r"(?<![\w-])(--[a-zA-Z0-9][\w-]*)", out))
    found |= set(re.findall(r"(?<![\w-])(-[a-zA-Z0-9]),", out))
    return found or None


def against_cli(paths, tools, used):
    findings = []
    cache = {}
    for (tool, sub), where in sorted(used.items()):
        if not shutil.which(tool) or sub is None:
            continue
        key = (tool, sub)
        if key not in cache:
            cache[key] = known_flags(tool, sub)
        known = cache[key]
        if known is None:
            continue
        globals_ = cache.setdefault((tool, None), known_flags(tool, None)) or set()
        for flag, path, line, fragment in where:
            name = flag.split("=", 1)[0]
            if name in known or name in globals_:
                continue
            findings.append(Finding(
                path, line, f"unknown-flag:{tool} {sub}", "error", fragment,
                f"{tool} {sub} does not accept {name} in the version installed here "
                f"({installed_version(tool)}).",
                "Check the tool's release notes and update the command, or add a rule to rules.yaml."))
    return findings


def installed_version(tool):
    for args in (["version", "--short"], ["version"], ["--version"]):
        try:
            proc = subprocess.run([tool] + args, capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            continue
        line = (proc.stdout or proc.stderr).strip().splitlines()
        if line:
            return line[0][:80]
    return "unknown version"


def collect_used(path, tools, used):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    for line, fragment in fragments(path, text):
        for tool, sub, flags, _args in invocations(tokenize(fragment), tools):
            for flag in flags:
                used.setdefault((tool, sub), []).append((flag, path, line, fragment))


# --------------------------------------------------------------------- main
def walk(roots):
    for root in roots:
        if os.path.isfile(root):
            yield root
            continue
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for name in sorted(files):
                if name.endswith(SCAN_SUFFIXES):
                    yield os.path.join(base, name)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", default=["."], help="files or directories to scan (default: .)")
    ap.add_argument("--rules-file", default=os.path.join(here, "rules.yaml"))
    ap.add_argument("--against-cli", action="store_true",
                    help="also check every used flag against the installed binary's --help")
    ap.add_argument("--expect", metavar="ID", action="append", default=[],
                    help="self-test: require a finding with this rule id (repeatable)")
    ap.add_argument("--expect-only", action="store_true",
                    help="self-test: fail when a finding outside --expect appears, and succeed on the expected ones")
    args = ap.parse_args()

    with open(args.rules_file, "r", encoding="utf-8") as fh:
        spec = yaml.safe_load(fh)
    tools, rules = spec["tools"], spec["rules"]

    findings, used = [], {}
    files = list(walk(args.paths or ["."]))
    for path in files:
        findings += apply_rules(path, rules, tools)
        if args.against_cli:
            collect_used(path, tools, used)
    if args.against_cli:
        findings += against_cli(files, tools, used)

    if args.expect or args.expect_only:
        got = sorted({f.rule_id for f in findings})
        missing = [e for e in args.expect if e not in got]
        extra = [g for g in got if g not in args.expect] if args.expect_only else []
        for f in findings:
            print(f)
        if missing or extra:
            if missing:
                print(f"\nself-test FAILED: no finding for {', '.join(missing)}", file=sys.stderr)
            if extra:
                print(f"\nself-test FAILED: unexpected findings {', '.join(extra)}", file=sys.stderr)
            return 1
        print(f"\nself-test passed: {len(args.expect)} planted violation(s) detected in {len(files)} file(s)")
        return 0

    errors = [f for f in findings if f.severity == "error"]
    for f in findings:
        print(f)
    print(f"\n{len(files)} file(s) scanned, {len(errors)} error(s), "
          f"{len(findings) - len(errors)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
