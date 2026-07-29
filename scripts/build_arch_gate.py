#!/usr/bin/env python3
"""Assert the container build covers every CPU architecture the NodePool can provision.

WHY this gate exists
--------------------
The Karpenter NodePool intentionally allows ``kubernetes.io/arch In [amd64, arm64]`` to
pick up cheaper Graviton capacity, and the mcp-backend Deployment sets no nodeSelector.
So a pod may legitimately be scheduled onto either architecture.

If the image is built for only one of them, the failure is genuinely nasty:

  * The image PULLS successfully -- there is no ImagePullBackOff to point at.
  * The container then dies at exec with
        exec /usr/local/bin/docker-entrypoint.sh: exec format error
    which reads like a corrupt entrypoint or a bad base image, not an arch mismatch.
  * It only reproduces when the scheduler happens to pick the unsupported arch, so it
    can pass CI, pass a dev deploy, and then fail hours later after a Karpenter
    consolidation moves the pod. Observed live on an m9gd.medium node 2026-07-29.

Because both halves of the contract live in different files (the workflow's ``platforms:``
and the NodePool's arch requirement), nothing links them. This gate does.

Usage:
    python3 scripts/build_arch_gate.py \\
        .github/workflows/build-image.yml gitops/apps/karpenter/nodepool.yaml
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

# Maps the Kubernetes arch label value to the docker/buildx platform string.
K8S_ARCH_TO_PLATFORM = {
    "amd64": "linux/amd64",
    "arm64": "linux/arm64",
}


def nodepool_arches(path: Path) -> set[str]:
    """Return the set of kubernetes.io/arch values the NodePool may provision.

    An ABSENT arch requirement is treated as 'both', because Karpenter is then free to
    choose any architecture its instance families offer — the permissive case, which is
    exactly the one that breaks a single-arch image.
    """
    pool = yaml.safe_load(path.read_text())
    reqs = pool["spec"]["template"]["spec"]["requirements"]
    for r in reqs:
        if r["key"] != "kubernetes.io/arch":
            continue
        if r.get("operator") == "In":
            return set(r["values"])
        # NotIn / Exists leave the effective set open-ended; assume the permissive case
        # rather than guessing, so the gate errs toward demanding more coverage.
        return set(K8S_ARCH_TO_PLATFORM)
    return set(K8S_ARCH_TO_PLATFORM)


def build_platforms(path: Path) -> set[str]:
    """Return the platforms the build-and-push step targets.

    PyYAML parses the workflow's `on:` key as the boolean True, which is harmless here
    since only jobs/steps are inspected.
    """
    wf = yaml.safe_load(path.read_text())
    found: set[str] = set()
    for job in wf["jobs"].values():
        for step in job.get("steps", []):
            uses = str(step.get("uses", ""))
            if "docker/build-push-action" not in uses:
                continue
            raw = step.get("with", {}).get("platforms", "")
            # `platforms` accepts a comma-separated string or a YAML list.
            if isinstance(raw, str):
                found |= {p.strip() for p in raw.split(",") if p.strip()}
            else:
                found |= {str(p).strip() for p in raw}
    return found


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {Path(sys.argv[0]).name} <workflow.yml> <nodepool.yaml>")

    wf_path, pool_path = Path(sys.argv[1]), Path(sys.argv[2])
    arches = nodepool_arches(pool_path)
    platforms = build_platforms(wf_path)

    if not platforms:
        sys.exit(
            f"FAIL: no docker/build-push-action `platforms:` found in {wf_path}. "
            "An unspecified platform builds only the runner's arch (amd64), which will "
            "exec-format-error on any arm64 node."
        )

    required = {K8S_ARCH_TO_PLATFORM[a] for a in arches if a in K8S_ARCH_TO_PLATFORM}
    missing = required - platforms

    if missing:
        sys.exit(
            f"FAIL: NodePool may provision {sorted(arches)} but the image is only built "
            f"for {sorted(platforms)}.\n"
            f"       Missing: {sorted(missing)}\n"
            "       A pod scheduled onto the unbuilt arch PULLS FINE and then dies with\n"
            "       'exec format error', which does not look like an arch problem.\n"
            "       Either add the platform to build-push-action, or constrain the\n"
            "       Deployment with a nodeSelector (forfeiting cheaper Graviton capacity)."
        )

    print(
        f"PASS: NodePool arches {sorted(arches)} are all covered by "
        f"build platforms {sorted(platforms)}"
    )


if __name__ == "__main__":
    main()
