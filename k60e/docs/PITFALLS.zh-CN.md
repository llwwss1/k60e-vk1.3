# K60E 移植踩过的 9 个坑

按遇到顺序。每条写清 **现象 / 判断 / 结论**。

---

## 1. 「file not found」其实是 SELinux 标签不对

**现象**

```
libMEOW: load_driver(/vendor/lib64/egl/libGLES_mali.so): dlopen failed:
  library "libged.so" not found: needed by …/libGLES_mali.so in namespace sphal
```

文件明明存在（`ls -la` 看得到），ELF 头也正常。

**判断**

bionic 的 linker 对任何 `open()` 失败（含 `EACCES`）都统一报 `library "xxx" not found`。
用非 root 的 shell 读一下就现形：

```
$ adb shell 'dd if=/vendor/lib64/libged.so bs=4 count=1'
dd: /vendor/lib64/libged.so: Permission denied      ← 标签问题
```

**结论**

app 进程要通过 `sphal` 命名空间加载的库必须打 `same_process_hal_file`：

```
chcon u:object_r:same_process_hal_file:s0 libged.so libgpud.so libmtk_mali_user.so \
      libc++.so android.hardware.*-ndk.so egl/*.so egl/mt6895/*.so mt6895/*.so \
      firmware/mali_csffw.bin
chcon u:object_r:vendor_file:s0        firmware/mali_csffw_reload.bin
chcon u:object_r:vendor_configs_file:s0 etc/mali_platform.config etc/permissions/*.xml
```

> 注意：本机原厂 `libged.so` / `libgpud.so` 标签就是 `vendor_file`，
> 但 overlay 后同一份文件被 app 进程通过 `sphal` 加载时会被拒。

---

## 2. tmpfs overlay 里 `libGLES_mali.so` 不能是符号链接

在 `/vendor/lib64/egl` 上盖 tmpfs 时，如果照抄原厂的
`libGLES_mali.so -> mt6895/libGLES_mali.so` 符号链接，MEOW 永远报

```
dlopen failed: library "/vendor/lib64/egl/libGLES_mali.so" not found
```

（没有任何附加原因）。改成**真文件**（bind mount 或直接放文件）后立刻变成正常的依赖报错。

**结论**：overlay 场景下用真文件，不要符号链接。

---

## 3. 本机 VNDK 31：`libcutils` 缺 `atrace_async_for_track_*_body`

**现象**

```
dlopen failed: cannot locate symbol "atrace_async_for_track_begin_body"
  referenced by "/vendor/libged.so"
```

**判断**

r54 的 `libged.so` 是用新 libcutils 编的，本机 `/apex/com.android.vndk.v31/lib64/libcutils.so`
没有这个符号。直接拿 `/system/lib64/libcutils.so` 覆盖 `/vendor/lib64/` 会连累 nvram、memtrack、
nfc、gatekeeper、相机（它们要 `android::base::Tokenize`/`Trim`，本机 libbase 没有）。

**结论**

用上游 `qqcandy/blobs/vendor_extra/libged.so`——它把符号名**等长改名**成
`atrace_begin_body` / `atrace_end_body`（`scripts/patch_libged_atrace.py`）。
**不要**替换 `libcutils.so` / `libbase.so`。

---

## 4. 缺的三个 NDK 库 + 专用 libc++

```
dlopen failed: library "android.hardware.common-V2-ndk.so" not found:
  needed by /vendor/lib64/egl/android.hardware.graphics.allocator-V2-ndk.so in namespace sphal
```

`libgpud.so` 还额外要 `android.hardware.graphics.common-V6-ndk.so`；r54 全系库要
`__libcpp_verbose_abort`（本机 vendor libc++ 没有）。

**结论**：把 `android.hardware.graphics.{common-V6,allocator-V2}-ndk.so`、
`android.hardware.common-V2-ndk.so`、`libc++.so` 一起放进 `/vendor/lib64/`。
`libc++.so` 用上游那份（1,154,016 B），`/system/lib64` 那份也能过符号解析但不是配套版本。

---

## 5. 本机 `modprobe` 不加载 GPU 链

**现象**：开机后 `/dev/mali0` 由原厂 r32 kbase 建立；`init.insmod.sh` 退出码 0、日志里
**一条 `Unknown symbol` 都没有**——它压根没尝试加载 GPU 模块。

**判断**

