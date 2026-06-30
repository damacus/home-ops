#!/usr/bin/env python3
"""Run repository-local Mondoo/cnspec scans through stable task entrypoints."""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


ROOT_DIR = Path(__file__).resolve().parents[1]
POLICY_DIR = ROOT_DIR / "mondoo" / "policies"
KUBERNETES_POLICY = POLICY_DIR / "home-ops-kubernetes.mql.yaml"
NODE_POLICY = POLICY_DIR / "home-ops-node.mql.yaml"
IMAGE_POLICY = POLICY_DIR / "home-ops-image.mql.yaml"
CUSTOM_RISK_THRESHOLD = "1"
REPORT_ONLY_RISK_THRESHOLD = "101"
FLATE_API_VERSIONS = (
    "policy/v1/PodDisruptionBudget,"
    "monitoring.coreos.com/v1,"
    "monitoring.coreos.com/v1/ServiceMonitor,"
    "monitoring.coreos.com/v1/PodMonitor,"
    "monitoring.coreos.com/v1/PrometheusRule"
)


@dataclass(frozen=True)
class AppScan:
    policy: str
    asset_name: str


APP_SCANS: dict[str, AppScan] = {
    "authentication/zitadel": AppScan(
        policy="home-ops-app-zitadel",
        asset_name="home-ops-zitadel",
    ),
    "monitoring/grafana": AppScan(
        policy="home-ops-app-grafana",
        asset_name="home-ops-grafana-oidc",
    ),
    "home-automation/paperless": AppScan(
        policy="home-ops-app-paperless",
        asset_name="home-ops-paperless-oidc",
    ),
    "home/mealie": AppScan(
        policy="home-ops-app-mealie",
        asset_name="home-ops-mealie-oidc",
    ),
}


MIGRATED_COMPLIANCE_CHECKS: dict[str, list[str]] = {
    "zitadel": [
        "ZITADEL-HTTPS-001",
        "ZITADEL-HTTPS-002",
        "ZITADEL-HEALTH-001",
        "ZITADEL-HEALTH-002",
        "ZITADEL-HEALTH-003",
        "ZITADEL-UI-001",
        "ZITADEL-UI-002",
        "ZITADEL-UI-003",
        "ZITADEL-OIDC-001",
        "ZITADEL-OIDC-002",
        "ZITADEL-OIDC-003",
        "ZITADEL-LOGIN-002",
        "ZITADEL-LOGIN-003",
        "ZITADEL-API-001",
        "ZITADEL-API-002",
        "ZITADEL-SEC-001",
    ],
    "grafana": [
        "grafana-oidc-config",
        "grafana-oidc-secret",
        "grafana-oidc-endpoints",
    ],
    "paperless": [
        "paperless-oidc-config",
        "paperless-oidc-secret",
        "paperless-oidc-endpoints",
    ],
    "mealie": [
        "mealie-oidc-config",
        "mealie-oidc-secret",
        "mealie-oidc-endpoints",
        "mealie-oidc-api-endpoint",
    ],
    "node": [
        "NODE-USER-001",
        "NODE-USER-002",
        "NODE-USER-003",
        "NODE-SSH-001",
        "NODE-SSH-002",
        "NODE-SSH-003",
        "NODE-SYS-001",
        "NODE-SYS-002",
        "NODE-SYS-003",
        "NODE-SYS-004",
        "NODE-SYS-005",
        "NODE-KERNEL-001",
        "NODE-KERNEL-002",
        "NODE-KERNEL-003",
        "NODE-KERNEL-004",
        "NODE-STORAGE-001",
        "NODE-STORAGE-002",
        "NODE-BOOT-001",
        "NODE-BOOT-002",
        "NODE-K3S-001",
        "NODE-K3S-002",
        "NODE-K3S-003",
        "NODE-K3S-004",
        "NODE-K3S-005",
        "NODE-CLUSTER-001",
        "NODE-CLUSTER-002",
        "NODE-CLUSTER-003",
        "NODE-PKG-001",
    ],
    "image": [
        "IMAGE-CLOUD-001",
        "IMAGE-CLOUD-002",
        "IMAGE-CLOUD-003",
        "IMAGE-CLOUD-004",
        "IMAGE-CLOUD-005",
        "IMAGE-STATE-001",
        "IMAGE-STATE-002",
        "IMAGE-STATE-003",
        "IMAGE-K3S-001",
        "IMAGE-K3S-002",
        "IMAGE-K3S-003",
        "IMAGE-K3S-004",
        "IMAGE-K3S-005",
        "IMAGE-K3S-006",
        "IMAGE-K3S-007",
        "IMAGE-SYS-001",
        "IMAGE-SYS-002",
        "IMAGE-SYS-003",
        "IMAGE-SYS-004",
        "IMAGE-SYS-005",
    ],
}


