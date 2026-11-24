#!/usr/bin/env python3
"""Nested-KVM E2E: verify /dev/kvm inside a sandbox on a KVM node pool."""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path


def add_repo_sdk_to_path() -> None:
    configured = os.environ.get("CUBE_REPO_ROOT")
    candidates = [Path(configured).expanduser().resolve()] if configured else []
    candidates.extend(Path(__file__).resolve().parents)
    for root in candidates:
        sdk = root / "sdk" / "python"
        if (sdk / "cubesandbox").is_dir():
            sys.path.insert(0, str(sdk))
            return
    raise RuntimeError("cannot locate repository sdk/python")


add_repo_sdk_to_path()

from cubesandbox import Config, Sandbox, Template  # noqa: E402

# Exit code used by the guest probe when the sandbox has no /dev/kvm, so the
# harness can tell "wrong node pool" apart from a genuine KVM failure.
GUEST_NO_KVM_EXIT = 77

# Runs inside the guest. KVM_GET_API_VERSION is _IO(KVMIO, 0x00) and returns
# the KVM ABI version (12).
GUEST_PROBE = """
set -eu
if [ ! -e /dev/kvm ]; then
  echo "no /dev/kvm in guest"
  exit 77
fi
if [ ! -c /dev/kvm ]; then
  echo "/dev/kvm is not a character device"
  exit 1
fi
flags="$(awk -F: '/^flags/{print $2; exit}' /proc/cpuinfo)"
case " $flags " in
  *" vmx "*) echo "guest virt flag: vmx" ;;
  *" svm "*) echo "guest virt flag: svm" ;;
  *) echo "guest CPUID exposes neither vmx nor svm"; exit 1 ;;
esac
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import fcntl, os, sys

KVM_GET_API_VERSION = 0xAE00
KVM_API_VERSION = 12
fd = os.open("/dev/kvm", os.O_RDWR | os.O_CLOEXEC)
try:
    version = fcntl.ioctl(fd, KVM_GET_API_VERSION)
finally:
    os.close(fd)
print(f"KVM_GET_API_VERSION={version}")
sys.exit(0 if version == KVM_API_VERSION else 1)
PY
else
  echo "python3 unavailable; validated only /dev/kvm and CPU flags"
fi
"""


def log(message: str) -> None:
    print(f"[nested-kvm-e2e] {message}", flush=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", default=os.environ.get("CUBE_TEMPLATE_ID"))
    parser.add_argument("--image", default=os.environ.get("CUBE_E2E_IMAGE"))
    parser.add_argument(
        "--instance-type",
        default=os.environ.get("CUBE_INSTANCE_TYPE", "cubebox-kvm"),
        help="instance type of the dedicated KVM node pool",
    )
    parser.add_argument("--node", default=os.environ.get("CUBE_E2E_NODE"))
    parser.add_argument("--template-build-timeout", type=float, default=900.0)
    parser.add_argument("--probe-timeout", type=float, default=60.0)
    parser.add_argument(
        "--allow-skip",
        action="store_true",
        help="treat a sandbox without /dev/kvm as SKIP instead of failure",
    )
    parser.add_argument("--keep-resources", action="store_true")
    args = parser.parse_args()
    if bool(args.template) == bool(args.image):
        parser.error("set exactly one of --template/CUBE_TEMPLATE_ID or --image/CUBE_E2E_IMAGE")
    return args


def build_template(args: argparse.Namespace, config: Config) -> str:
    name = f"nested-kvm-e2e-{int(time.time())}"
    log(f"building temporary template {name} in instance type {args.instance_type}")
    build = Template.build(
        name=name,
        image=args.image,
        instance_type=args.instance_type,
        cpu_count=500,
        memory_mb=2048,
        writable_layer_size="1G",
        network_type="tap",
        nodes=[args.node] if args.node else None,
        config=config,
    )
    if not build.template_id or not build.build_id:
        raise RuntimeError("template build response is missing template/build ID")
    template_id = str(build.template_id)
    build_id = str(build.build_id)
    deadline = time.monotonic() + args.template_build_timeout
    while time.monotonic() < deadline:
        current = Template.get_build_status(template_id, build_id, config=config)
        status = current.status.upper()
        if status in {"ERROR", "FAILED", "CANCELED", "CANCELLED"}:
            raise RuntimeError(
                f"template build failed: status={current.status} "
                f"phase={current.phase} error={current.error_message or current.message}"
            )
        if status in {"READY", "SUCCESS", "SUCCEEDED"}:
            return template_id
        time.sleep(3.0)
    raise RuntimeError(f"template build timed out after {args.template_build_timeout}s")


def probe_sandbox(sandbox: Sandbox, timeout: float) -> int:
    result = sandbox.commands.run(GUEST_PROBE, timeout=timeout)
    output = (result.stdout or "") + (result.stderr or "")
    for line in output.strip().splitlines():
        log(f"guest: {line}")
    return result.exit_code


def main() -> int:
    args = parse_args()
    config = Config()
    template_id = args.template or build_template(args, config)
    log(f"creating sandbox from template {template_id}")
    # No instance_type is sent: the sandbox must inherit the template's pool.
    sandbox = Sandbox.create(template=template_id, config=config)
    try:
        exit_code = probe_sandbox(sandbox, args.probe_timeout)
        if exit_code == GUEST_NO_KVM_EXIT:
            message = "sandbox has no /dev/kvm (template is not in the KVM node pool)"
            if args.allow_skip:
                log(f"SKIP: {message}")
                return 0
            log(f"FAIL: {message}")
            return 1
        if exit_code != 0:
            log(f"FAIL: guest probe exited {exit_code}")
            return 1
        log(f"PASS: sandbox {sandbox.sandbox_id} provides nested KVM")
        return 0
    finally:
        if not args.keep_resources:
            try:
                sandbox.kill()
            except Exception as exc:  # noqa: BLE001 - cleanup must not mask the result
                log(f"warning: sandbox cleanup failed: {exc}")


if __name__ == "__main__":
    sys.exit(main())
