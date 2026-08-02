#!/usr/bin/env python3
"""Validate committed CRs against their pinned chart's CRD *schema*, not just apiVersion.

WHY THIS EXISTS (2026-07-29 outage):
`crd_apiversion_gate.py` proved `NodePool karpenter.sh/v1` was a served apiVersion and passed --
then Karpenter refused every NodeClaim it computed with:

    spec.requirements[6].operator: Unsupported value: "Gte"
      supported values: "In","NotIn","Exists","DoesNotExist","Gt","Lt"

The apiVersion was right; a FIELD VALUE inside it was not. Karpenter 1.14 added the Gte/Lte
operators, but the cluster still had CRDs from the 1.0.8 chart (Helm never upgrades `crds/`), so
the controller emitted values its own CRDs rejected. Result: zero capacity could be provisioned.

This gate closes that class of bug by walking the CRD's openAPIV3Schema and checking committed
field values against `enum` constraints -- catching operator/policy/type values that a chart bump
adds or removes. apiVersion checks and schema checks are complementary: keep both.

Deliberately dependency-free (PyYAML only) so it runs in CI without a venv.
"""
from __future__ import annotations

import sys
from typing import Any

import yaml


def load_all(path: str) -> list[dict[str, Any]]:
    """Parse a possibly multi-document YAML file, skipping empty documents."""
    with open(path) as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


def schema_for(crd: dict[str, Any], version: str) -> dict[str, Any] | None:
    """Return the openAPIV3Schema for a specific served version of a CRD."""
    for ver in crd.get("spec", {}).get("versions", []):
        if ver.get("name") == version:
            return ver.get("schema", {}).get("openAPIV3Schema")
    return None


def walk(node: Any, schema: dict[str, Any] | None, path: str, errors: list[str]) -> None:
    """Recursively compare a manifest subtree against its schema, collecting enum violations.

    Only `enum` is enforced. Types are intentionally NOT checked: CRD schemas use
    x-kubernetes-int-or-string and similar escape hatches, and a strict type check would produce
    false failures that teach people to ignore the gate -- the exact failure mode this repo's CI
    is designed to avoid.
    """
    if schema is None:
        return

    if isinstance(node, dict):
        props = schema.get("properties", {})
        for key, val in node.items():
            sub = props.get(key)
            if sub is None:
                # Unknown keys are the apiVersion gate's job, and CRDs legitimately allow
                # x-kubernetes-preserve-unknown-fields subtrees. Skip rather than false-fail.
                continue
            walk(val, sub, f"{path}.{key}", errors)
        return

    if isinstance(node, list):
        items = schema.get("items")
        for idx, val in enumerate(node):
            walk(val, items, f"{path}[{idx}]", errors)
        return

    # Scalar leaf: enforce enum membership when the schema declares one.
    enum = schema.get("enum")
    if enum is not None and node not in enum:
        errors.append(f"{path}: {node!r} not in {enum}")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(f"usage: {argv[0]} <chart-crds.yaml> <manifest.yaml> [manifest.yaml ...]")
        return 2

    crd_file, manifests = argv[1], argv[2:]

    # Index CRDs by (group, Kind) so a manifest's apiVersion/kind can find its schema.
    crds: dict[tuple[str, str], dict[str, Any]] = {}
    for doc in load_all(crd_file):
        if doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc.get("spec", {})
        crds[(spec.get("group", ""), spec["names"]["kind"])] = doc

    errors: list[str] = []
    checked = 0

    for manifest in manifests:
        for doc in load_all(manifest):
            api_version, kind = doc.get("apiVersion", ""), doc.get("kind", "")
            group, _, version = api_version.partition("/")
            if not version:  # core group ("v1") -- no CRD involved
                continue

            crd = crds.get((group, kind))
            if crd is None:
                continue  # apiVersion gate owns "is this CRD even present"

            schema = schema_for(crd, version)
            if schema is None:
                errors.append(f"{manifest}: {kind} {api_version} -- version not served")
                continue

            before = len(errors)
            walk(doc, schema, f"{manifest}:{kind}", errors)
            checked += 1
            status = "OK " if len(errors) == before else "BAD"
            print(f"{status} {kind:22} {api_version:34} schema-validated")

    if errors:
        print("\nFAIL: committed manifests violate the pinned chart's CRD schema:")
        for err in errors:
            print(f"  - {err}")
        print(
            "\nThis usually means a chart bump changed an allowed field value, or the cluster's\n"
            "CRDs are older than the controller (Helm does NOT upgrade crds/ on upgrade)."
        )
        return 1

    # Fail closed on an empty run. Every manifest lookup that misses a CRD is skipped, so a
    # CRD file that is empty or from the wrong chart validates NOTHING and still reports PASS.
    # Hit exactly that on 2026-08-02: `helm template --include-crds` emits no CRDs for the
    # karpenter chart (they ship in crds/, which only `helm pull --untar` materialises -- what
    # CI does). The gate printed "PASS: 0 manifest(s)" and looked green. A gate that cannot
    # tell "everything is valid" from "I checked nothing" is worse than no gate, because it
    # is trusted. If this fires, suspect how the CRD file was produced, not the manifests.
    if checked == 0:
        print(
            f"\nFAIL: validated 0 manifests against {crd_file}.\n"
            f"  Manifests given: {', '.join(manifests)}\n"
            "  Their apiVersion/kind matched no CustomResourceDefinition in that file, so\n"
            "  nothing was actually checked. Verify the CRD file is non-empty and came from\n"
            "  the right chart -- karpenter ships CRDs in crds/, which requires\n"
            "  `helm pull --untar` (`helm template --include-crds` does NOT emit them)."
        )
        return 1

    print(f"\nPASS: {checked} manifest(s) valid against the pinned chart's CRD schema")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