```
$ grep -nB8 insmod_sh /vendor/etc/init/hw/init.mtkgki.rc
service insmod_sh /vendor/bin/init.insmod.sh /vendor/etc/init.insmod.${ro.hardware}.cfg
```

`insmod_sh` 在 ~4.9 s 跑完就退出了，`vendor.all.modules.ready` 之后没有任何进程再去 insmod。

**结论**

不需要刷 `vendor_dlkm`：在 Magisk 的 `post-fs-data.sh`（~14 s，早于 SurfaceFlinger）
里 `rmmod` 原厂三个 → `insmod` r54 三个即可，`/dev/mali0` 会被重建。

---

## 6. `eglInitialize` 抛 `bad_optional_access`（根因是 SELinux，补丁只是权宜）

**现象**

```
Abort message: 'bad_optional_access was thrown in -fno-exceptions mode'
  #01 libc++.so  std::__1::__libcpp_verbose_abort
  #02 libGLES_mali.so
  #03 libGLES_mali.so
  #06 libGLES_mali.so (eglInitialize+1228)
  #07 libEGL.so (egl_display_t::initialize)
  #08 libsurfaceflinger.so (SkiaGLRenderEngine::create)
```

固件其实已经起来了（`CSF firmware was successfully initialized`），崩在 `get_configs()`：
它按顺序读 7 种格式的 `ro.vendor.arm.egl.configs.<fmt>.{hal_format,framebuffer_target,recordable}`，
读不到（bit0=0）或布尔解析失败（bit8=0）就 `tbz → 抛异常`。

本机这 44 条属性都在（`getprop | grep -c arm.egl.configs` = 44）、也没有 SELinux 拒绝，
但 `get_configs()` 仍判定失败（原因未完全查清；怀疑 system(Android 16) 的 libEGL 与
vendor(Android 12/VNDK31) 之间的差异）。

**结论**：打二进制补丁——把 17 条 `tbz … 0xab8c74` 全部 nop，并把 `0xab8c74` 的抛异常调用
改成跳函数尾声。补丁后驱动用默认值继续建 config，`eglInitialize` 成功。

```bash
python3 scripts/patch_libgles_configs.py \
    blobs/vendor/lib64/egl/mt6895/libGLES_mali.so \
    blobs/vendor/lib64/egl/mt6895/libGLES_mali.so
```

补丁只影响「拿不到配置就 abort」这一条路径，其余逻辑不动。

> **后续修正（重要）**：这个 abort 的真实根因是 **SELinux**——
> `ro.vendor.arm.*` 命中 `vendor_default_prop`，而 `surfaceflinger` / 应用域默认读不到，
> 驱动拿不到 EGL 配置属性才会抛异常。用 `sepolicy.rule` 放行后，**原厂 r54 驱动一个字节都不用改**
> 就能正常启动（见第 11 条）。`--get-configs` 补丁现在只在无法改 SELinux 策略时才需要
> （`GET_CONFIGS=1 bash scripts/build_module.sh`）。
副作用：`activeMode` 里
`supportedHdrTypes=INVALID`（10-bit/HDR 相关的 config 可能没注册），待进一步收窄。

---

## 7. 重打 vendor 镜像时目录标签最容易漏

第一次重打 vendor 刷进去卡第一屏，原因：文件标签补上了，**目录标签还是 `shell_data_file`**。

**判断**

- `chcon --reference=/vendor/xxx /data/.../xxx` 在 toybox 里**不支持**（`Unknown option`），
  而且会静默失败（`2>/dev/null` 时完全看不出来）。
- `cp -a` 也不保留 SELinux 标签，落到 `/data` 的文件会继承父目录的 `shell_data_file`。

**结论**

用 `ls -ZR /vendor` 生成映射，逐条 `chcon <ctx> <path>`；**目录也要**；符号链接要 `chcon -h`。
最后用 `ls -ZR <tree> | grep -c shell_data_file` 校验，必须是 0。

---

## 8. 固件要两份、而且必须成对

`vendor/firmware/` 下要同时有 `mali_csffw.bin` 和 `mali_csffw_reload.bin`（内容相同）。
少了 reload 那份，某些复位/重载路径会失败。

MTK 的 `mali_csffw.bin` 版本必须和 DDK 严格配对（r54p1 ↔ UK 1.38）：

```
libGLES_mali.so   r54p1 / UK 1.38
mali_kbase*.ko    r54p1
mali_csffw.bin    UK 1.38      ← md5 5594d779d10bb95dcd24f6f577a874da
```

