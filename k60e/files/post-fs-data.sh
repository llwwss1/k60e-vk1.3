#!/system/bin/sh
# r54p1 GPU stack for K60E —— 按 qqcandy 配方：只换 kbase/mgm/prot_alloc，ged/gpueb 保持原厂
MODDIR=${0%/*}
case "$MODDIR" in
  /*) ;;
  *) MODDIR=$(cd "$MODDIR" && pwd) ;;
esac
LOG=/data/local/tmp/r54_boot.log
exec >>"$LOG" 2>&1
echo "===== $(date) v12 start ====="

V="$MODDIR/system/vendor"
HAL=u:object_r:same_process_hal_file:s0
chcon $HAL "$V/lib64/egl"/*.so "$V/lib64/egl/mt6895"/*.so 2>/dev/null
chcon $HAL "$V/lib64/libged.so" "$V/lib64/libgpud.so" "$V/lib64/libmtk_mali_user.so" "$V/lib64/libc++.so" 2>/dev/null
chcon $HAL "$V/lib64/android.hardware.graphics.common-V6-ndk.so" "$V/lib64/android.hardware.graphics.allocator-V2-ndk.so" "$V/lib64/android.hardware.common-V2-ndk.so" 2>/dev/null
chcon $HAL "$V/lib64/mt6895"/*.so 2>/dev/null
chcon $HAL "$V/firmware/mali_csffw.bin" 2>/dev/null
chcon u:object_r:vendor_file:s0 "$V/firmware/mali_csffw_reload.bin" 2>/dev/null
chcon u:object_r:vendor_configs_file:s0 "$V/etc/mali_platform.config" "$V/etc/permissions"/*.xml 2>/dev/null

EXPECT=39c473f885c112ff0a9bed430a1c3b092ec08d41
M=/vendor/lib/modules
for n in mali_kbase_mt6895 mali_mgm mali_prot_alloc; do rmmod "$n" 2>/dev/null; done
insmod "$MODDIR/ko/mali_prot_alloc_mt6895.ko" 2>/dev/null
insmod "$MODDIR/ko/mali_mgm_mt6895.ko" 2>/dev/null
insmod "$MODDIR/ko/mali_kbase_mt6895.ko" 2>/dev/null
i=0; while [ $i -lt 8 ]; do [ -e /dev/mali0 ] && break; sleep 1; i=$((i+1)); done
ID=$(od -An -tx1 /sys/module/mali_kbase_mt6895/notes/.note.gnu.build-id 2>/dev/null | tr -d ' \n')
echo "[INFO] kbase=$ID  waited=${i}s"
case "$ID" in
  *"$EXPECT"*) echo "[ OK ] r54 kbase 已加载" ;;
  *) echo "[WARN] kbase build-id 不是 39c473f8…，请检查" ;;
esac
echo "[INFO] modules: $(awk '{print $1}' /proc/modules | grep -E '^(ged|gpueb|mali)' | tr '\n' ' ')"
ls -l /dev/mali* 2>&1
echo "== 用户态检查 =="
ls -l /vendor/libc++.so /vendor/etc/mali_platform.config 2>&1
ls -l /vendor/lib64/libc++.so /vendor/firmware/mali_csffw_reload.bin 2>&1
echo "===== v12 done ====="