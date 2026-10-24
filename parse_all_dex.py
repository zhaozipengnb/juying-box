import struct, os

def parse_dex(path):
    with open(path, 'rb') as f:
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
    return strings

for dex_path in ['/tmp/classes.dex', '/tmp/classes_tan.dex']:
    if not os.path.exists(dex_path):
        continue
    print(f"\n{'='*60}")
    print(f"DEX: {dex_path}")
    print(f"{'='*60}")
    strings = parse_dex(dex_path)
    
    print("\nSpider classes:")
    for s in strings:
        if 'catvod/spider/' in s and '$' not in s and len(s) < 60:
            cls = s.split('/')[-1].rstrip(';')
            print(f'  {cls}')
    
    print("\nAll HTTP URLs:")
    seen = set()
    for s in strings:
        if s.startswith('http') and '://' in s:
            u = s.split('"')[0].split(',')[0].split(' ')[0]
            if u not in seen and '127.0.0.1' not in u and 'w3.org' not in u and 'android' not in u and 'protobuf' not in u and 'xmlpull' not in u:
                seen.add(u)
                print(f'  {u[:120]}')
