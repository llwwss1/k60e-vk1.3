#!/system/bin/sh
# 设备端安装：sh install_module.sh /data/local/tmp/r54_k60e.zip
# 需要 root（Magisk / KernelSU 均可）
set -e

ZIP="${1:-/data/local/tmp/r54_k60e.zip}"
D=/data/adb/modules

[ -f "$ZIP" ] || { echo "找不到 $ZIP"; exit 1; }

TMP=$(mktemp -d /data/local/tmp/r54.XXXXXX)
unzip -q "$ZIP" -d "$TMP"

rm -rf "$D/r54gpu"
mkdir -p "$D"
mv "$TMP/r54gpu" "$D/r54gpu"
rm -rf "$TMP"

find "$D/r54gpu" -type d -exec chmod 0755 {} \;
find "$D/r54gpu" -type f -exec chmod 0644 {} \;
chmod 0755 "$D/r54gpu/post-fs-data.sh"

M="$D/r54gpu/system/vendor"
HAL=u:object_r:same_process_hal_file:s0
VF=u:object_r:vendor_file:s0
VC=u:object_r:vendor_configs_file:s0

# app 进程要经 sphal 命名空间加载这些库，必须是 same_process_hal_file
chcon $HAL "$M/lib64/egl"/*.so "$M/lib64/egl/mt6895"/*.so
chcon $HAL "$M/lib64/libged.so" "$M/lib64/libgpud.so" "$M/lib64/libmtk_mali_user.so"
chcon $HAL "$M/lib64/libc++.so"
chcon $HAL "$M/lib64/android.hardware.graphics.common-V6-ndk.so"
chcon $HAL "$M/lib64/android.hardware.graphics.allocator-V2-ndk.so"
chcon $HAL "$M/lib64/android.hardware.common-V2-ndk.so"
chcon $HAL "$M/lib64/mt6895"/*.so
chcon $HAL "$M/firmware/mali_csffw.bin"
# 其余
chcon $VF  "$M/firmware/mali_csffw_reload.bin"
chcon $VC  "$M/etc/mali_platform.config" "$M/etc/permissions"/*.xml

rm -f "$D/r54gpu/disable"
for f in "$D"/*/disable; do [ -e "$f" ] && rm -f "$f"; done

echo "安装完成: $D/r54gpu"
echo "重启后验证: adb shell 'dumpsys SurfaceFlinger | grep -m1 \"^GLES:\"'"
