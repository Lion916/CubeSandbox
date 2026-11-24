# Nested KVM E2E

Validates that a sandbox created in a dedicated KVM node pool receives a working
`/dev/kvm`: the guest must expose `vmx`/`svm`, `/dev/kvm` must be a character
device, and `KVM_GET_API_VERSION` must report the expected ABI version (12).

## Prerequisites

- A node installed with the nested-KVM guest kernel (`CUBE_KVM_ENABLE=1` for
  one-click, or `cubeNode.kvmGuestKernel.enabled=true` for Helm). See
  [Nested KVM](../../../docs/guide/nested-kvm.md).
- A CubeMaster instance type for that pool (default in this script:
  `cubebox-kvm`), configured in the scheduler's `instance_type_conf`.
- Host nested virtualization enabled (`kvm-intel.nested=1` or
  `kvm-amd.nested=1`) and the host exposing `/dev/kvm`.
- CubeAPI reachable from the machine that runs the script, and the repository
  Python SDK (`sdk/python`).

## Run

Against an existing template in the KVM pool:

```bash
CUBE_TEMPLATE_ID=tpl-kvm-pool python3 tests/e2e/nested_kvm/nested_kvm_e2e.py
```

Building a temporary template from an image:

```bash
CUBE_E2E_IMAGE=python:3.11-slim \
  python3 tests/e2e/nested_kvm/nested_kvm_e2e.py --instance-type cubebox-kvm
```

Options:

- `--template` / `CUBE_TEMPLATE_ID` — existing template (mutually exclusive with
  `--image`).
- `--image` / `CUBE_E2E_IMAGE` — build a temporary template in the KVM pool.
- `--instance-type` / `CUBE_INSTANCE_TYPE` — pool instance type (default
  `cubebox-kvm`).
- `--node` / `CUBE_E2E_NODE` — pin the template build and sandbox to one node.
- `--allow-skip` — exit 0 with `SKIP` when the sandbox has no `/dev/kvm`
  (useful on shared CI where no KVM pool exists).
- `--keep-resources` — keep the sandbox for inspection.

The script deliberately creates the sandbox **without** an explicit
`instance_type`, so it also exercises pool inheritance from the template: a
template built in the `cubebox-kvm` pool must place its sandboxes there.

Exit codes: `0` pass (or skip with `--allow-skip`), `1` failure, `2`
configuration error.
