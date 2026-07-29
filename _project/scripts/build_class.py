"""
Generalized per-class builder: TSV (+ SimC aura seed) -> grouped, triaged rows.

    python build_class.py PALADIN

Reads   <class>_full.tsv          from extract.lua
        ../simc/<class>.txt       SimulationCraft SpellDataDump (aura seed)
        overlays.py               hand-verified overrides, per class
Writes  <class>_rows.json

Supersedes build_grouped.py + refine.py, which were Warrior-specific. Same rules:
  * nest modifier passives under the ability their description names
  * collapse same-name variants ONLY when they are demonstrably the same ability
  * triage actives into needs-verify / no-aura
  * classify passives by what they change (duration/cooldown/charges vs damage)
  * seed aura IDs from SimC, then let hand-verified overlays win
"""
import csv, re, json, sys, collections, difflib, os
import simc_import

CLASS = (sys.argv[1] if len(sys.argv) > 1 else 'WARRIOR').upper()
LOWER = CLASS.lower()

try:
    import overlays
    VERIFIED = overlays.VERIFIED.get(CLASS, {})
    JUNK = overlays.JUNK
except ImportError:
    VERIFIED, JUNK = {}, set()

# ------------------------------------------------------------------ load TSV
rich = {}
with open(f'{LOWER}_full.tsv', encoding='utf-8') as f:
    for r in csv.DictReader(f, delimiter='\t'):
        sid = int(r['spellID'])
        e = rich.setdefault(sid, {
            'spellID': sid, 'name': r['name'], 'specs': set(), 'sources': set(),
            'passive': r['passive'], 'charges': r['charges'], 'cd': r['cooldownMS'],
            'recharge': r.get('rechargeMS', ''), 'override': r.get('overrideSpellID', ''),
            'desc': r.get('description', '')})
        e['specs'].add(r['specName']); e['sources'].add(r['source'])
        if r['passive'] == 'false':
            e['passive'] = 'false'
        if r['charges']:
            e['charges'] = r['charges']
        if r['cooldownMS'] and r['cooldownMS'] not in ('', '0'):
            e['cd'] = r['cooldownMS']
        if r.get('overrideSpellID') and r['overrideSpellID'] not in ('', '0'):
            e['override'] = r['overrideSpellID']
        if r.get('rechargeMS') and r['rechargeMS'] not in ('', '0'):
            # recharge is haste/talent-modified; keep the largest (least-reduced)
            e['recharge'] = str(max(int(r['rechargeMS']), int(e.get('recharge') or 0)))
        if r.get('description'):
            e['desc'] = r['description']

for j in JUNK:
    rich.pop(j, None)

# ---------------------------------------------- baseline spells + rename chains
# The cross-class sweep cannot see these: C_SpellBook is player-only (so a swept
# class has no baseline spellbook) and C_Spell.GetOverrideSpell only resolves for
# the ACTIVE talent build. SimC's generated class/spec spell tables supply both
# for any class, with no character of that class required at any level.
import simc_baseline
base, replaces = simc_baseline.load(CLASS)
added_base = 0
for sid, b in base.items():
    if sid in rich:
        rich[sid]['sources'].add('baseline')
        continue
    rich[sid] = {
        'spellID': sid, 'name': b['name'], 'specs': set(), 'sources': {'baseline'},
        'passive': 'false', 'charges': '', 'cd': '', 'recharge': '',
        'override': '', 'desc': '',
    }
    added_base += 1
# forward-fill rename edges the client could not report
added_ovr = 0
for old, new in replaces.items():
    if old in rich and not rich[old].get('override'):
        rich[old]['override'] = str(new)
        added_ovr += 1
if base:
    print(f"SimC baseline: +{added_base} spells not in the talent trees, "
          f"{added_ovr} rename edges")

