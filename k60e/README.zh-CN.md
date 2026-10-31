# Mali r54p1 on Redmi K60E (rembrandt / MT6896)

把 MT6895/MT6896 的 Mali r54p1 GPU 栈搬到 **Redmi K60E（rembrandt，MT6896，平台仍报 mt6895）**。
和仓库根的 xaga 移植、`qqcandy/` 的 OPPO 移植是同一套 DDK（r54p1-11eac0），但落盘方式不同。

## 结果

```
GLES: ARM, Mali-G610 MC6, OpenGL ES 3.2 v1.r54p1-11eac0.3421…dae7314f…
sys.boot_completed=1   surfaceflinger=running
Display 0: 1440x3200 @ 120.00 Hz
dumpsys gfxinfo <pkg> → Pipeline=Skia (Vulkan)
```

## Vulkan

| 项 | 值 |
|---|---|
| `android.hardware.vulkan.version`（PackageManager 特性） | **4210688 = 1.4.0** |
| 实例 `apiVersion`（loader） | **4210688 = 1.4.0** |
| 物理设备 `apiVersion`（驱动自报） | **4210688 = 1.4.0**（补丁后；原厂自报 1.3.305） |
| 驱动 conformanceVersion | 1.4.0.1 |
| 对外扩展数 | 170 |
| `core14.features` | **21 项全部为 0** ← 真实差距 |
| `core14.properties` | 有值（`maxPushDescriptors=32`、`copySrcLayoutCount=4` …） |

r54p1 这套 DDK 已经带齐 Vulkan 1.4 提升为 core 的全部扩展
（`maintenance5/6/7`、`vertex_attribute_divisor`、`load_store_op_none`、`global_priority`、
`map_memory2`、`shader_subgroup_rotate`、`shader_float_controls2`、`host_image_copy`、
`dynamic_rendering_local_read`、`shader_replicated_composites` …），
1.4 的核心命令入口也基本齐全（`vkCmdBindDescriptorSets2`、`vkCmdPushConstants2`、
`vkMapMemory2`、`vkGetRenderingAreaGranularity`、`vkCmdSetRenderingAttachmentLocations`、
`vkGetDeviceImageSubresourceLayout`、`vkCopyMemoryToImageEXT` … 15 个里 13 个在，
缺的两个属可选扩展）。

本移植做了两层：
1. Android 侧声明（`vendor/etc/permissions/android.hardware.vulkan.version.xml`）→ 1.4.0；
2. 驱动侧 `scripts/patch_libgles_configs.py --vulkan14` 把 `VkPhysicalDeviceProperties.apiVersion`
   从 1.3.305 改成 1.4.0（改的是 `mov w?, #0x3131` → `mov w?, #0x4000` 两处，
   `0x00403131 → 0x00404000`）。

**真实差距（已用 Vulkan Hardware Capability Viewer 复核）**：`VkPhysicalDeviceVulkan14Features`
里的 21 项 1.4 核心特性**全部为 false**（`maintenance5/6`、`shaderFloatControls2`、
`shaderSubgroupRotate`、`shaderExpectAssume`、`vertexAttributeInstanceRateDivisor/ZeroDivisor`、
`indexTypeUint8`、`dynamicRenderingLocalRead`、`rectangularLines`、`bresenhamLines`、
`stippled*Lines`、`pushDescriptor`、`globalPriorityQuery`、`hostImageCopy`、
`pipelineRobustness`、`pipelineProtectedAccess` …）。

也就是说 **r54p1 是「1.4 扩展齐全 + 1.4 属性齐全，但 core 特性不报告」**：
特性只以 KHR/EXT 扩展形式存在，没有提升进 core 结构体。这是 DDK 内部实现，
改不了（除非换新 DDK）。

结论：
- 按**版本号**判断的应用（`apiVersion` / `android.hardware.vulkan.version`）→ 看到 1.4，能过；
- 按**特性结构体**判断的应用（`VkPhysicalDeviceVulkan14Features`）→ 看到全 false，会认为不支持 1.4。

因为“版本 1.4 + 特性全 false”在规范上是不自洽的（1.4 要求这些特性必须支持），
**默认不开启版本补丁**；确实需要骗过“只查版本号”的应用时才加 `--vulkan14`：

```bash
VULKAN14=1 bash scripts/build_module.sh    # 版本号也报 1.4
bash scripts/build_module.sh               # 默认：保持驱动原本的 1.3.305
```

`vendor/etc/permissions/android.hardware.vulkan.version.xml` 里的特性号同理：
默认 4206592（1.3.0），开 1.4 时改 4210688。



## 目标机

| 项 | 值 |
|---|---|
| 机型 | Redmi K60E / `rembrandt` |
| 指纹 | `Redmi/rembrandt/rembrandt:16/BP2A.250605.031.A3/OS3.0.309.0.WPSCNXM:user/release-keys` |
| 平台 | MT6896（`ro.boot.hardware=mt6895`，模块名/路径都是 mt6895） |
| 内核 | `5.10.257-android12-9-Kirara-26Y10R01-nemo`（vermagic 免校验，模块能跨版本加载） |
| vendor | Android 12 时代（VNDK **31**） |
| system | Android 16 |
| 原厂 DDK | r32p1（UK 1.18）→ 目标 r54p1（UK 1.38） |
| root | Magisk 30.7 |

