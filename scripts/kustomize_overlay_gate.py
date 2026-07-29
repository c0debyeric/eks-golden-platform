#!/usr/bin/env python3
"""Validate the per-environment kustomize overlays for a multi-env app.

WHY this gate exists
--------------------
dev/stage/prod are three NAMESPACES on one cluster, all rendered from one shared base.
That makes two silent, high-blast-radius mistakes possible in review:

1. A missing or duplicated ``namespace:`` in an overlay. Two overlays naming the same
   namespace means the later Argo CD sync overwrites the earlier env's workloads in
   place — dev would redeploy over prod with no error anywhere, because both
   Applications are individually valid and both report Synced.

2. A leaked placeholder image. The base intentionally carries a sentinel
   (``PLACEHOLDER_IMAGE``) so a mistyped overlay fails loudly, but nothing stops that
   sentinel from being *committed* in an overlay. That is exactly how the previous
   literal ``REPLACE_WITH_GIT_SHA`` reached the cluster and pinned the Deployment in
   ``InvalidImageName``.

Neither is caught by ``kubectl kustomize`` exiting 0 — the render succeeds, it is the
*content* that is wrong. Hence a content assertion rather than a build check.

Usage:
    crd_apiversion_gate.py-style CLI, one arg: the app directory containing overlays/.
        python3 scripts/kustomize_overlay_gate.py gitops/apps/mcp-backend
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import yaml

# Sentinels that must never survive into a rendered overlay. Kept as a tuple so a new
# placeholder convention can be added without touching the logic below.
FORBIDDEN_IMAGE_TOKENS = ("PLACEHOLDER_IMAGE", "REPLACE_WITH", "<account>")

# Values the base uses to force an overlay to declare its own. If one of these reaches a
# rendered object, an overlay forgot its patch.
FORBIDDEN_VALUE_TOKENS = ("OVERRIDDEN_BY_OVERLAY",)


def render(overlay: Path) -> list[dict]:
    """Render one overlay with the kustomize built into kubectl.

    Uses kubectl rather than a standalone kustomize binary so CI needs no extra install
    and the rendered output matches what a developer sees locally from `kubectl kustomize`.
    """
    proc = subprocess.run(
        ["kubectl", "kustomize", str(overlay)],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"FAIL: `kubectl kustomize {overlay}` errored:\n{proc.stderr.strip()}")
    return [d for d in yaml.safe_load_all(proc.stdout) if d]


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {Path(sys.argv[0]).name} <app-dir-containing-overlays>")

    app_dir = Path(sys.argv[1])
    overlay_root = app_dir / "overlays"
    if not overlay_root.is_dir():
        sys.exit(f"FAIL: {overlay_root} does not exist — expected per-env overlays there.")

    overlays = sorted(p for p in overlay_root.iterdir() if (p / "kustomization.yaml").is_file())
    if not overlays:
        sys.exit(f"FAIL: no overlays with a kustomization.yaml under {overlay_root}.")

    # env name -> namespace, used to prove the envs are mutually exclusive.
    claimed: dict[str, str] = {}
    failures: list[str] = []

    for overlay in overlays:
        env = overlay.name
        objects = render(overlay)

        namespaces = {o["metadata"].get("namespace") for o in objects}
        if None in namespaces:
            kinds = [o["kind"] for o in objects if not o["metadata"].get("namespace")]
            failures.append(
                f"[{env}] objects rendered with NO namespace: {kinds}. "
                "The overlay must set `namespace:` — the base deliberately does not."
            )
            namespaces.discard(None)

        if len(namespaces) > 1:
            failures.append(f"[{env}] renders into multiple namespaces {sorted(namespaces)}.")

        for ns in namespaces:
            if ns in claimed.values():
                other = next(e for e, n in claimed.items() if n == ns)
                failures.append(
                    f"[{env}] targets namespace '{ns}' which is ALREADY claimed by "
                    f"overlay '{other}'. Two envs sharing a namespace means one silently "
                    "overwrites the other's workloads on sync."
                )
            claimed[env] = ns

        for obj in objects:
            kind = obj["kind"]
            containers = (
                obj.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
                if kind == "Deployment"
                else []
            )
            for c in containers:
                image = c.get("image", "")
                for tok in FORBIDDEN_IMAGE_TOKENS:
                    if tok in image:
                        failures.append(
                            f"[{env}] container '{c['name']}' image still contains the "
                            f"placeholder '{tok}' ({image}). The overlay's `images:` block "
                            "must set a real ECR reference."
                        )
                for env_var in c.get("env", []):
                    val = str(env_var.get("value", ""))
                    for tok in FORBIDDEN_VALUE_TOKENS:
                        if tok in val:
                            failures.append(
                                f"[{env}] env var '{env_var['name']}' still has the base "
                                f"sentinel '{tok}' — the overlay patch did not apply."
                            )

    if failures:
        print("\n".join(f"FAIL: {f}" for f in failures))
        sys.exit(1)

    for env, ns in sorted(claimed.items()):
        print(f"PASS: overlay '{env}' -> namespace '{ns}' (unique, no placeholders)")


if __name__ == "__main__":
    main()
