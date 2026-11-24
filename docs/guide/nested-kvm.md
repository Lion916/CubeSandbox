# Nested KVM (KVM inside a sandbox)

> **When to use this guide:** A workload running inside a Cube sandbox needs its
> own hardware-assisted virtual machine — for example an evaluation harness that
> boots a VM, or a tool that creates Micro-VMs itself. If you only need ordinary
> containers, the default deployment already gives you everything.

Nested KVM is **opt-in and per-node**: the standard guest kernel is unchanged,
and no sandbox gets `/dev/kvm` unless it runs on a node that was installed with
the nested-KVM guest kernel. A dedicated node pool keeps the capability away
from ordinary sandboxes.

::: warning Security surface
Exposing VMX/SVM to a guest enlarges the hypervisor attack surface (the L1
guest becomes an L0 hypervisor). Enable it only on dedicated nodes that run
trusted workloads, and keep the pool separate from general-purpose sandboxes.
:::

## What the feature consists of

Nested KVM needs four things, all of which the Cube stack provides as one switch:

1. **Host nested virtualization** — `kvm_intel.nested=1` (Intel) or
   `kvm-amd.nested=1` (AMD) on the *host* kernel.
2. **A guest kernel with KVM built in** — the `kvm` guest kernel variant
   (`vmlinux-kvm`) enables `CONFIG_KVM`, `CONFIG_KVM_INTEL` and
   `CONFIG_KVM_AMD`. Cube guests have no `/lib/modules`, so KVM must be built
   in rather than loaded as a module.
3. **Nested cmdline parameters** — CubeShim boots the guest with
   `kvm-intel.nested=1` / `kvm-amd.nested=1`; they are no-ops on the default
   kernel.
4. **Nested CPU state in snapshots** — pause, template commit and resume save
   and restore `KVM_GET_NESTED_STATE` / `KVM_SET_NESTED_STATE`, so a paused or
   committed KVM sandbox boots with its L1 virtualization state intact.

The sandbox does **not** receive `/dev/kvm` automatically. It is passed through
only when the sandbox runs on a node using the `kvm` kernel variant.

## Prerequisites

- **x86_64** host. Nested KVM is not available on aarch64 (the VMM does not
  expose `ID_AA64PFR0.EL2`).
- VT-x (`vmx`) or AMD-V (`svm`) in `/proc/cpuinfo`, and `/dev/kvm` present.
- **Not a PVM host.** PVM does not support nested virtualization;
  `CUBE_KVM_ENABLE=1` and `CUBE_PVM_ENABLE=1` are mutually exclusive.
- Host nested virtualization enabled on the kernel command line, followed by a
  reboot:

  ```bash
  # Intel
  cat /sys/module/kvm_intel/parameters/nested   # should print Y or 1
  # AMD
  cat /sys/module/kvm_amd/parameters/nested
  ```

  If it prints `N`/`0`, add `kvm-intel.nested=1` (Intel) or
  `kvm-amd.nested=1` (AMD) to the host kernel command line and reboot. The
  installer checks this and refuses to proceed otherwise.

## Enable on a dedicated node pool

1. **Reserve a node pool.** Configure the pool's instance type (for example
   `cubebox-kvm`) in CubeMaster's scheduler `instance_type_conf`, mapped from
   the node cluster label. Instance types are a hard scheduling partition:
   sandboxes created in that pool never land on other nodes, and sandboxes from
   other pools never land on these nodes.

2. **Enable the guest kernel variant on those nodes.**

   One-click deployment:

   ```bash
   CUBE_KVM_ENABLE=1 ./deploy/one-click/install.sh
   ```

   The installer validates x86_64, `/dev/kvm`, `vmx`/`svm` and host nested
   parameters, rejects PVM hosts, and installs `vmlinux-kvm` as the guest
   kernel (`vmlinux` symlink target).

   Kubernetes / Helm:

   ```yaml
   cubeNode:
     kvmGuestKernel:
       enabled: true
   ```

   `kvmGuestKernel.enabled` and `pvmGuestKernel.enabled` cannot both be true.

3. **Build (or obtain) the `kvm` kernel artifact.** Kernel releases publish
   `vmlinux-kvm-amd64` next to the standard `vmlinux`; the `cube-kernel` image
   carries it as `vmlinux-kvm` and advertises it in `version.json`. To build it
   from source:

   ```bash
   make guest-kernel KERNEL_SRC=/path/to/linux KERNEL_VARIANT=kvm
   ```

   The variant is produced by merging `configs/kernel-oc9.x86_64-kvm.fragment`
   into the standard guest config, so it stays in sync with the base kernel.

## Verify from inside a sandbox

Create a template and sandbox in the dedicated pool, then ask the guest:

```bash
# Inside the sandbox
test -c /dev/kvm && echo "kvm device present"
grep -qwE 'vmx|svm' /proc/cpuinfo && echo "nested CPUID exposed"
cat /sys/module/kvm_intel/parameters/nested   # when the guest uses Intel
```

A full check (open the device and query the KVM ABI) is in
`tests/e2e/nested_kvm/`:

```bash
CUBE_TEMPLATE_ID=tpl-kvm-pool python3 tests/e2e/nested_kvm/nested_kvm_e2e.py
```

The script creates a sandbox from the given template (or builds one with
`--image` and `--instance-type`), runs the probe in the guest, and expects
`KVM_GET_API_VERSION=12`. Dedicate a KVM template to the pool — a template built
in the `cubebox-kvm` pool inherits that instance type, and a create request that
explicitly asks for a different pool is rejected.

## Snapshot, pause and resume

Nested KVM state is part of the snapshot:

- `pause` / `resume` — the paused guest keeps its VMXON state and any running
  L2 VM; resume restores it from the pause snapshot.
- template commit and from-snapshot create — the committed memory image carries
  nested state, so new sandboxes start with L1 virtualization already
  initialized.
- Cross-node restore still requires matching host facts (`cpuid_hash` and
  `host_kernel_release`), and the target must belong to the same instance type.
  On Intel and AMD hosts VMX and SVM nested state are not interchangeable, so a
  pool should stay on a single vendor.

A `cubebox-kvm` sandbox created from a snapshot in the standard pool (or the
reverse) is refused: the pool is part of the sandbox identity.

## Limitations

- x86_64 only.
- Not available together with PVM.
- Requires host nested virtualization; many cloud providers block it (check
  `/dev/kvm` and the module `nested` parameter before deploying).
- The nested-KVM guest kernel keeps `CONFIG_KVM=y` built in, so every sandbox
  on those nodes carries a slightly larger kernel and boots a few milliseconds
  slower than on the standard kernel. Nodes using the default kernel are
  unaffected.
- Performance of L2 guests is not benchmarked by the project; treat the
  capability as functional enablement, not a performance guarantee.

## Related

- [PVM Deployment](./pvm-deploy.md) — the alternative for hosts without
  `/dev/kvm` (and the incompatible option for nested KVM).
- [Component Multi-Version](./component-multiversion.md) — how guest kernel
  variants are stored, versioned and fetched.