## 和 qqcandy 的三点不同

1. **用 Magisk，不用 KernelSU**：`system/vendor/**` 走 Magisk 魔术挂载即可，文件对 `sphal`
   命名空间可见（前提是标签对，见 `docs/PITFALLS.zh-CN.md` 第 1 条）。
2. **内核模块在 post-fs-data 热替换**：本机 `init.insmod.sh` 的 `modprobe` 根本不加载 GPU 链
   （开机 dmesg 里连一条 `Unknown symbol` 都没有），所以不需要写 `vendor_dlkm` 分区，
   在 `post-fs-data.sh` 里 `rmmod` 原厂三个 → `insmod` r54 三个即可。
3. **必须给 `libGLES_mali.so` 打二进制补丁**：本机 `get_configs()` 会抛
   `bad_optional_access`（详见 PITFALLS 第 6 条），补丁把 17 条失败分支 nop 掉。

## 目录

```
k60e/
├── README.zh-CN.md
├── docs/
│   ├── PITFALLS.zh-CN.md      10 个坑：现象 / 判断 / 结论
│   ├── PORTING.zh-CN.md       从零复现的操作步骤
│   └── RECOVERY.zh-CN.md      出问题时的恢复步骤（含 Magisk 安全模式）
├── files/
│   ├── module.prop            Magisk 模块描述
│   ├── system.prop            44 条 EGL + 12 条 gralloc + Vulkan 开关
│   ├── post-fs-data.sh        内核模块热替换 + chcon + Vulkan 属性
│   ├── mali_platform.config   AGT 频率 + OSU 受保护堆名
│   └── *.xml                  Vulkan version / deqp level 声明
├── blobs/
│   ├── vendor_dlkm/           r54 的 3 个内核模块（kbase / mgm / prot_alloc）
│   └── vendor_extra/          本机缺的 5 个库（libc++、改过 atrace 的 libged、NDK 三件套）
├── firmware/mali_csffw.bin    UK 1.38 固件（装成 mali_csffw.bin + mali_csffw_reload.bin）
└── scripts/
    ├── build_module.sh        组装 Magisk 模块（10 个 r54 库取自仓库根 blobs/vendor）
    ├── install_module.sh      设备端安装（chmod + chcon）
    └── patch_libgles_configs.py  libGLES_mali.so 的 DDK 补丁（构建时自动调用）

> r54 的 10 个用户态库不重复放进本目录，`build_module.sh` 直接读仓库根的
> `blobs/vendor/`，并对 `libGLES_mali.so` 自动打补丁。
> 构建依赖：`python3` + `capstone`（`pip install capstone`）。
```

## 安装

```bash
# 1) 组装模块（在电脑上；需要 python3 + capstone）
pip install capstone
bash scripts/build_module.sh            # 产出 r54_k60e.zip

# 2) 推到手机并安装（Magisk root）
adb push r54_k60e.zip /data/local/tmp/
adb push scripts/install_module.sh /data/local/tmp/
adb shell "su -c 'sh /data/local/tmp/install_module.sh /data/local/tmp/r54_k60e.zip'"

# 3) 重启
adb reboot
```

## 验证

```bash
adb shell 'dumpsys SurfaceFlinger | grep -m1 "^GLES:"'        # v1.r54p1-11eac0
adb shell 'getprop | grep -c arm.egl.configs'                 # 44
adb shell 'getprop | grep -c arm.gralloc'                     # 12
adb shell 'od -An -tx1 /sys/module/mali_kbase_mt6895/notes/.note.gnu.build-id'   # …ef95cf04…
adb shell 'dumpsys gfxinfo com.android.systemui | grep -m1 Pipeline'             # Skia (Vulkan)
adb shell 'dmesg | grep -i "CSF firmware"'                    # successfully initialized
```

## 回滚

```bash
adb shell "su -c 'rm -rf /data/adb/modules/r54gpu'"
adb reboot
```

不刷任何分区，重启即回原厂 r32。

## 排查前先看这条

设备连续起不来几次后，Magisk 会把 bootloop 计数累加到 3~7，然后**安全模式把所有模块
静默 `disable`**（`/cache/magisk.log` 里有 `Safe mode triggered`），表现成「模块装了但没生效」，
极容易误判成移植失败。每次改机前先做：

```bash
adb shell su -c '/debug_ramdisk/magisk --sqlite "update settings set value=0 where key=\x27bootloop\x27"'
adb shell su -c 'rm -f /data/adb/modules/*/disable'
```

详见 `docs/PITFALLS.zh-CN.md` 第 10 条、`docs/RECOVERY.zh-CN.md` 的 B 节。

## 许可

`libGLES_mali.so` / `mali_kbase*.ko` / `mali_csffw.bin` / `libgpud.so` 等是 ARM / MTK 的专有二进制，
仅作移植对照与完整性记录，不适用本仓库的 GPL-2.0。分发前请自行确认授权条款。