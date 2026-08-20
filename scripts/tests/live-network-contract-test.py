#!/usr/bin/env python3
"""실제 Node Pod CIDR과 계약/Squid ACL 교차검증 회귀 시험."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify/verify-live-network-contract.py"
PASSED = 0
FAILED = 0


def run_case(
    label: str,
    pod_cidrs: list[str],
    clients: list[str],
    success: bool,
    kubernetes_service_ip: str = "10.53.0.1",
    cluster_dns_ip: str = "10.53.0.10",
) -> None:
    global PASSED, FAILED
    contract = {
        "spec": {
            "network": {
                "podCIDRs": ["10.52.0.0/16"],
                "serviceCIDRs": ["10.53.0.0/16"],
                "clusterDNS": "10.53.0.10",
                "squid": {"clientCIDRs": clients},
            }
        }
    }
    nodes = {
        "items": [
            {
                "metadata": {"name": f"node-{index}"},
                "spec": {"podCIDRs": [cidr], "podCIDR": cidr},
            }
            for index, cidr in enumerate(pod_cidrs, start=1)
        ]
    }
    with tempfile.TemporaryDirectory(prefix="live-network-contract-test-") as temporary:
        contract_path = pathlib.Path(temporary) / "contract.yaml"
        contract_path.write_text(yaml.safe_dump(contract), encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(contract_path),
                kubernetes_service_ip,
                cluster_dns_ip,
            ],
            input=json.dumps(nodes),
            text=True,
            capture_output=True,
            check=False,
        )
    if (result.returncode == 0) == success:
        PASSED += 1
        print(f"[OK]   {label}")
    else:
        FAILED += 1
        print(f"[FAIL] {label}: exit={result.returncode} stderr={result.stderr.strip()}")


run_case(
    "LN-01 Node Pod CIDR이 계약과 Squid ACL 안이면 통과",
    ["10.52.0.0/24", "10.52.1.0/24"],
    ["10.20.30.0/24", "10.52.0.0/16"],
    True,
)
run_case(
    "LN-02 실제 Node Pod CIDR이 계약과 다르면 거부",
    ["10.54.0.0/24"],
    ["10.20.30.0/24", "10.52.0.0/16", "10.54.0.0/16"],
    False,
)
run_case(
    "LN-03 실제 Node Pod CIDR이 Squid ACL에서 빠지면 거부",
    ["10.52.0.0/24"],
    ["10.20.30.0/24"],
    False,
)
run_case(
    "LN-04 실제 Kubernetes Service IP가 계약 CIDR 밖이면 거부",
    ["10.52.0.0/24"],
    ["10.20.30.0/24", "10.52.0.0/16"],
    False,
    kubernetes_service_ip="10.54.0.1",
)
run_case(
    "LN-05 실제 CoreDNS Service IP가 계약과 다르면 거부",
    ["10.52.0.0/24"],
    ["10.20.30.0/24", "10.52.0.0/16"],
    False,
    cluster_dns_ip="10.53.0.11",
)

print(f"통과 {PASSED} / 실패 {FAILED}")
raise SystemExit(FAILED != 0)