# ------------------------------------------------------- SimC aura seed
simc_path = f'../simc/{LOWER}.txt'
seed = {}
if os.path.exists(simc_path):
    spells = simc_import.parse(simc_path)
    edges = simc_import.link(spells)
    for sid in rich:
        b = simc_import.best(edges, spells, sid)
        if b:
            seed[sid] = b
    print(f"SimC seed: {len(seed)} of {len(rich)} spells matched from {simc_path}")

    # Backfill cooldown / charges / description / passive-flag for anything the
    # client could not supply -- chiefly the baseline spells added above, which
    # were never read in-game. Client data always wins where it exists.
    fill_cd = fill_desc = 0
    for sid, e in rich.items():
        rec = spells.get(sid)
        if not rec:
            continue
        if not e.get('cd') or e['cd'] in ('', '0'):
            if rec.get('recharge'):
                e['recharge'] = str(int(rec['recharge'] * 1000)); fill_cd += 1
            elif rec.get('cooldown'):
                e['cd'] = str(int(rec['cooldown'] * 1000)); fill_cd += 1
        if not e.get('charges') and rec.get('charges'):
            e['charges'] = str(rec['charges'])
        if not e.get('desc') and rec.get('desc'):
            # SimC descriptions carry $-substitution tokens; strip the worst of them
            d = re.sub(r'\$@?[a-z]*\d*[a-z]?\d*', '', rec['desc'])
            d = re.sub(r'\?[a-z]\d+\[([^\]]*)\]\[[^\]]*\]', r'\1', d)
            d = re.sub(r'[\[\]]', '', d)
            e['desc'] = re.sub(r'\s+', ' ', d).strip(); fill_desc += 1
    if fill_cd or fill_desc:
        print(f"SimC backfill: {fill_cd} cooldowns, {fill_desc} descriptions")
else:
    print(f"WARNING: no SimC dump at {simc_path} -- aura IDs will be empty")


def clean_desc(d):
    if not d:
        return ''
    d = re.sub(r'\|T[^|]*\|t', ' ', d)
    d = re.sub(r'\|c[0-9A-Fa-f]{8}', '', d).replace('|r', '')
    d = re.sub(r'\|H[^|]*\|h(\[?[^|]*?\]?)\|h', r'\1', d)
    d = re.sub(r'\|4([^:;|]*):([^;|]*);', r'\2', d)
    d = re.sub(r'\|n', ' ', d)
    return re.sub(r'\s+', ' ', d).strip()


def is_active(e):
    return e['passive'] == 'false'


actives = {sid: e for sid, e in rich.items() if is_active(e)}
active_names = {e['name'] for e in actives.values() if e['name']}

# ------------------------------------------- nest modifiers under their parent
def find_parent(e):
    if is_active(e):
        return None
    d = clean_desc(e['desc'])
    if not d:
        return None
    best_nm, best_pos = None, 10 ** 9
    for nm in active_names:
        if nm == e['name'] or not nm:
            continue
        m = re.search(r'\b' + re.escape(nm) + r'\b', d)
        if m and m.start() < best_pos:
            best_pos, best_nm = m.start(), nm
    return best_nm


parent_of = {}
for sid, e in rich.items():
    p = find_parent(e)
    if p:
        parent_of[sid] = p

# --------------------------------------------------------------- cooldown
def cd_seconds(e):
    rc = e.get('recharge', '')
    if rc and rc not in ('', '0'):
        return round(int(rc) / 1000, 1)
    cd = e.get('cd', '')
    if cd and cd not in ('', '0'):
        return round(int(cd) / 1000, 1)
    return ''


