import sys, re, json, urllib.request

url = "https://700sjro44343.vicp.fun/eggp/0211/tv.json"
try:
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = resp.read().decode('utf-8', errors='replace')
except Exception as e:
    print(f"Fetch error: {e}")
    sys.exit(1)

print(f"Total length: {len(raw)} bytes")

# Simulate parseJson5ish
out = ''
in_str = False
n = len(raw)
i = 0
while i < n:
    c = raw[i]
    if in_str:
        if c == '\\' and i + 1 < n:
            out += c + raw[i+1]
            i += 2
            continue
        if c == '"':
            in_str = False
        out += c
        i += 1
        continue
    if c == '/' and i + 1 < n and raw[i+1] == '/':
        while i < n and raw[i] != '\n':
            i += 1
        continue
    if c == '"':
        in_str = True
    out += c
    i += 1

# Remove control chars (but keep \n \t for now to check)
out2 = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', out)
# Remove trailing commas
out2 = re.sub(r',(\s*[}\]])', r'\1', out2)

print(f"After preprocessing: {len(out2)} bytes")

# Try to parse
try:
    data = json.loads(out2)
    print("JSON parse OK!")
    # Count sites
    sites = data.get('sites', [])
    print(f"Number of sites: {len(sites)}")
    # Check for csp_ sources
    csp_sites = [s for s in sites if s.get('api', '').startswith('csp_')]
    print(f"csp_ sources: {len(csp_sites)}")
    for s in csp_sites:
        print(f"  - {s.get('key')}: api={s.get('api')}, type={s.get('type')}, jar={s.get('jar', 'N/A')[:50]}")
except json.JSONDecodeError as e:
    print(f"JSON error: {e.msg} at position {e.pos}")
    start = max(0, e.pos - 200)
    end = min(len(out2), e.pos + 200)
    print(f"Context around error:")
    print(repr(out2[start:end]))
    print(f"Character at pos: {repr(out2[e.pos])}")
