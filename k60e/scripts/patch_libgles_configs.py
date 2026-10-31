#!/usr/bin/env python3
"""给 r54p1 的 libGLES_mali.so 打补丁。

用法: python3 patch_libgles_configs.py <in.so> <out.so> [--vulkan14]
依赖: pip install capstone

默认只修 get_configs() 的 bad_optional_access；
加 --vulkan14 会把设备 VkPhysicalDeviceProperties.apiVersion 从 1.3.305 报成 1.4.0。
"""
import struct
import sys

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs

ABORT_SITE = 0xAB8C74   # bl __libcpp_verbose_abort 的落点（get_configs 的失败分支）
EPILOGUE = 0xAB8BC4     # 同一个函数恢复寄存器的位置


def main(src, dst):
    data = bytearray(open(src, "rb").read())
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, = struct.unpack_from("<H", data, 0x36)
    e_phnum, = struct.unpack_from("<H", data, 0x38)

    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, off)[0] != 1:  # PT_LOAD
            continue
        segs.append((
            struct.unpack_from("<Q", data, off + 0x10)[0],  # vaddr
            struct.unpack_from("<Q", data, off + 0x08)[0],  # offset
            struct.unpack_from("<Q", data, off + 0x20)[0],  # filesz
            struct.unpack_from("<I", data, off + 0x04)[0],  # flags
        ))

    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    patched = []
    for vaddr, off, size, flags in segs:
        if not (flags & 1):          # 只看可执行段
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

    # 安全网：万一还是走到抛异常点，直接跳函数尾声
    for vaddr, off, size, _flags in segs:
        if vaddr <= ABORT_SITE < vaddr + size:
            p = off + (ABORT_SITE - vaddr)
            imm = (EPILOGUE - ABORT_SITE) // 4
            data[p:p + 4] = struct.pack("<I", 0x14000000 | (imm & 0x3FFFFFF))

    if not patched:
        print("错误：没找到补丁点，确认输入是 r54p1-11eac0 的 libGLES_mali.so",
              file=sys.stderr)
        return 1

    vulkan14 = "--vulkan14" in sys.argv
    sites = patch_vulkan14(data, segs) if vulkan14 else []

    open(dst, "wb").write(data)
    print(f"patched branches: {len(patched)}")
    for addr in patched:
        print(f"  0x{addr:x}")
    if vulkan14:
        print(f"vulkan 1.4 apiVersion sites: {len(sites)}")
        for addr in sites:
            print(f"  0x{addr:x}")
    print(f"written: {dst} ({len(data)} bytes)")
    return 0


def patch_vulkan14(data, segs):
    """把 VkPhysicalDeviceProperties.apiVersion 从 1.3.305 (0x403131) 报成 1.4.0 (0x404000)。

    驱动里的写法是：
        mov  w<N>, #0x3131
        ...
        movk w<N>, #0x40, lsl #16
        str  w<N>, [x0]           ; apiVersion 是 VkPhysicalDeviceProperties 的第一个字段
    把 movz 的立即数 0x3131 换成 0x4000 即可（高半 0x40 不变 -> 0x00404000）。
    """
    sites = []
    for vaddr, off, size, flags in segs:
        if not (flags & 1):
            continue
        for p in range(off, off + size - 4 * 8, 4):
            w1, = struct.unpack_from("<I", data, p)
            if (w1 & 0x7F800000) != 0x52800000:             # MOVZ (32-bit)
                continue
            if ((w1 >> 5) & 0xFFFF) != 0x3131:
                continue
            rd = w1 & 0x1F
            for k in range(1, 7):                            # 往后看 6 条
                w2, = struct.unpack_from("<I", data, p + 4 * k)
                if (w2 & 0x7F800000) == 0x72800000 and ((w2 >> 5) & 0xFFFF) == 0x40 \
                        and ((w2 >> 21) & 3) == 1 and (w2 & 0x1F) == rd:
                    data[p:p + 4] = struct.pack("<I", 0x52800000 | (0x4000 << 5) | rd)
                    sites.append(vaddr + (p - off))
                    break
    return sites


if __name__ == "__main__":
    positional = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(positional) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(positional[0], positional[1]))
