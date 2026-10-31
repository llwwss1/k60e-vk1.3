#!/usr/bin/env python3
"""给 r54p1 的 libGLES_mali.so 打可选补丁。

用法: python3 patch_libgles.py <in.so> <out.so> [--vulkan14] [--get-configs]
依赖: pip install capstone

默认什么都不改（直接拷贝）。

--vulkan14
    把设备 VkPhysicalDeviceProperties.apiVersion 从 1.3.305 报成 1.4.0
    （改 2 处 `mov w?, #0x3131` → `mov w?, #0x4000`）。
    注意：r54p1 的 VkPhysicalDeviceVulkan14Features 全为 false，声明 1.4 与规范不自洽，
    只在需要骗过"只查版本号"的应用时使用。

--get-configs
    历史补丁：把 get_configs() 里 17 条「属性读不到就抛 bad_optional_access」的分支 nop 掉。
    **正常不再需要**：那个异常的真实原因是 SELinux 不允许应用/SF 读 ro.vendor.arm.*
    （vendor_default_prop），用 sepolicy 放行即可（见 docs/PITFALLS 第 11 条）。
    只有在无法修改 SELinux 策略时才需要这个补丁。
"""
import struct
import sys

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs

ABORT_SITE = 0xAB8C74   # get_configs 的失败分支（bad_optional_access）
EPILOGUE = 0xAB8BC4     # 同一个函数恢复寄存器的位置


def parse_segments(data):
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, = struct.unpack_from("<H", data, 0x36)
    e_phnum, = struct.unpack_from("<H", data, 0x38)
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, off)[0] != 1:      # PT_LOAD
            continue
        segs.append((
            struct.unpack_from("<Q", data, off + 0x10)[0],   # vaddr
            struct.unpack_from("<Q", data, off + 0x08)[0],   # offset
            struct.unpack_from("<Q", data, off + 0x20)[0],   # filesz
            struct.unpack_from("<I", data, off + 0x04)[0],   # flags
        ))
    return segs


def patch_get_configs(data, segs):
    """nop 掉 get_configs 里所有跳到 ABORT_SITE 的分支，并把 ABORT_SITE 改成跳尾声。"""
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    patched = []
    for vaddr, off, size, flags in segs:
        if not (flags & 1):
            continue
        for ins in md.disasm(bytes(data[off:off + size]), vaddr):
            if not ins.op_str:
                continue
            target = None
            if ins.mnemonic in ("b", "bl") and ins.op_str.startswith("#0x"):
                target = int(ins.op_str[1:], 16)
            elif ins.mnemonic.startswith(("tbz", "tbnz", "cbz", "cbnz")) \
                    and ", #0x" in ins.op_str:
                target = int(ins.op_str.split(", #")[-1], 16)
            if target == ABORT_SITE:
                p = off + (ins.address - vaddr)
                data[p:p + 4] = b"\x1f\x20\x03\xd5"          # nop
                patched.append(ins.address)

    for vaddr, off, size, _flags in segs:
        if vaddr <= ABORT_SITE < vaddr + size:
            p = off + (ABORT_SITE - vaddr)
            imm = (EPILOGUE - ABORT_SITE) // 4
            data[p:p + 4] = struct.pack("<I", 0x14000000 | (imm & 0x3FFFFFF))
    return patched


def patch_vulkan14(data, segs):
    """apiVersion 1.3.305 (0x403131) -> 1.4.0 (0x404000)。

    驱动写法：mov w<N>,#0x3131 … movk w<N>,#0x40,lsl#16 → str w<N>,[x0]
    """
    sites = []
    for vaddr, off, size, flags in segs:
        if not (flags & 1):
            continue
        for p in range(off, off + size - 4 * 8, 4):
            w1, = struct.unpack_from("<I", data, p)
            if (w1 & 0x7F800000) != 0x52800000:               # MOVZ (32-bit)
                continue
            if ((w1 >> 5) & 0xFFFF) != 0x3131:
                continue
            rd = w1 & 0x1F
            for k in range(1, 7):
                w2, = struct.unpack_from("<I", data, p + 4 * k)
                if (w2 & 0x7F800000) == 0x72800000 and ((w2 >> 5) & 0xFFFF) == 0x40 \
                        and ((w2 >> 21) & 3) == 1 and (w2 & 0x1F) == rd:
                    data[p:p + 4] = struct.pack("<I", 0x52800000 | (0x4000 << 5) | rd)
                    sites.append(vaddr + (p - off))
                    break
    return sites


def main(src, dst):
    data = bytearray(open(src, "rb").read())
    segs = parse_segments(data)
    args = sys.argv[3:]

    if "--get-configs" in args:
        sites = patch_get_configs(data, segs)
        print(f"get_configs branches nop'd: {len(sites)}")
        if not sites:
            print("错误：没找到补丁点，确认输入是 r54p1-11eac0 的 libGLES_mali.so",
                  file=sys.stderr)
            return 1

    if "--vulkan14" in args:
        sites = patch_vulkan14(data, segs)
        print(f"vulkan14 apiVersion sites: {len(sites)}  {[hex(x) for x in sites]}")

    open(dst, "wb").write(data)
    print(f"written: {dst} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(positional) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(positional[0], positional[1]))
