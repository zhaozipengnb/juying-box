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

# Print spider classes
print("=== Spider classes ===")
for s in strings:
    if 'catvod/spider/' in s and '$' not in s and len(s) < 60:
        cls = s.split('/')[-1].rstrip(';')
        print(f'  {cls}')

# Print all unique HTTP URLs (filtered)
print("\n=== API URLs ===")
seen = set()
for s in strings:
    if s.startswith('http') and '://' in s:
        u = s.split('"')[0].split(',')[0].split(' ')[0]
        if u not in seen and '127.0.0.1' not in u and 'w3.org' not in u and 'android.com' not in u and 'protobuf' not in u and 'xmlpull' not in u and 'kugou' not in u and 'kuwo' not in u and 'slf4j' not in u:
            seen.add(u)
            print(f'  {u[:100]}')
