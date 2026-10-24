import sys, re, json, urllib.request

url = "https://700sjro44343.vicp.fun/eggp/0211/tv.json"
try:
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = resp.read().decode('utf-8', errors='replace')
except Exception as e:
    print(f"Fetch error: {e}")
    sys.exit(1)

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

out2 = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', out)
out2 = re.sub(r',(\s*[}\]])', r'\1', out2)

data = json.loads(out2)
sites = data.get('sites', [])
print(f"Total sites: {len(sites)}")

# Show all sites with their type and api
for idx, s in enumerate(sites):
    key = s.get('key', '')
    typ = s.get('type', -1)
    api = s.get('api', '')
    jar = s.get('jar', '')
    ext = s.get('ext', '')
    is_csp = api.startswith('csp_') if api else False
    is_http = api.startswith('http') if api else False
    print(f"  [{idx}] key={key} type={typ} api={api[:60]} csp={is_csp} http={is_http} jar={'Y' if jar else 'N'} ext={'Y' if ext else 'N'}")
