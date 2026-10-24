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

# Target spiders
targets = ['Gz360', 'Ikanbot', 'Duboku', 'JianPian', 'TingShijie', 'ShuangXing', 'Guazi', 'Djlh', 'Djuu', 'Jpys', 'Czsapp']

for target in targets:
    print(f"\n=== {target} ===")
    for i, s in enumerate(strings):
        if target.lower() in s.lower() and 'catvod' not in s:
            # Print the string and nearby strings
            print(f"  [{i}] {s[:120]}")
