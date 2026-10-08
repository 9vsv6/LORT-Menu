"""List loaded objects of given class names whose object name matches a filter (read-only).
Usage: python listobjs.py <GUObjectArray> <ClassName[,ClassName]> [name-substring ...]
"""
import sys
from memread import Proc, Names, pid_of

p = Proc(pid_of())
N = Names(p, int(open("names_addr.txt").read(), 16))
guo = int(sys.argv[1], 16)
classes = set(sys.argv[2].split(","))
subs = [x.lower() for x in sys.argv[3:]]


def name_of(o):
    return N.get(p.u32(o + 0x18)) if o else None


def path_of(o):
    parts = []
    while o:
        parts.append(name_of(o) or "?")
        o = p.q(o + 0x20)
    return "/".join(reversed(parts))


objs = p.q(guo + 0x10)
num = p.i32(guo + 0x24)
for i in range(num):
    chunk = p.q(objs + (i // 65536) * 8)
    if not chunk:
        continue
    o = p.q(chunk + (i % 65536) * 0x18 + 8)
    if not o:
        continue
    cn = name_of(p.q(o + 0x10))
    if cn in classes:
        n = name_of(o) or ""
        if not subs or any(s in n.lower() for s in subs):
            print(cn, path_of(o))
