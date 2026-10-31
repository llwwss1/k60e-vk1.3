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

# --- libGLES_mali.so：打 get_configs 的 bad_optional_access 补丁 ---
"$PY" "$ROOT/scripts/patch_libgles_configs.py" \
        "$REPO/blobs/vendor/lib64/egl/mt6895/libGLES_mali.so" \
        "$M/system/vendor/lib64/egl/mt6895/libGLES_mali.so"

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
cp "$ROOT/files/android.hardware.vulkan.version.xml" \
   "$M/system/vendor/etc/permissions/android.hardware.vulkan.version.xml"
cp "$ROOT/files/android.software.vulkan.deqp.level.xml" \
   "$M/system/vendor/etc/permissions/android.software.vulkan.deqp.level.xml"

if command -v zip >/dev/null 2>&1; then
    ( cd "$BUILD" && zip -qr "$OUT" r54gpu )
else
    ( cd "$BUILD" && "$PY" - <<'PY' "$OUT"
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