# ------------------------------------------------------------- build rows
def mk(e, kind, group):
    sid = e['spellID']
    v = VERIFIED.get(sid)
    s = seed.get(sid)
    row = dict(Class=CLASS.capitalize(), Group=group, Kind=kind, Name=e['name'],
               SpellID=sid, Specs=', '.join(sorted(x for x in e['specs'] if x)),
               Type='Active' if is_active(e) else 'Passive',
               Cooldown_s=cd_seconds(e), Charges=(e['charges'] or ''),
               BuffID='', DebuffID='', AuraUnit='', AuraDuration='',
               AuraPermanent=False, Effect='', Note='', AltIDs='',
               Override=e.get('override', ''),
               Desc=clean_desc(e['desc'])[:240], Confidence='Captured')
    if v:                                    # hand-verified wins outright
        key = 'BuffID' if v['kind'] == 'buff' else 'DebuffID'
        row[key] = v['aura']
        row['AuraUnit'] = v['unit']
        row['AuraDuration'] = v['dur'] if v['dur'] is not None else ''
        row['AuraPermanent'] = bool(v.get('perm'))
        row['Effect'] = ('Buff: ' if v['kind'] == 'buff' else 'Debuff: ') + v['n']
        row['Confidence'] = 'Verified'
        if v.get('note'):
            row['Note'] = v['note']
    elif s:                                  # SimC seed
        rec = s
        # hostility, not unit, decides buff vs debuff -- an ally-targeted blessing
        # lands on "target" but is unambiguously a buff.
        kind_g = 'debuff' if rec.get('hostility') == 'hostile' else 'buff'
        row['BuffID' if kind_g == 'buff' else 'DebuffID'] = rec['aura']
        row['AuraUnit'] = rec.get('unit') or ''
        row['AuraDuration'] = rec.get('duration') or ''
        row['Effect'] = ('Buff: ' if kind_g == 'buff' else 'Debuff: ') + (rec.get('name') or '')
        row['Confidence'] = 'SimC (' + '+'.join(rec['signals']) + ')'
    return row


rows, used = [], set()
children = collections.defaultdict(list)
for sid, par in parent_of.items():
    children[par].append(sid)

for e in sorted(actives.values(), key=lambda x: (x['name'] or '').lower()):
    rows.append(mk(e, 'Ability', e['name'])); used.add(e['spellID'])
    for csid in sorted(children.get(e['name'], []),
                       key=lambda s: (rich[s]['name'] or '').lower()):
        if csid in used:
            continue
        rows.append(mk(rich[csid], '  ↳ Modifier', e['name'])); used.add(csid)

for e in sorted((e for sid, e in rich.items() if sid not in used and not is_active(e)),
                key=lambda x: (x['name'] or '').lower()):
    rows.append(mk(e, 'Passive', 'General / Passive')); used.add(e['spellID'])

# ------------------------------------------------------------- collapse
def norm(d):
    return re.sub(r'\s+', ' ', re.sub(r'[\d,\.]+', '#', (d or '').lower())).strip()


def same_ability(a, b):
    return (a['Type'] == b['Type'] == 'Active' and a['Group'] == b['Group']
            and difflib.SequenceMatcher(None, norm(a['Desc']), norm(b['Desc'])).ratio() >= 0.55)


by_name = collections.defaultdict(list)
for r in rows:
    by_name[r['Name']].append(r)
dropped, collapsed_n = set(), 0
for name, group in by_name.items():
    if len(group) < 2:
        continue
    clusters = []
    for r in group:
        for c in clusters:
            if same_ability(c[0], r):
                c.append(r); break
        else:
            clusters.append([r])
    for c in clusters:
        if len(c) < 2:
            continue
        c.sort(key=lambda r: (-len(r['Specs'].split(',')), int(r['SpellID'])))
        primary, alts = c[0], c[1:]
        primary['Specs'] = ', '.join(sorted({s.strip() for r in c
                                             for s in r['Specs'].split(',') if s.strip()}))
        primary['AltIDs'] = ', '.join(str(r['SpellID']) for r in alts)
        primary['Desc'] = max((r['Desc'] for r in c), key=len)
        for r in alts:
            dropped.add(id(r))
        collapsed_n += 1
rows = [r for r in rows if id(r) not in dropped]