def report_target(report_dir: Path | None, name: str, output: str | None) -> str | None:
    if report_dir is None or output is None:
        return None
    suffix = "xml" if output == "junit" else output
    return str((report_dir / f"{name}.{suffix}").resolve())


def cnspec_scan_command(
    target: Sequence[str],
    *,
    policy_bundle: Path | None = None,
    policy: str | None = None,
    props: dict[str, str] | None = None,
    asset_name: str | None = None,
    output: str | None = None,
    output_target: str | None = None,
    risk_threshold: str = CUSTOM_RISK_THRESHOLD,
    sudo: bool = False,
    discover: Sequence[str] | None = None,
) -> list[str]:
    command = ["cnspec", "scan", *target, "--incognito", "--risk-threshold", risk_threshold]
    if sudo:
        command.append("--sudo")
    for target_discovery in discover or []:
        command.extend(["--discover", target_discovery])
    if policy_bundle is not None:
        command.extend(["--policy-bundle", str(policy_bundle)])
    if policy is not None:
        command.extend(["--policy", policy])
    if asset_name is not None:
        command.extend(["--asset-name", asset_name])
    for key, value in sorted((props or {}).items()):
        command.extend(["--props", f"{key}={value}"])
    if output is not None:
        command.extend(["--output", output])
    if output_target is not None:
        command.extend(["--output-target", output_target])
    return command


def flux_render_command(path: str) -> list[str]:
    return ["flate", "build", "all", "--api-versions", FLATE_API_VERSIONS, "--path", path]


def run(command: Sequence[str], *, stdout=None, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=check, text=True, stdout=stdout)


def run_scan(command: Sequence[str], *, check: bool = True) -> None:
    run(command, check=check)


def run_k8s_manifests(args: argparse.Namespace) -> None:
    report_dir = Path(args.report_dir).resolve() if args.report_dir else None
    if report_dir is not None:
        report_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="home-ops-mondoo-") as temp_dir:
        rendered_manifest = Path(temp_dir) / "rendered.yaml"
        with rendered_manifest.open("w", encoding="utf-8") as output:
            run(flux_render_command(args.path), stdout=output)

        output_target = report_target(report_dir, "k8s-manifests-custom", args.output)
        run_scan(
            cnspec_scan_command(
                ["k8s", str(rendered_manifest)],
                policy_bundle=KUBERNETES_POLICY,
                policy="home-ops-kubernetes-manifests",
                asset_name="home-ops-rendered-manifests",
                output=args.output,
                output_target=output_target,
                discover=["clusters"],
            )
        )

        if args.include_posture:
            output_target = report_target(report_dir, "k8s-manifests-posture", args.output)
            run_scan(
                cnspec_scan_command(
                    ["k8s", str(rendered_manifest)],
                    asset_name="home-ops-rendered-manifests-posture",
                    output=args.output,
                    output_target=output_target,
                    risk_threshold=REPORT_ONLY_RISK_THRESHOLD,
                ),
                check=False,
            )


def run_k8s_live(args: argparse.Namespace) -> None:
    report_dir = Path(args.report_dir).resolve() if args.report_dir else None
    if report_dir is not None:
        report_dir.mkdir(parents=True, exist_ok=True)
    output_target = report_target(report_dir, "k8s-live-posture", args.output)
    run_scan(
        cnspec_scan_command(
            ["k8s"],
            asset_name="home-ops-live-cluster",
            output=args.output,
            output_target=output_target,
            risk_threshold=REPORT_ONLY_RISK_THRESHOLD,
        ),
        check=False,
    )


