#!/usr/bin/env python3
"""Validate the per-environment Helm values files for a multi-environment app.

WHY this gate exists
--------------------
dev/stage/prod are three NAMESPACES on one cluster, all rendered from one shared
chart. That makes several silent, high-blast-radius mistakes possible in review,
none of which ``helm template`` exits non-zero for:

1. **A leaked placeholder image.** The chart's ``image.tag`` default is empty so
   an unpinned render fails loudly, but nothing stops a literal ``bootstrap`` or
   ``REPLACE_WITH_GIT_SHA`` from being *committed* in an environment file. That is
   exactly how the previous ``prod-bootstrap`` tag reached prod's manifest and
   left the Deployment unable to pull anything.

2. **A missing digest.** A tag alone is mutable in principle; the promotion
   contract in promote.yml is that what reaches prod is byte-identical to what
   stage validated, and only a digest proves that.

3. **Two environments sharing a value that must differ.** If stage and prod both
   declare ``environment: stage``, telemetry from both lands in the same Grafana
   bucket and production signal is diluted by pre-production noise. Both files are
   individually valid; only comparing them catches it.

4. **A PDB that deadlocks eviction.** ``minAvailable >= replicaCount`` blocks
   voluntary eviction outright, so Karpenter consolidation and ``kubectl drain``
   hang forever. The chart itself fails on this, but checking here reports all
   environments at once instead of stopping at the first.

Usage:
    python3 scripts/helm_values_gate.py charts/mcp-backend gitops/apps/mcp-backend
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import yaml

# Sentinels that must never survive into a committed environment file. Kept as a
# tuple so a new placeholder convention can be added without touching the logic.
FORBIDDEN_IMAGE_TOKENS = (
    "PLACEHOLDER",
    "REPLACE_WITH",
    "<account>",
    "bootstrap",
    "latest",
)

ENVIRONMENTS = ("dev", "stage", "prod")


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    chart_dir = Path(sys.argv[1])
    values_dir = Path(sys.argv[2])

    if not (chart_dir / "Chart.yaml").is_file():
        fail(f"{chart_dir} is not a Helm chart (no Chart.yaml)")
        return 1

    errors: list[str] = []
    seen_environment_tags: dict[str, str] = {}

    for env in ENVIRONMENTS:
        values_file = values_dir / f"values-{env}.yaml"
        if not values_file.is_file():
            errors.append(f"missing environment values file: {values_file}")
            continue

        values = yaml.safe_load(values_file.read_text()) or {}
        image = values.get("image") or {}
        tag = str(image.get("tag") or "")
        digest = str(image.get("digest") or "")

        # 1. Placeholder detection.
        if not tag:
            errors.append(f"{values_file}: image.tag is empty — the environment is unpinned")
        else:
            for token in FORBIDDEN_IMAGE_TOKENS:
                if token.lower() in tag.lower():
                    errors.append(
                        f"{values_file}: image.tag {tag!r} contains the placeholder "
                        f"{token!r}. A real, pushed tag is required."
                    )

        # 2. Digest required.
        if not digest:
            errors.append(
                f"{values_file}: image.digest is empty. Pin by digest so the artifact "
                f"promoted onward is provably the bytes that were validated."
            )
        elif not digest.startswith("sha256:"):
            errors.append(f"{values_file}: image.digest {digest!r} is not a sha256 reference")

        # 3. Environment tag must be present and unique across environments.
        environment = values.get("environment")
        if not environment:
            errors.append(f"{values_file}: 'environment' is unset — telemetry cannot be split")
        elif environment in seen_environment_tags:
            errors.append(
                f"{values_file}: environment {environment!r} is also declared in "
                f"{seen_environment_tags[environment]}. Two environments reporting the "
                f"same tag makes their telemetry indistinguishable."
            )
        else:
            seen_environment_tags[str(environment)] = str(values_file)

        # 4. PDB sanity.
        pdb = values.get("podDisruptionBudget") or {}
        if pdb.get("enabled"):
            min_available = int(pdb.get("minAvailable", 1))
            replicas = int(values.get("replicaCount", 1))
            if min_available >= replicas:
                errors.append(
                    f"{values_file}: podDisruptionBudget.minAvailable ({min_available}) >= "
                    f"replicaCount ({replicas}). This blocks voluntary eviction and "
                    f"deadlocks node drains and Karpenter consolidation."
                )

        # 5. The render itself must succeed. This is the check that catches a
        #    values key the chart's `required` guards reject.
        result = subprocess.run(
            [
                "helm",
                "template",
                chart_dir.name,
                str(chart_dir),
                "-f",
                str(values_file),
                "--namespace",
                f"mcp-{env}",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            errors.append(f"{values_file}: helm template failed:\n{result.stderr.strip()}")
            continue

        # 6. And no sentinel may survive into the RENDERED output either —
        #    a placeholder could arrive via the chart's own defaults, not just
        #    the environment file.
        rendered = result.stdout
        for token in ("PLACEHOLDER_IMAGE", "REPLACE_WITH", "OVERRIDDEN_BY"):
            if token in rendered:
                errors.append(f"{values_file}: rendered output still contains {token!r}")

    if errors:
        for error in errors:
            fail(error)
        print(f"\n{len(errors)} problem(s) found in {values_dir}", file=sys.stderr)
        return 1

    print(f"OK: {values_dir} — all {len(ENVIRONMENTS)} environments pinned, unique and renderable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