# --------------------------------------------------------------- triage
AURA_PATTERNS = [
    (r'\bfor \d[\d,\.]* sec', 'timed'), (r'\bfor \d[\d,\.]* min', 'timed'),
    (r'\bover \d[\d,\.]* sec', 'dot'), (r'\bwhile .{0,40}\bis active\b', 'while-active'),
    (r'\bstun(s|ning|ned)?\b', 'stun'), (r'\broot(s|ing|ed)?\b', 'root'),
    (r'\bsnare|slow(s|ing|ed)?\b', 'snare'), (r'\bsilenc(e|es|ing|ed)\b', 'silence'),
    (r'\bfear(s|ing|ed)?\b|\bdisorient', 'fear'), (r'\bincapacitat', 'incap'),
    (r'\btaunt(s|ing|ed)?\b', 'taunt'), (r'\bignoring \d|\babsorbing \d|\babsorbs \d', 'absorb'),
    (r'\bbleed(s|ing)?\b', 'bleed'), (r'\bincreas(e|es|ing)\b.*\bfor\b', 'timed buff'),
    (r'\breduc(e|es|ing)\b.*\bfor\b', 'timed debuff'), (r'\byour next\b', 'next-cast'),
    (r'\bstacks? up to\b', 'stacking'), (r'\buntil\b', 'until'), (r'\bimmun(e|ity)\b', 'immunity'),
]
NO_AURA_PATTERNS = [(r'\binterrupt(s|ing)?\b', 'interrupt'), (r'\bdispel(s|ling)?\b', 'dispel')]

AFFECTS = [
    ('duration', [r'\bduration\b', r'\blasts? \d', r'\bextend\w*\b', r'\b\d+ additional sec']),
    ('cooldown', [r'\bcooldown\b', r'\brecharge\w*\b', r'\breset\w*\b']),
    ('charges',  [r'\bcharge(s)?\b']),
    ('proc',     [r'\bchance to\b', r'\bwhen you\b', r'\beach time\b', r'\bstack']),
]

# A sub-2s cooldown on an ability with no charge count is almost always the
# inter-charge lockout rather than the real recharge (Shield Block reads 1s but
# recharges in 16s; Shield of the Righteous the same). The charge category lives
# in a table the SimC text dump does not carry, so flag it instead of shipping a
# number that looks authoritative and is wrong.
for r in rows:
    if r['Type'] == 'Active' and not r['Charges'] and r['Cooldown_s'] not in ('', None):
        try:
            if 0 < float(r['Cooldown_s']) <= 1.6 and not r['Note']:
                r['Note'] = ('cooldown %ss is likely an inter-charge lockout, not the real '
                             'recharge -- verify in-game' % r['Cooldown_s'])
                r['CooldownSuspect'] = True
        except (TypeError, ValueError):
            pass

for r in rows:
    if r['Type'] == 'Passive':
        d = (r['Desc'] or '').lower()
        tags = [n for n, ps in AFFECTS if any(re.search(p, d) for p in ps)] if d else []
        r['Affects'] = ','.join(tags) if tags else ('damage' if d else '')
        continue
    r['Affects'] = ''
    if r['BuffID'] or r['DebuffID']:
        r['Triage'] = 'VERIFIED' if r['Confidence'] == 'Verified' else 'SEEDED'
        continue
    d = (r['Desc'] or '').lower()
    if not d:
        r['Triage'] = 'UNCERTAIN'; continue
    if any(re.search(p, d) for p, _ in AURA_PATTERNS):
        r['Triage'] = 'NEEDS VERIFY'
    elif any(re.search(p, d) for p, _ in NO_AURA_PATTERNS) or re.search(r'\bdamage\b', d):
        r['Triage'] = 'NO AURA'; r['Effect'] = '— none —'
    else:
        r['Triage'] = 'UNCERTAIN'

out = f'{LOWER}_rows.json'
json.dump(rows, open(out, 'w', encoding='utf-8'), indent=1, ensure_ascii=False, default=str)

tri = collections.Counter(r.get('Triage') for r in rows if r['Type'] == 'Active')
print(f"\n{CLASS}: {len(rows)} rows  ({collapsed_n} collapsed)")
print(f"  abilities={sum(1 for r in rows if r['Kind']=='Ability')} "
      f"modifiers={sum(1 for r in rows if 'Modifier' in r['Kind'])} "
      f"passives={sum(1 for r in rows if r['Kind']=='Passive')}")
print("  active triage:", dict(tri))
timing = sum(1 for r in rows if r['Affects'] and
             any(t in r['Affects'] for t in ('duration', 'cooldown', 'charges')))
print(f"  timing-relevant passives: {timing}")
print(f"  -> {out}")
