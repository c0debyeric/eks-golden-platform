#!/usr/bin/env python3
"""Validate every committed OpenTelemetryCollector's pipeline config against the REAL collector.

WHY THIS EXISTS:
`crd_apiversion_gate.py` and `crd_schema_gate.py` both pass on a collector whose pipeline is
nonsense, because the OpenTelemetryCollector CRD declares `spec.config` with
`x-kubernetes-preserve-unknown-fields` — Kubernetes deliberately does not look inside it. The
schema is owned by the collector binary, not by the CRD.

The failure that motivated this gate: `prometheusremotewrite` accepts `remote_write_queue`, not
the `sending_queue` that every other exporter takes. That mistake is invisible to kubectl, to
`helm template`, to both existing CRD gates, and to ArgoCD — the Application syncs green and the
collector then CrashLoops with `has invalid keys: sending_queue`. Because the collector is the
single path to Prometheus, Loki and Tempo, a crash-looping gateway means the entire platform goes
blind while every dashboard shows a healthy cluster.

So: run the actual collector binary, from the exact image the pinned operator chart deploys, in
`validate` mode. If the config would not start, CI fails here instead of in the cluster.

Usage: otel_config_gate.py <collector-image> <collector-cr.yaml> [<collector-cr.yaml>...]
Exit 1 on any invalid config.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile

import yaml


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2

    image, manifests = sys.argv[1], sys.argv[2:]
    print(f"Validating against {image}\n")

    failures = 0
    for path in manifests:
        docs = [d for d in yaml.safe_load_all(pathlib.Path(path).read_text()) if isinstance(d, dict)]
        collectors = [d for d in docs if d.get("kind") == "OpenTelemetryCollector"]
        if not collectors:
            print(f"SKIP {path} (no OpenTelemetryCollector)")
            continue

        for cr in collectors:
            name = cr.get("metadata", {}).get("name", "<unnamed>")
            config = cr.get("spec", {}).get("config")
            if not config:
                print(f"FAIL {path} [{name}]: spec.config is empty")
                failures += 1
                continue

            with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as fh:
                yaml.safe_dump(config, fh, sort_keys=False)
                tmp = fh.name
            # NamedTemporaryFile creates 0600 files. The collector image runs as a non-root
            # user, so a bind-mounted 0600 file is unreadable inside the container and every
            # config "fails" with a permission error that looks exactly like a real config
            # error. Widen to 0644 before mounting.
            pathlib.Path(tmp).chmod(0o644)

            # K8S_NODE_NAME is supplied via the downward API in-cluster; k8sattributes'
            # node_from_env_var check runs at validate time, so it must be set here too.
            proc = subprocess.run(
                [
                    "docker", "run", "--rm",
                    "-e", "K8S_NODE_NAME=ci-validation",
                    "-v", f"{tmp}:/cfg.yaml:ro",
                    image, "validate", "--config=/cfg.yaml",
                ],
                capture_output=True,
                text=True,
            )
            pathlib.Path(tmp).unlink(missing_ok=True)

            if proc.returncode == 0:
                pipelines = sorted(config.get("service", {}).get("pipelines", {}))
                print(f"OK   {path} [{name}] pipelines={pipelines}")
            else:
                print(f"FAIL {path} [{name}]")
                print((proc.stderr or proc.stdout).strip())
                failures += 1

    print()
    if failures:
        print(f"FAIL: {failures} collector config(s) would not start")
        return 1
    print("PASS: all collector configs valid for the pinned collector build")
    return 0


if __name__ == "__main__":
    sys.exit(main())
