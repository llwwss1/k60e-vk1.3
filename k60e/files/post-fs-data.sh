#!/system/bin/sh
# Mali r54p1 GPU stack for Redmi K60E (MT6896 / platform mt6895)
# 只换 kbase / mgm / prot_alloc 三个内核模块，ged.ko 与 gpueb.ko 保持原厂
MODDIR=${0%/*}
case "$MODDIR" in
  /*) ;;
  *) MODDIR=$(cd "$MODDIR" && pwd) ;;
esac
LOG=/data/local/tmp/r54_boot.log
exec >>"$LOG" 2>&1
echo "===== $(date) r54_k60e start ====="

V="$MODDIR/system/vendor"
HAL=u:object_r:same_process_hal_file:s0

# ---- SELinux：sphal 命名空间要加载的库必须是 same_process_hal_file ----
chcon $HAL "$V/lib64/egl"/*.so "$V/lib64/egl/mt6895"/*.so 2>/dev/null
chcon $HAL "$V/lib64/libged.so" "$V/lib64/libgpud.so" "$V/lib64/libmtk_mali_user.so" \
           "$V/lib64/libc++.so" 2>/dev/null
chcon $HAL "$V/lib64/android.hardware.graphics.common-V6-ndk.so" \
           "$V/lib64/android.hardware.graphics.allocator-V2-ndk.so" \
           "$V/lib64/android.hardware.common-V2-ndk.so" 2>/dev/null
chcon $HAL "$V/lib64/mt6895"/*.so "$V/firmware/mali_csffw.bin" 2>/dev/null
chcon u:object_r:vendor_file:s0 \
      "$V/firmware/mali_csffw_reload.bin" 2>/dev/null
chcon u:object_r:vendor_configs_file:s0 \
      "$V/etc/mali_platform.config" "$V/etc/permissions"/*.xml 2>/dev/null

# ---- 内核：原厂 r32 → r54（本机 modprobe 不加载 GPU 链，所以在这里手动换热）----
EXPECT=ef95cf04a47c79cabb8bac8c51de534d7e2224e8
for n in mali_kbase_mt6895 mali_mgm mali_prot_alloc; do rmmod "$n" 2>/dev/null; done
for n in mali_prot_alloc_mt6895 mali_mgm_mt6895 mali_kbase_mt6895; do
  [ -f "$MODDIR/ko/$n.ko" ] && insmod "$MODDIR/ko/$n.ko" 2>/dev/null
done

i=0
while [ $i -lt 8 ]; do [ -e /dev/mali0 ] && break; sleep 1; i=$((i+1)); done

ID=$(od -An -tx1 /sys/module/mali_kbase_mt6895/notes/.note.gnu.build-id 2>/dev/null | tr -d ' \n')
echo "[INFO] kbase build-id: $ID (waited ${i}s)"
case "$ID" in
  *"$EXPECT"*) echo "[ OK ] r54 kbase 已加载" ;;
  *)           echo "[WARN] kbase 不是 r54（期望 build-id 含 $EXPECT）" ;;
esac
echo "[INFO] modules: $(awk '{print $1}' /proc/modules | grep -E '^(ged|gpueb|mali)' | tr '\n' ' ')"
echo "[INFO] mali0: $(ls -l /dev/mali* 2>/dev/null | tr '\n' ' ')"

# ---- Vulkan：HWUI 走 Vulkan（SurfaceFlinger 合成仍留 GL）----
RP=""
for p in /debug_ramdisk/resetprop /data/adb/magisk/resetprop /system/bin/resetprop; do
  [ -x "$p" ] && { RP="$p"; break; }
done
[ -z "$RP" ] && command -v resetprop >/dev/null 2>&1 && RP=resetprop
if [ -n "$RP" ]; then
  "$RP" -n ro.hwui.use_vulkan true 2>/dev/null
  "$RP" -n debug.hwui.renderer skiavk 2>/dev/null
  echo "[INFO] vulkan: hwui_use_vulkan=$(getprop ro.hwui.use_vulkan) renderer=$(getprop debug.hwui.renderer)"
fi



# ---- SELinux：r54 驱动要读 ro.vendor.arm.* / vendor.mali.*，
#      本机策略默认禁止 app 域读 vendor_default_prop（微信相机会因此 invalid EGLDisplay）----
MP=/data/adb/magisk/magiskpolicy
if [ -x "$MP" ]; then
  "$MP" --live     "allow appdomain vendor_default_prop file { read open getattr map }"     "allow appdomain vendor_mtk_gpu_prop file { read open getattr map }" 2>/dev/null     && echo "[ OK ] sepolicy: appdomain 可读 vendor 属性"
fi

# ---- 逐条应用模块 system.prop（不依赖 Magisk 的 system.prop 机制）----
if [ -n "$RP" ] && [ -f "$MODDIR/system.prop" ]; then
  n=0
  while IFS='=' read -r k v; do
    case "$k" in ""|"#"*) continue ;; esac
    "$RP" -n "$k" "$v" 2>/dev/null && n=$((n+1))
  done < "$MODDIR/system.prop"
  echo "[INFO] system.prop applied: $n"
fi

echo "[INFO] firmware: $(ls -l /vendor/firmware/mali_csffw*.bin 2>/dev/null | wc -l) 份"
echo "===== r54_k60e done ====="
