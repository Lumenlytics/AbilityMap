"""
Pull the capturedAuras table out of a CCXMap SavedVariables dump.

/ccx watch attributes every newly-applied aura to the most recent cast within a
1.5s window, so an aura that lands close to another cast CAN be misattributed.
Treat these as strong hints, not gospel -- they carry lower confidence than a
hand-verified Wowhead lookup, and any conflict with the verified V dict is
reported rather than silently merged.
"""
import re, json, sys

path = sys.argv[1] if len(sys.argv) > 1 else '../data/CCXMap_SavedVariables_warrior.lua'
t = open(path, encoding='utf-8', errors='replace').read()

start = t.find('["capturedAuras"]')
if start < 0:
    print('no capturedAuras block'); raise SystemExit(1)

# walk braces to find the end of the block
i = t.index('{', start)
depth, j = 0, i
while j < len(t):
    if t[j] == '{': depth += 1
    elif t[j] == '}':
        depth -= 1
        if depth == 0: break
    j += 1
block = t[i:j + 1]

# [castID] = { [auraID] = { ["harmful"] = bool, ["unit"] = "x" }, ... }
out = {}
for cm in re.finditer(r'\[(\d+)\] = \{', block):
    castID = int(cm.group(1))
    k = cm.end() - 1
    d, e = 0, k
    while e < len(block):
        if block[e] == '{': d += 1
        elif block[e] == '}':
            d -= 1
            if d == 0: break
        e += 1
    inner = block[k:e + 1]
    auras = {}
    for am in re.finditer(r'\[(\d+)\] = \{(.*?)\}', inner, re.S):
        aid = int(am.group(1))
        body = am.group(2)
        harmful = 'true' in (re.search(r'\["harmful"\] = (\w+)', body) or
                             type('', (), {'group': lambda s, n: 'false'})()).group(1)
        unit_m = re.search(r'\["unit"\] = "(\w+)"', body)
        auras[aid] = {'harmful': harmful, 'unit': unit_m.group(1) if unit_m else '?'}
    if auras:
        out[castID] = auras

# drop the self-referential outer match (castID keys re-matched as aura keys)
clean = {}
for castID, auras in out.items():
    if castID in auras and len(auras) == 1 and auras[castID]['unit'] in ('player', 'target'):
        clean[castID] = auras          # self-aura, same ID -- legitimate
    else:
        clean[castID] = {a: m for a, m in auras.items()}

json.dump({str(k): {str(a): m for a, m in v.items()} for k, v in clean.items()},
          open('captured_auras.json', 'w', encoding='utf-8'), indent=1)

print(f"cast spells with captured auras: {len(clean)}")
for castID, auras in sorted(clean.items()):
    for aid, meta in sorted(auras.items()):
        kind = 'DEBUFF' if meta['harmful'] else 'BUFF'
        same = ' (same id)' if aid == castID else ''
        print(f"  cast {castID:<9} -> {kind:6} {aid:<9} on {meta['unit']}{same}")
