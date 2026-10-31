# K60E 移植操作步骤

假设：已解锁 bootloader、Magisk 已装、手上有 `blobs/` 里的 r54 文件。

## 0. 备份与急救（可选）

本移植**不刷任何分区**，理论上用不到；留着以防手滑。

```bash
adb reboot fastboot
fastboot getvar is-userspace          # 必须 yes（fastbootd）
fastboot flash vendor_dlkm stock/vendor_dlkm.img
fastboot reboot
```

## 1. 组装模块

```bash
pip install capstone                   # 打补丁用
bash scripts/build_module.sh           # 产出 r54_k60e.zip
```

脚本会从**仓库根** `blobs/vendor/` 取 10 个 r54 用户态库，并自动对
`libGLES_mali.so` 调用 `scripts/patch_libgles_configs.py`。

模块内容：

```
r54gpu/
├── module.prop
├── system.prop                       44 EGL + 12 gralloc + ro.hwui.use_vulkan
├── post-fs-data.sh                   内核模块热替换 + chcon + Vulkan 属性
├── ko/                               kbase / mgm / prot_alloc（r54）
└── system/vendor/
    ├── lib64/                        r54 库 + libc++ + 3 个 NDK 库 + 改过 atrace 的 libged
    ├── lib64/egl/                    MEOW 装载器 + 插件
    ├── lib64/egl/mt6895/             libGLES_mali.so（已打补丁）
    ├── lib64/mt6895/                 arm.mali.platform / graphics-V5 / 三个 sysprop 库
    ├── firmware/                     mali_csffw.bin + mali_csffw_reload.bin
    └── etc/                          mali_platform.config + Vulkan 两个 xml
```

## 2. 安装

```bash
adb push r54_k60e.zip /data/local/tmp/
adb push scripts/install_module.sh /data/local/tmp/
adb shell "su -c 'sh /data/local/tmp/install_module.sh /data/local/tmp/r54_k60e.zip'"
adb reboot
```

安装脚本做三件事：解压到 `/data/adb/modules/r54gpu`、`chmod`、**逐条 chcon**
（见 PITFALLS 第 1 条，标签不对会表现成「file not found」）。

## 3. 验证

```bash
adb shell 'dumpsys SurfaceFlinger | grep -m1 "^GLES:"'
# GLES: ARM, Mali-G610 MC6, OpenGL ES 3.2 v1.r54p1-11eac0…

adb shell 'od -An -tx1 /sys/module/mali_kbase_mt6895/notes/.note.gnu.build-id'
# …ef95cf04a47c79cabb8bac8c51de534d7e2224e8

adb shell 'getprop | grep -c arm.egl.configs'    # 44
adb shell 'getprop | grep -c arm.gralloc'        # 12
adb shell 'dmesg | grep -i "CSF firmware"'       # successfully initialized
adb shell 'dumpsys gfxinfo com.android.systemui | grep -m1 Pipeline'
# Pipeline=Skia (Vulkan)
```

## 4. 补丁复现

```bash
python3 scripts/patch_libgles_configs.py \
    blobs/vendor/lib64/egl/mt6895/libGLES_mali.so \
    /tmp/libGLES_mali_patched.so
# patched branches: 17
```

补丁点（r54p1-11eac0，build-id `445d1251…`）：

| 地址 | 原指令 | 改成 |
|---|---|---|
| `0xab8814` … `0xab895c`（17 处） | `tbz w?, #?, 0xab8c74` | `nop` |
| `0xab8c74` | `bl 0xa50fc0`（抛 bad_optional_access） | `b 0xab8bc4`（函数尾声） |

## 5. 开/关 Vulkan

模块 `system.prop` 里的 `ro.hwui.use_vulkan=true` + `post-fs-data.sh` 里的
`debug.hwui.renderer=skiavk` 决定 HWUI 是否走 Vulkan；删掉这两行就退回 GL。

SurfaceFlinger 自己的合成仍是 `skiaglthreaded`（`debug.renderengine.backend` 会被 init 覆盖，
要强改只能写进 `/vendor/build.prop`）。

## 6. 回滚

```bash
adb shell "su -c 'rm -rf /data/adb/modules/r54gpu'"
adb reboot
```
