"""Read DataTable row names straight from LORT's memory (read-only).

UDataTable: RowStruct at +0x28, RowMap (TMap<FName, uint8*>) at +0x30.
TMap element = { FName key (8), uint8* value (8), HashNextId (4), HashIndex (4) } = 0x18 bytes.
Usage: python rowdump.py <GUObjectArray addr> TableName [TableName ...]   -> rows.json
"""
import json, struct, sys
from memread import Proc, Names, pid_of

p = Proc(pid_of())
N = Names(p, int(open("names_addr.txt").read(), 16))
guo = int(sys.argv[1], 16)
want = set(sys.argv[2:])


def name_of(o):
    return N.get(p.u32(o + 0x18)) if o else None


objs = p.q(guo + 0x10)
num = p.i32(guo + 0x24)
tables = {}
for i in range(num):
    chunk = p.q(objs + (i // 65536) * 8)
    if not chunk:
        continue
    o = p.q(chunk + (i % 65536) * 0x18 + 8)
    if not o:
        continue
    n = name_of(o)
    if n in want:
        cls = name_of(p.q(o + 0x10))
        if cls and "DataTable" in cls:
            tables[n] = o

out = {}
for n, t in tables.items():
    rs = name_of(p.q(t + 0x28))
    data, cnt, mx = p.q(t + 0x30), p.i32(t + 0x38), p.i32(t + 0x3C)
    rows = []
    for i in range(mx):
        e = data + i * 0x18
        idx = p.u32(e)
        num_ = p.u32(e + 4)
        nm = N.get(idx) if idx is not None else None
        if nm and all(32 < ord(ch) < 127 for ch in nm) and len(nm) < 80:
            rows.append(nm if num_ == 0 else f"{nm}_{num_ - 1}")
    out[n] = {"struct": rs, "count": cnt, "rows": rows}
    print(f"{n}: struct={rs} count={cnt} read={len(rows)}")
json.dump(out, open("rows.json", "w"), indent=1)
