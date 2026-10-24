import struct

with open('/tmp/classes_tan.dex', 'rb') as f:
    data = f.read()

ss = struct.unpack_from('<I', data, 0x38)[0]
so = struct.unpack_from('<I', data, 0x3C)[0]
strings = []
for i in range(ss):
    off = struct.unpack_from('<I', data, so + i * 4)[0]
    p = off
    while data[p] & 0x80: p += 1
    p += 1
    end = data.index(0, p)
    strings.append(data[p:end].decode('utf-8', errors='replace'))

# Search for JinPai and Dubk related strings
for target in ['JinPai', 'Dubk', 'jinpai', 'dubk', 'MacCms']:
    print(f"\n=== {target} ===")
    for i, s in enumerate(strings):
        if target.lower() in s.lower() and 'catvod' not in s and len(s) < 200:
            print(f"  [{i}] {s[:120]}")

# Search for all URLs
print("\n=== All URLs ===")
for s in strings:
    if 'http' in s and '://' in s and '127.0.0.1' not in s and 'w3.org' not in s:
        print(f"  {s[:120]}")