def run_app(args: argparse.Namespace) -> None:
    try:
        app_scan = APP_SCANS[args.app]
    except KeyError as error:
        known_apps = ", ".join(sorted(APP_SCANS))
        raise SystemExit(f"Unknown app '{args.app}'. Known apps: {known_apps}") from error

    report_dir = Path(args.report_dir).resolve() if args.report_dir else None
    if report_dir is not None:
        report_dir.mkdir(parents=True, exist_ok=True)
    output_target = report_target(report_dir, app_scan.asset_name, args.output)
    run_scan(
        cnspec_scan_command(
            ["k8s"],
            policy_bundle=KUBERNETES_POLICY,
            policy=app_scan.policy,
            asset_name=app_scan.asset_name,
            output=args.output,
            output_target=output_target,
            discover=["clusters"],
        )
    )


def run_node(args: argparse.Namespace) -> None:
    report_dir = Path(args.report_dir).resolve() if args.report_dir else None
    if report_dir is not None:
        report_dir.mkdir(parents=True, exist_ok=True)
    output_target = report_target(report_dir, f"node-{args.host}", args.output)
    run_scan(
        cnspec_scan_command(
            ["ssh", f"pi@{args.host}"],
            policy_bundle=NODE_POLICY,
            asset_name=f"home-ops-node-{args.host}",
            output=args.output,
            output_target=output_target,
            sudo=True,
        )
    )


def run_image(args: argparse.Namespace) -> None:
    mount = Path(args.mount).resolve()
    if not mount.is_dir():
        raise SystemExit(f"Mounted image root does not exist: {mount}")

    report_dir = Path(args.report_dir).resolve() if args.report_dir else None
    if report_dir is not None:
        report_dir.mkdir(parents=True, exist_ok=True)
    output_target = report_target(report_dir, "image", args.output)
    run_scan(
        cnspec_scan_command(
            ["local"],
            policy_bundle=IMAGE_POLICY,
            props={"rootfs": str(mount)},
            asset_name=f"home-ops-image-{mount.name}",
            output=args.output,
            output_target=output_target,
        )
    )


def policy_text() -> str:
    return "\n".join(path.read_text(encoding="utf-8") for path in sorted(POLICY_DIR.glob("*.mql.yaml")))


def run_validate_parity(_: argparse.Namespace) -> None:
    bundle_text = policy_text()
    missing = [
        check
        for checks in MIGRATED_COMPLIANCE_CHECKS.values()
        for check in checks
        if check not in bundle_text
    ]
    if missing:
        missing_checks = "\n".join(f"- {check}" for check in missing)
        raise SystemExit(f"Mondoo policy parity is missing migrated checks:\n{missing_checks}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", choices=["compact", "full", "json", "junit", "summary"], default=None)
    parser.add_argument("--report-dir", default=None)
    subcommands = parser.add_subparsers(required=True)

    manifests = subcommands.add_parser("k8s-manifests", help="Scan rendered Flux Kubernetes manifests")
    manifests.add_argument("--path", default="./kubernetes")
    manifests.add_argument("--include-posture", action="store_true")
    manifests.set_defaults(func=run_k8s_manifests)

    live = subcommands.add_parser("k8s-live", help="Run report-only live Kubernetes posture scan")
    live.set_defaults(func=run_k8s_live)

    app = subcommands.add_parser("app", help="Run migrated application checks")
    app.add_argument("--app", required=True)
    app.set_defaults(func=run_app)

    node = subcommands.add_parser("node", help="Run migrated running-node checks")
    node.add_argument("--host", required=True)
    node.set_defaults(func=run_node)

    image = subcommands.add_parser("image", help="Run migrated mounted-image checks")
    image.add_argument("--mount", required=True)
    image.set_defaults(func=run_image)

    parity = subcommands.add_parser("validate-parity", help="Validate migrated check parity")
    parity.set_defaults(func=run_validate_parity)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
