#!/usr/bin/env python3
"""Consistency of the workflow input types (tests/params/run.sh).

  1 workflows/admission/workflow-parameters.yaml is what generate.py makes of
    workflows/params/types.yaml
  2 every input of every WorkflowTemplate has a type, every typed input exists,
    enums agree, and every default satisfies its type
  2b the discover step of every template with clusterMap receives the filter,
     the clusterMap and (filters pairs and any) the instances inputs
  3 workflows/params/cluster-map-keys.yaml: the workflows it names take
    clusterMap, the types exist, and every default input ("flag") is an input
    of that workflow
  4 docs/workflow-commands.md: every input table row carries the Type of that
    input as types.yaml declares it
Prints one line per problem; exit 1 when there is any.
"""
import glob
import os
import re
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
problems = []

# 1
r = subprocess.run([sys.executable, os.path.join(ROOT, "workflows/params/generate.py"), "--check"],
                   capture_output=True, text=True)
if r.returncode != 0:
    problems.append(r.stderr.strip() or "generate.py --check failed")

src = yaml.safe_load(open(os.path.join(ROOT, "workflows/params/types.yaml")))
types, typed = src["types"], src["templates"]


def type_ok(spec, value):
    t = spec["type"]
    if value == "" and spec.get("allowEmpty"):
        return True
    if t == "string":
        return True
    if t == "enum":
        return value in [str(v) for v in spec["values"]]
    pat = types[t]["pattern"]
    # CEL uses RE2; these patterns are also valid Python regular expressions
    if not re.search(pat, value):
        return False
    if types[t].get("excludeAll") and any(x.strip() == "all" for x in value.split(",")):
        return False
    return True


# 2
templates = {}
for f in sorted(glob.glob(os.path.join(ROOT, "workflows/templates/*.yaml"))):
    doc = yaml.safe_load(open(f))
    name = doc["metadata"]["name"]
    if name == "tpg-lib":
        continue
    params = {p["name"]: p for p in doc["spec"].get("arguments", {}).get("parameters", [])}
    templates[name] = params
    if name not in typed:
        problems.append(f"{name}: no entry in workflows/params/types.yaml")
        continue
    for p, spec in params.items():
        if p not in typed[name]:
            problems.append(f"{name}.{p}: input without a type in types.yaml")
            continue
        ts = typed[name][p]
        default = str(spec.get("value", ""))
        if not type_ok(ts, default):
            problems.append(f"{name}.{p}: default '{default}' is not {types[ts['type']]['describe']}")
        if "enum" in spec:
            tenum = [str(v) for v in spec["enum"] if str(v) != ""]
            if ts["type"] == "enum":
                if sorted(tenum) != sorted(str(v) for v in ts["values"]):
                    problems.append(f"{name}.{p}: enum {tenum} differs from types.yaml {ts['values']}")
            elif ts["type"] == "boolean":
                if sorted(tenum) != ["false", "true"]:
                    problems.append(f"{name}.{p}: boolean enum {tenum}")
            else:
                problems.append(f"{name}.{p}: the template has an enum but types.yaml says {ts['type']}")
            if "" in [str(v) for v in spec["enum"]] and not ts.get("allowEmpty"):
                problems.append(f"{name}.{p}: the enum allows empty but types.yaml has no allowEmpty")
    for p in typed[name]:
        if p not in params:
            problems.append(f"{name}.{p}: typed in types.yaml but not an input of the template")
for name in typed:
    if name not in templates:
        problems.append(f"types.yaml: {name} is not a WorkflowTemplate")

# 2b the discover step of a template that selects instances receives the selection
def _discover_steps(x):
    if isinstance(x, dict):
        if x.get("templateRef", {}).get("template") == "discover":
            yield {p["name"]: str(p.get("value", "")) for p in x.get("arguments", {}).get("parameters", [])}
        for v in x.values():
            yield from _discover_steps(v)
    elif isinstance(x, list):
        for v in x:
            yield from _discover_steps(v)


