# 出问题怎么恢复

按「症状」查，从最轻的做起。**所有步骤都不需要刷分区**，除非你确实刷过 `vendor` / `vendor_dlkm`。

---

## A. 手机能开机、能进系统，但 GPU 不对 / 想回原厂

```bash
adb shell "su -c 'rm -rf /data/adb/modules/r54gpu'"
adb reboot
```

重启后就是原厂 r32，`/vendor`、`vendor_dlkm` 一个字节都没动过。

验证：

```bash
adb shell 'dumpsys SurfaceFlinger | grep -m1 "^GLES:"'
# 期望：… v1.r32p1-01eac0 …（原厂）
```

---

## B. 开机卡第一屏 / 反复重启（r54 生效了但没起来）

先确认是不是 Magisk 安全模式在作怪（见 PITFALLS 第 10 条）：

```bash
adb shell su -c 'tail -n 60 /cache/magisk.log | grep -i "safe mode"'
adb shell su -c 'ls /data/adb/modules/*/disable'
```

如果 `Safe mode triggered` 且一堆 `disable`：

```bash
adb shell su -c '/debug_ramdisk/magisk --sqlite "update settings set value=0 where key=\x27bootloop\x27"'
adb shell su -c 'rm -f /data/adb/modules/*/disable'
adb shell su -c 'rm -rf /data/adb/modules/r54gpu'      # 先回到原厂
adb reboot
```

> 安全模式会把**所有**模块静默 disable（包括和 GPU 无关的），
> 表现成「模块装了但没生效」，很容易误判。

---

## C. adb 也进不去、只能进 fastboot

用 fastbootd 刷回原厂（保留数据）：

```bash
adb reboot fastboot        # 或 音量下 + 电源
fastboot getvar is-userspace     # 必须 yes
```

如果显示 `no`（还在 bootloader），先转 fastbootd：

```bash
fastboot reboot fastboot
```

然后按你**动过什么**刷回对应的原厂镜像：

```bash
# 只动过模块 → 不需要刷；清 /data 里的模块目录即可（见 A/B）
# 刷过 vendor_dlkm：
fastboot flash vendor_dlkm stock/vendor_dlkm.img
# 刷过 vendor：
fastboot flash vendor stock/vendor.img
fastboot reboot
```

原厂镜像备份位置（本机）：
`backup/vendor_stock.img`（md5 `4959eda0ce425bcbc9c9804936c96806`）、
`vdlkm_stock.img`（md5 `47490832ECE796F6F934BD09404F4D96`）。

---

## D. 想彻底确认「现在是原厂还是 r54」

```bash
adb shell 'od -An -tx1 /sys/module/mali_kbase_mt6895/notes/.note.gnu.build-id' | tr -d ' \n'
# 原厂 r32：…1be8ca3376dd2ea1a812ca7816fc40679cfc71bc
# r54：    …ef95cf04a47c79cabb8bac8c51de534d7e2224e8

adb shell 'ls -l /vendor/lib64/egl/mt6895/libGLES_mali.so'
# 原厂：38,285,504 B
# r54： 51,726,104 B

adb shell 'ls /data/adb/modules/r54gpu'
# 存在 = 模块还在；删除后重启即回原厂
```