用原厂那份会报 `Firmware header version 0.1 not understood`。

---

## 9. `ged.ko` / `gpueb.ko` 保持原厂

r54 的 `ged.ko` 依赖更新内核的 `MTKGPUQoS_*`、`sspm_reserve_mem_*`，
本机 5.10.257 没有，装上就 `Unknown symbol`；而原厂 `ged.ko` 导出的 5 个
`ged_dvfs_*` 恰好覆盖 r54 kbase 需要的全部符号。

**结论**：只换 `mali_kbase_mt6895` / `mali_mgm` / `mali_prot_alloc` 三个。
`gpueb.ko` 同理保持原厂（GPUEB 固件还带 RSA 签名，动不了）。
---

## 10. Magisk 的安全模式会静默关掉所有模块（排查时第一个看）

**现象**

移植失败时设备反复重启 → Magisk 的 bootloop 计数一路累加到 3~7 →
`/cache/magisk.log` 里出现 `* Safe mode triggered` →
Magisk 会**给所有** `/data/adb/modules/*` 写入 `disable` 文件（包括完全无关的模块）。

结果就是：模块"看起来装了但没生效"、`post-fs-data.sh` 根本没跑、
`/vendor` 下也看不到 overlay 的文件，很容易误判成移植本身的问题。

**判断**

```bash
adb shell su -c 'tail -n 50 /cache/magisk.log | grep -i "safe mode"'
adb shell su -c 'ls /data/adb/modules/*/disable'
adb shell su -c '/debug_ramdisk/magisk --sqlite "select * from settings where key=\x27bootloop\x27"'
```

**处理**

```bash
adb shell su -c '/debug_ramdisk/magisk --sqlite "update settings set value=0 where key=\x27bootloop\x27"'
adb shell su -c 'rm -f /data/adb/modules/*/disable'
adb reboot
```

`disable` 是空文件，删掉即恢复；计数清零后不会再因为历史失败次数触发安全模式。

**建议**

每次改机前先清零 bootloop 计数；设备起不来时**先看 `magisk.log` 有没有
`Safe mode triggered`**，再怀疑移植本身。

---

## 11. 应用读不到 `ro.vendor.arm.*` → 微信相机闪退

**现象**

装完模块后，微信「扫一扫」正常，但「相机」一进就整个应用退出；系统相机正常。
日志里没有 tombstone，只有：

```
E com.tencent.mm: [SurfaceTexture-0-XXX] checkAndUpdateEglState: invalid current EGLDisplay
I com.tencent.mm: System.exit called, status: 1
W libc: Access denied finding property "ro.vendor.arm.egl.configs.…"     ← 几百条
```

**判断**

`ro.vendor.arm.*` 在本机命中 `ro.vendor.` → `u:object_r:vendor_default_prop`，
而本机策略**不允许 app 域读 `vendor_default_prop`**。r54 驱动在应用进程里读不到
EGL config 属性，配置列表就是错的；`SurfaceTexture` 校验发现 EGLDisplay 状态不一致，
微信遂自行 `System.exit(1)`（不是崩溃，是主动退出，所以没有 tombstone）。

验证方法：

```bash
adb shell su -c 'getprop | grep -c ro.vendor.arm'                      # 56
adb shell 'getprop | grep -c ro.vendor.arm'                            # 0  ← shell 也读不到
adb shell su -c 'logcat -d | grep -c "Access denied finding property .ro.vendor.arm"'
```

**结论**

在模块里放行（`files/sepolicy.rule`，Magisk 会自动加载；`post-fs-data.sh` 里再补一次 live 版）：

```
allow appdomain        vendor_default_prop file { read open getattr map }
allow surfaceflinger   vendor_default_prop file { read open getattr map }
allow bootanim         vendor_default_prop file { read open getattr map }
allow gpu_device       vendor_default_prop file { read open getattr map }
allow { … }            vendor_mtk_gpu_prop file { read open getattr map }
```

`surfaceflinger` 也必须放行：它读不到时会在 `eglInitialize` 里抛 `bad_optional_access`
（PITFALLS 第 6 条），这就是之前要靠二进制补丁才能开机的原因。

放行后微信相机恢复正常。副作用：应用可以读到其它 `vendor_default_prop`（只读，风险很低）。

> 顺带：本机的属性机制会让 **shell 用户也读不到** 这些 `ro.vendor.arm.*`，
> 排查时一定要用 `su -c getprop`，否则会误判成"属性没生效"。
