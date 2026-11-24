# 嵌套 KVM（沙箱内提供 KVM）

> **适用场景：** 沙箱中的工作负载需要自己创建硬件加速虚拟机——例如启动虚拟机的评测框架，或在内部创建 Micro-VM 的工具。如果只需要普通容器能力，默认部署已经足够。

嵌套 KVM 是**按节点显式开启的可选能力**：默认 guest 内核完全不变，只有安装了嵌套 KVM guest 内核的节点上的沙箱才会获得 `/dev/kvm`。建议使用独立节点池，把该能力与普通沙箱隔离。

::: warning 安全影响
向 guest 暴露 VMX/SVM 会扩大 hypervisor 的攻击面（L1 guest 本身成为 L0 hypervisor）。请仅在运行可信工作负载的专用节点上开启，并与通用沙箱池分离。
:::

## 能力组成

嵌套 KVM 需要四个条件，Cube 通过一个开关统一提供：

1. **宿主机嵌套虚拟化** —— 宿主内核的 `kvm_intel.nested=1`（Intel）或 `kvm-amd.nested=1`（AMD）。
2. **内置 KVM 的 guest 内核** —— `kvm` guest 内核变体（`vmlinux-kvm`）开启 `CONFIG_KVM`、`CONFIG_KVM_INTEL`、`CONFIG_KVM_AMD`。Cube guest 没有 `/lib/modules`，因此 KVM 必须内置而不能按模块加载。
3. **嵌套 cmdline 参数** —— CubeShim 启动 guest 时传入 `kvm-intel.nested=1` / `kvm-amd.nested=1`；在默认内核上是 no-op。
4. **快照中的嵌套 CPU 状态** —— pause、模板 commit 与 resume 通过 `KVM_GET_NESTED_STATE` / `KVM_SET_NESTED_STATE` 保存和恢复 L1 虚拟化状态。

沙箱不会自动获得 `/dev/kvm`：只有运行在 `kvm` 内核变体节点上的沙箱才会被透传。

## 前置条件

- **x86_64** 宿主机。aarch64 不支持（VMM 不暴露 `ID_AA64PFR0.EL2`）。
- `/proc/cpuinfo` 中有 VT-x（`vmx`）或 AMD-V（`svm`），且存在 `/dev/kvm`。
- **不能是 PVM 宿主机**。PVM 不支持嵌套虚拟化，`CUBE_KVM_ENABLE=1` 与 `CUBE_PVM_ENABLE=1` 互斥。
- 在宿主内核命令行开启嵌套虚拟化并重启：

  ```bash
  # Intel
  cat /sys/module/kvm_intel/parameters/nested   # 应输出 Y 或 1
  # AMD
  cat /sys/module/kvm_amd/parameters/nested
  ```

  若输出 `N`/`0`，在宿主内核命令行加入 `kvm-intel.nested=1`（Intel）或 `kvm-amd.nested=1`（AMD）后重启。安装脚本会检查该状态，未开启时拒绝继续。

## 在专用节点池开启

1. **预留节点池。** 在 CubeMaster 调度器 `instance_type_conf` 中配置该池的实例类型（例如 `cubebox-kvm`），并与节点 cluster label 映射。实例类型是硬调度分区：该池的沙箱不会调度到其他节点，其他池的沙箱也不会落到这些节点。

2. **在这些节点开启 guest 内核变体。**

   一键部署：

   ```bash
   CUBE_KVM_ENABLE=1 ./deploy/one-click/install.sh
   ```

   安装脚本会校验 x86_64、`/dev/kvm`、`vmx`/`svm` 与宿主嵌套参数，拒绝 PVM 宿主，并把 `vmlinux-kvm` 安装为 guest 内核（`vmlinux` 软链目标）。

   Kubernetes / Helm：

   ```yaml
   cubeNode:
     kvmGuestKernel:
       enabled: true
   ```

   `kvmGuestKernel.enabled` 与 `pvmGuestKernel.enabled` 不能同时为 true。

3. **构建（或获取）`kvm` 内核产物。** 内核发布会在标准 `vmlinux` 之外提供 `vmlinux-kvm-amd64`；`cube-kernel` 镜像将其携带为 `vmlinux-kvm`，并在 `version.json` 中标记。从源码构建：

   ```bash
   make guest-kernel KERNEL_SRC=/path/to/linux KERNEL_VARIANT=kvm
   ```

   该变体通过把 `configs/kernel-oc9.x86_64-kvm.fragment` 合并进标准 guest 配置生成，跟基础内核保持同步。

## 在沙箱内验证

在专用池中创建模板和沙箱，然后在 guest 中执行：

```bash
# 沙箱内
test -c /dev/kvm && echo "kvm device present"
grep -qwE 'vmx|svm' /proc/cpuinfo && echo "nested CPUID exposed"
cat /sys/module/kvm_intel/parameters/nested   # guest 使用 Intel 时
```

完整校验（打开设备并查询 KVM ABI）见 `tests/e2e/nested_kvm/`：

```bash
CUBE_TEMPLATE_ID=tpl-kvm-pool python3 tests/e2e/nested_kvm/nested_kvm_e2e.py
```

脚本会从指定模板创建沙箱（或用 `--image` 与 `--instance-type` 现场构建模板），在 guest 内运行探测，期望得到 `KVM_GET_API_VERSION=12`。请为 KVM 池使用专属模板——在 `cubebox-kvm` 池构建的模板会继承该实例类型，显式请求其他池的创建会被拒绝。

## 快照、暂停与恢复

嵌套 KVM 状态是快照的一部分：

- `pause` / `resume` —— 暂停的 guest 保留 VMXON 状态以及正在运行的 L2 虚拟机；resume 从 pause 快照恢复。
- 模板 commit 与 from-snapshot create —— 提交的内存镜像包含嵌套状态，新沙箱启动时 L1 虚拟化已初始化。
- 跨节点恢复仍要求 host facts（`cpuid_hash`、`host_kernel_release`）一致，且目标节点必须属于同一实例类型。Intel 与 AMD 的 VMX/SVM 嵌套状态互不兼容，同一池应保持单一厂商。

从其他池的快照创建 `cubebox-kvm` 沙箱（或反向）会被拒绝：实例类型是沙箱身份的一部分。

## 限制

- 仅支持 x86_64。
- 不能与 PVM 同时使用。
- 依赖宿主嵌套虚拟化；很多云厂商会禁用（部署前先检查 `/dev/kvm` 与模块 `nested` 参数）。
- 嵌套 KVM guest 内核仍内置 `CONFIG_KVM=y`，这些节点上的每个沙箱内核略大、启动慢几毫秒；使用默认内核的节点不受影响。
- 项目未对 L2 guest 性能做基准测试；该能力定位为功能可用，而非性能承诺。

## 相关文档

- [PVM 部署](./pvm-deploy.md) —— 无 `/dev/kvm` 宿主机的替代方案（与嵌套 KVM 互斥）。
- [组件多版本](./component-multiversion.md) —— guest 内核变体的存储、版本化与按需拉取。
