#!/usr/bin/env python3
"""给 r54p1 的 libGLES_mali.so 打补丁：绕过 get_configs() 的 bad_optional_access。

用法: python3 patch_libgles_configs.py <in.so> <out.so>
依赖: pip install capstone
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

    open(dst, "wb").write(data)
    print(f"patched branches: {len(patched)}")
    for addr in patched:
        print(f"  0x{addr:x}")
    print(f"written: {dst} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