for f in sorted(glob.glob(os.path.join(ROOT, "workflows/templates/*.yaml"))):
    doc = yaml.safe_load(open(f))
    name = doc["metadata"]["name"]
    params = templates.get(name, {})
    if "clusterMap" not in params:
        continue
    for args in _discover_steps(doc):
        flt = args.get("filter", "")
        if not flt:
            problems.append(f"{name}: the discover step has no filter, so instances and clusterMap are ignored")
            continue
        if flt != "off" and "clusterMap" not in args:
            problems.append(f"{name}: the discover step (filter {flt}) does not receive clusterMap")
        if flt in ("pairs", "any") and "instances" in params and "instances" not in args:
            problems.append(f"{name}: the discover step (filter {flt}) does not receive instances")

# 3
keys = yaml.safe_load(open(os.path.join(ROOT, "workflows/params/cluster-map-keys.yaml")))
tmpl = {"scale": "tpg-scale-instance"}
known_types = {"string", "name", "boolean", "integer", "posint", "quantity", "enum", "operatorVersion",
               "postgresVersion", "pathList"}
# tpg-upgrade takes the default of operatorVersion and postgresVersion from
# targetVersion (validate-params.sh upgrade), not from inputs of those names
flag_exceptions = {("tpg-upgrade", "operatorVersion"), ("tpg-upgrade", "postgresVersion")}
for w in keys["workflows"]:
    t = tmpl.get(w, "tpg-" + w)
    if "clusterMap" not in templates.get(t, {}):
        problems.append(f"cluster-map-keys.yaml: {t} has no clusterMap input")
for level in ("cluster", "instance"):
    for k, spec in keys[level].items():
        if spec["type"] not in known_types:
            problems.append(f"cluster-map-keys.yaml {level}.{k}: unknown type {spec['type']}")
        for w in spec.get("workflows", {}):
            if w not in keys["workflows"]:
                problems.append(f"cluster-map-keys.yaml {level}.{k}: unknown workflow {w}")
                continue
            t = tmpl.get(w, "tpg-" + w)
            flag = spec.get("flag", k)
            if flag and (t, k) not in flag_exceptions and flag not in templates.get(t, {}) \
                    and spec["workflows"][w] != "guard":
                problems.append(f"cluster-map-keys.yaml {level}.{k}: default input {flag} is not an input of {t}")

# 4 input tables: a table whose header starts with "| Input | Type |", inside the
# section "## N. tpg-<name>" of that WorkflowTemplate
md = open(os.path.join(ROOT, "docs/workflow-commands.md")).read()
section, in_table = None, False
documented = {s: set() for s in typed}
for line in md.splitlines():
    m = re.match(r"^## \d+\. (tpg-[a-z0-9-]+)", line)
    if line.startswith("## "):
        section = m.group(1) if m else None
        in_table = False
        continue
    if not line.startswith("|"):
        in_table = False
        continue
    if re.match(r"^\| Input \| Type \|", line):
        in_table = True
        if section not in typed:
            problems.append(f"docs/workflow-commands.md: an input table outside a tpg-<name> section ({section})")
        continue
    if not in_table or section not in typed or line.startswith("|---"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    names = re.findall(r"`([A-Za-z]+)`", cells[0])
    if not names:
        problems.append(f"docs/workflow-commands.md {section}: input row without an input name: {line}")
    for n in names:
        documented[section].add(n)
        if n not in typed[section]:
            problems.append(f"docs/workflow-commands.md {section}: `{n}` is not an input of the template")
            continue
        want = types[typed[section][n]["type"]]["display"]
        if cells[1].strip("`") != want:
            problems.append(f"docs/workflow-commands.md {section}: `{n}` Type is '{cells[1]}', types.yaml says '{want}'")
for s, params in typed.items():
    missing = [p for p in params if p != "toolsImage" and p not in documented.get(s, set())]
    if missing:
        problems.append(f"docs/workflow-commands.md {s}: inputs without a row in an input table: {', '.join(missing)}")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
