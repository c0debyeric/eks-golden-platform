#!/usr/bin/env python3
"""Assert every committed CR's apiVersion is actually SERVED by its pinned chart's CRDs.

Why: an apiVersion/chart mismatch is the single highest-frequency ArgoCD failure in this
repo's history, and it surfaces only as the opaque "one or more synchronization tasks are
not valid" -- no mention of the version. This closes the loop mechanically instead of
trusting release notes.

Usage: crd_apiversion_gate.py <rendered-chart.yaml> <cr-manifest.yaml> [<cr-manifest.yaml>...]
Exit 1 on any mismatch so it can gate CI.
"""
import sys, yaml

def load(path):
    with open(path) as fh:
        # Helm output and multi-doc manifests both contain None/comment-only docs.
        return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]

rendered, manifests = sys.argv[1], sys.argv[2:]

# Build {(group, Kind): {served versions}} from the chart's own CRDs.
served: dict[tuple[str, str], set[str]] = {}
for doc in load(rendered):
    if doc.get("kind") != "CustomResourceDefinition":
        continue
    spec = doc.get("spec", {})
    key = (spec.get("group"), spec.get("names", {}).get("kind"))
    served[key] = {v["name"] for v in spec.get("versions", []) if v.get("served")}

failures = 0
for path in manifests:
    for cr in load(path):
        api, kind = cr.get("apiVersion", ""), cr.get("kind")
        if "/" not in api:
            continue  # core group (v1 Secret etc.) -- not CRD-backed
        group, version = api.split("/", 1)
        ok = served.get((group, kind))
        if ok is None:
            continue  # CRD not from this chart; another chart owns it
        status = "OK " if version in ok else "FAIL"
        if version not in ok:
            failures += 1
        print(f"{status} {kind:22s} {api:34s} served={sorted(ok)}")

print(f"\n{'PASS: all CR apiVersions served' if not failures else f'FAIL: {failures} mismatch(es)'}")
sys.exit(1 if failures else 0)
