#!/usr/bin/env bash
# 组装 K60E 的 Magisk 模块：r54_k60e.zip
#
# 依赖：
#   - 仓库根的 blobs/vendor/（r54 的 10 个用户态库，来自 xaga 移植）
#   - 本目录 blobs/vendor_extra/（本机额外需要的 5 个库）
#   - 本目录 blobs/vendor_dlkm/（r54 的 3 个内核模块）
#   - 本目录 firmware/mali_csffw.bin
#   - python3 + capstone（给 libGLES_mali.so 打补丁）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"            # k60e/
REPO="$(cd "$ROOT/.." && pwd)"            # 仓库根
OUT="${1:-$ROOT/r54_k60e.zip}"
# 统一成绝对路径（后面要 cd 到临时目录里打包）
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# 找一个装了 capstone 的 python（Windows 上 python3/python 可能是两个不同的解释器）
PY=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import capstone" >/dev/null 2>&1; then
        PY="$cand"
        break
    fi
done
[ -n "$PY" ] || { echo "需要 python + capstone：pip install capstone" >&2; exit 1; }

M="$BUILD/r54gpu"
mkdir -p "$M/ko" \
         "$M/system/vendor/lib64/egl/mt6895" \
         "$M/system/vendor/lib64/mt6895" \
         "$M/system/vendor/firmware" \
         "$M/system/vendor/etc/permissions"

# --- 元信息 + 脚本 ---
cp "$ROOT/files/module.prop"     "$M/module.prop"
cp "$ROOT/files/system.prop"     "$M/system.prop"
cp "$ROOT/files/post-fs-data.sh" "$M/post-fs-data.sh"
chmod 755 "$M/post-fs-data.sh"

# --- 内核模块（只换 kbase / mgm / prot_alloc；ged、gpueb 保持原厂）---
cp "$ROOT/blobs/vendor_dlkm/"*.ko "$M/ko/"

# --- r54 用户态库（10 个，来自仓库根 blobs/vendor）---
for f in lib64/egl/libGLES_meow.so \
         lib64/egl/libMEOW_gift.so lib64/egl/libMEOW_trace.so lib64/egl/libMEOW_qt.so \
         lib64/egl/libMEOW_data.so lib64/egl/libMEOW_mfrc_ext.so \
         lib64/libgpud.so lib64/libmtk_mali_user.so \
         lib64/mt6895/arm.mali.platform-V2-ndk.so \
         lib64/mt6895/libarm_mali_config_sysprops.so \
         lib64/mt6895/libarm_gralloc_properties_sysprop.so \
         lib64/mt6895/libarm_egl_properties_sysprop.so \
         lib64/mt6895/arm.graphics-V5-ndk.so ; do
    src="$REPO/blobs/vendor/$f"
    [ -f "$src" ] || { echo "缺 $src" >&2; exit 1; }
    mkdir -p "$M/system/vendor/$(dirname "$f")"
    cp "$src" "$M/system/vendor/$f"
done

# --- libGLES_mali.so：默认原厂驱动，不打补丁 ---
# r54p1 抛 bad_optional_access 的真实原因是 SELinux 不让读 ro.vendor.arm.*（见 PITFALLS 11），
# 用 sepolicy.rule 放行即可，不再需要二进制补丁。
#   可选：VULKAN14=1      → 设备级 apiVersion 改报 1.4.0（与规范不自洽，慎用）
#         GET_CONFIGS=1   → 历史补丁：nop 掉 get_configs 的 17 条失败分支（无 sepolicy 时用）
PATCH_ARGS=""
[ "${VULKAN14:-0}" = "1" ] && PATCH_ARGS="$PATCH_ARGS --vulkan14"
[ "${GET_CONFIGS:-0}" = "1" ] && PATCH_ARGS="$PATCH_ARGS --get-configs"
if [ -n "$PATCH_ARGS" ]; then
    "$PY" "$ROOT/scripts/patch_libgles.py" \
            "$REPO/blobs/vendor/lib64/egl/mt6895/libGLES_mali.so" \
            "$M/system/vendor/lib64/egl/mt6895/libGLES_mali.so" $PATCH_ARGS
else
    cp "$REPO/blobs/vendor/lib64/egl/mt6895/libGLES_mali.so" \
       "$M/system/vendor/lib64/egl/mt6895/libGLES_mali.so"
fi

# --- 本机缺的 5 个（libc++、改过 atrace 的 libged、NDK 三件套）---
for f in libc++.so libged.so \
         android.hardware.graphics.common-V6-ndk.so \
         android.hardware.graphics.allocator-V2-ndk.so \
         android.hardware.common-V2-ndk.so ; do
    cp "$ROOT/blobs/vendor_extra/$f" "$M/system/vendor/lib64/$f"
done

# --- 固件两份 + 平台配置 + Vulkan 声明 ---
cp "$ROOT/firmware/mali_csffw.bin" "$M/system/vendor/firmware/mali_csffw.bin"
cp "$ROOT/firmware/mali_csffw.bin" "$M/system/vendor/firmware/mali_csffw_reload.bin"
cp "$ROOT/files/mali_platform.config" "$M/system/vendor/etc/mali_platform.config"
if [ "${VULKAN14:-0}" = "1" ]; then
    cp "$ROOT/files/android.hardware.vulkan.version-vk14.xml" \
       "$M/system/vendor/etc/permissions/android.hardware.vulkan.version.xml"
else
    cp "$ROOT/files/android.hardware.vulkan.version.xml" \
       "$M/system/vendor/etc/permissions/android.hardware.vulkan.version.xml"
fi
cp "$ROOT/files/android.software.vulkan.deqp.level.xml" \
   "$M/system/vendor/etc/permissions/android.software.vulkan.deqp.level.xml"

# --- SELinux 规则：让 app / surfaceflinger 能读 ro.vendor.arm.* ---
cp "$ROOT/files/sepolicy.rule" "$M/sepolicy.rule"

if command -v zip >/dev/null 2>&1; then
    ( cd "$BUILD" && zip -qr "$OUT" r54gpu )
else
    # Windows 上的 python 不认 MSYS 的 /c/... 路径，需要转一下
    OUT_PY="$OUT"
    if command -v cygpath >/dev/null 2>&1; then
        OUT_PY="$(cygpath -w "$OUT")"
    fi
    ( cd "$BUILD" && "$PY" - "$OUT_PY" <<'PY'
import os, sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _dirs, files in os.walk("r54gpu"):
        for name in files:
            p = os.path.join(root, name)
            z.write(p, p)
PY
    )
fi
echo "生成: $OUT ($(wc -c < "$OUT") 字节)"
