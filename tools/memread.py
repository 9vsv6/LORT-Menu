"""Read-only external memory inspector for LORT (single-player, no anti-cheat).

Used to work out UE struct layouts for UE4SS's MemberVariableLayout.ini.
Only uses OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION) + ReadProcessMemory.
"""
import ctypes, ctypes.wintypes as wt, struct, subprocess, re, sys

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.OpenProcess.restype = wt.HANDLE
k32.ReadProcessMemory.argtypes = [wt.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]


class Proc:
    def __init__(self, pid):
        self.h = k32.OpenProcess(0x0010 | 0x0400, False, pid)
        if not self.h:
            raise OSError(ctypes.get_last_error())

    def read(self, addr, n):
        buf = ctypes.create_string_buffer(n)
        got = ctypes.c_size_t()
        if not k32.ReadProcessMemory(self.h, ctypes.c_void_p(addr), buf, n, ctypes.byref(got)):
            return None
        return buf.raw[: got.value]

    def q(self, a):
        b = self.read(a, 8)
        return struct.unpack("<Q", b)[0] if b else None

    def i32(self, a):
        b = self.read(a, 4)
        return struct.unpack("<i", b)[0] if b else None

    def u32(self, a):
        b = self.read(a, 4)
        return struct.unpack("<I", b)[0] if b else None


class Names:
    """UE5 FNamePool decoder. blocks = address of the Blocks[] pointer array."""

    def __init__(self, p, blocks):
        self.p, self.blocks, self.cache = p, blocks, {}

    def get(self, idx):
        if idx in self.cache:
            return self.cache[idx]
        blk, off = idx >> 16, (idx & 0xFFFF) * 2
        base = self.p.q(self.blocks + blk * 8)
        if not base:
            return None
        hdr = self.p.read(base + off, 2)
        if not hdr:
            return None
        h = struct.unpack("<H", hdr)[0]
        wide, ln = h & 1, h >> 6
        if ln == 0 or ln > 1024:
            return None
        raw = self.p.read(base + off + 2, ln * (2 if wide else 1))
        s = raw.decode("utf-16le" if wide else "latin-1", "replace")
        self.cache[idx] = s
        return s


def pid_of(name="LortGame-Win64-Shipping.exe"):
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {name}", "/FO", "CSV", "/NH"], capture_output=True, text=True).stdout
    m = re.search(r'"[^"]+","(\d+)"', out)
    return int(m.group(1)) if m else None
