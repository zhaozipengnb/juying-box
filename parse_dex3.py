import struct

with open('/tmp/classes.dex', 'rb') as f:
    data = f.read()

string_ids_size = struct.unpack_from('<I', data, 0x38)[0]
string_ids_off = struct.unpack_from('<I', data, 0x3C)[0]

strings = []
for i in range(string_ids_size):
    off = struct.unpack_from('<I', data, string_ids_off + i * 4)[0]
    p = off
    while data[p] & 0x80:
        p += 1
    p += 1
    end = data.index(0, p)
    s = data[p:end].decode('utf-8', errors='replace')
    strings.append(s)

# Search for specific patterns
targets = ['360', 'gz', 'guazi', 'star2', 'sq0527', 'shuang', 'jianpian', 'jpys', 'djlh', 'czsapp', 'HaokanDJ', 'DJHub']

for target in targets:
    matches = []
    for i, s in enumerate(strings):
        if target.lower() in s.lower() and 'catvod' not in s and len(s) < 200:
            matches.append(f"  [{i}] {s[:120]}")
    if matches:
        print(f"\n=== {target} ===")
        for m in matches[:5]:
            print(m)

# Also search for all URLs containing 'api' or 'vod' or 'search'
print("\n=== API-like URLs ===")
seen = set()
for s in strings:
    if s.startswith('http') and ('api' in s.lower() or 'vod' in s.lower() or 'search' in s.lower() or 'app' in s.lower()):
        u = s.split('"')[0].split(',')[0].split(' ')[0]
        if u not in seen and '127.0.0.1' not in u and 'w3.org' not in u and 'kugou' not in u and 'kuwo' not in u:
            seen.add(u)
            print(f'  {u[:100]}')
