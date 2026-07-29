"""
Parse a SimulationCraft SpellDataDump class file into cast -> aura candidates.

Source: https://raw.githubusercontent.com/simulationcraft/simc/midnight/SpellDataDump/<class>.txt
Licence: SimulationCraft is GPL-3.0. The dumps are a mechanical extraction of Blizzard
client data. Generate offline, credit SimC, do not vendor simc source into the addon.

The cast->aura link is NOT a single field. Blizzard hardcodes most of these in script,
so SpellEffect.EffectTriggerSpell is empty for the majority of player abilities
(Shield Block's only effect is literally "Dummy"). Three recoverable signals, in
descending reliability:

  A. backref  - the AURA's description is exactly "$@spelldescNNNN", pointing at the cast
  B. descref  - the CAST's description interpolates "$NNNNd" / "$NNNNs1" (the aura's
                duration / scaling values), which names the aura
  C. trigger  - an effect carries an explicit "Trigger Spell: NNNN"

Usage:  python simc_import.py <path-to-class.txt> [--score <refined_rows.json>]
"""
import re, sys, json, collections

FIELD = re.compile(r'^(\w[\w %/()\'-]*?)\s*:\s?(.*)$')
NAME = re.compile(r'^Name\s+:\s+(.*?)\s+\(id=(\d+)\)')
EFFECT_HEAD = re.compile(r'^#(\d+)\s+\(id=(\d+)\)\s*:\s*(.*)$')


def parse(path):
    """Return {spellID: record}. Records are separated by blank lines."""
    spells, cur = {}, None
    for raw in open(path, encoding='utf-8', errors='replace'):
        line = raw.rstrip('\n')
        m = NAME.match(line)
        if m:
            cur = {'id': int(m.group(2)), 'name': m.group(1), 'effects': [],
                   'desc': '', 'duration': None, 'cooldown': None, 'charges': None,
                   'recharge': None, 'targets': [], 'cls': None, 'triggers': []}
            spells[cur['id']] = cur
            continue
        if cur is None:
            continue
        if not line.strip():
            cur = None
            continue

        em = EFFECT_HEAD.match(line.strip())
        if em:
            cur['effects'].append(em.group(3))
            continue

        # continuation lines inside an effect carry Target / Trigger Spell
        for t in re.findall(r'Target:\s*([^|]+?)(?:\s*\||$)', line):
            cur['targets'].append(t.strip())
        for t in re.findall(r'Trigger Spell:\s*(\d+)', line):
            cur['triggers'].append(int(t))

        fm = FIELD.match(line)
        if not fm:
            continue
        key, val = fm.group(1).strip(), fm.group(2).strip()
        if key == 'Class':
            cur['cls'] = val
        elif key == 'Description':
            cur['desc'] = val
        elif key == 'Duration':
            d = re.match(r'([\d.]+)\s*seconds?', val)
            if d: cur['duration'] = float(d.group(1))
        elif key == 'Cooldown':
            d = re.match(r'([\d.]+)\s*seconds?', val)
            if d: cur['cooldown'] = float(d.group(1))
        elif key == 'Charges':
            d = re.match(r'(\d+)\s*\(([\d.]+)\s*seconds? cooldown\)', val)
            if d:
                cur['charges'] = int(d.group(1)); cur['recharge'] = float(d.group(2))
            elif val.isdigit():
                cur['charges'] = int(val)
    return spells


def unit_of(rec):
    """Map SimC effect target enums onto (unit, hostility).

    Hostility matters: an aura on a friendly target is a BUFF, on an enemy a DEBUFF.
    Collapsing both to "target" mislabels every ally-targeted blessing as a debuff.
    Checked ally-first because strings like "Targeted Ally" contain "target" too.
    """
    t = ' '.join(rec['targets']).lower()
    if not t:
        return None, None
    if 'ally' in t or 'party' in t or 'raid' in t or 'friend' in t:
        return 'target', 'friendly'
    if 'enemy' in t or 'hostile' in t:
        return 'target', 'hostile'
    if 'self' in t:
        return 'player', 'friendly'
    if 'target' in t:
        return 'target', None      # ambiguous -- caller falls back to effect text
    return None, None


def is_aura(rec):
    return any('Apply Aura' in e for e in rec['effects'])


def link(spells):
    """Return {castID: [ (auraID, signal), ... ]}."""
    edges = collections.defaultdict(list)

    for sid, rec in spells.items():
        # D. SELF-AURA -- the single most common shape, and the one the three
        # cross-reference signals structurally cannot see: the ability applies an
        # aura that IS itself (Avatar, Shield Wall, Taunt, Rend, the stances...).
        # There is no pointer to follow; the evidence is that the cast spell's own
        # record carries Apply Aura effects. Ranked highest because when it holds
        # it is definitional, not inferred.
        #
        # A Duration is normally present too, but permanent auras (stances) have
        # none -- so Apply Aura alone is the test, with duration as a tie-breaker.
        if is_aura(rec):
            edges[sid].append((sid, 'self'))

        # A. backref: this record IS an aura whose description points at its caster
        for cast in re.findall(r'\$@spelldesc(\d+)', rec['desc']):
            cast = int(cast)
            if cast != sid:
                edges[cast].append((sid, 'backref'))

        # B. descref: this record is a CAST whose description interpolates an aura's values
        for aura in set(re.findall(r'\$(\d{3,7})[dsuo]', rec['desc'])):
            aura = int(aura)
            if aura != sid and aura in spells and is_aura(spells[aura]):
                edges[sid].append((aura, 'descref'))

        # C. explicit trigger
        for trig in rec['triggers']:
            if trig in spells and is_aura(spells[trig]):
                edges[sid].append((trig, 'trigger'))

    return edges


def best(edges, spells, cast):
    """Pick the strongest candidate for one cast spell."""
    cands = edges.get(cast, [])
    if not cands:
        return None
    rank = {'self': 0, 'backref': 1, 'descref': 2, 'trigger': 3}
    agg = collections.defaultdict(set)
    for aura, sig in cands:
        agg[aura].add(sig)
    scored = sorted(agg.items(),
                    key=lambda kv: (0 if 'self' in kv[1] else 1,
                                    -len(kv[1]),
                                    min(rank[s] for s in kv[1])))
    aura, sigs = scored[0]
    rec = spells.get(aura, {})
    unit, hostility = unit_of(rec) if rec else (None, None)
    # An aura whose effects only help (heal/absorb/speed) on an ambiguous target is
    # a buff; damage/control effects are debuffs.
    if hostility is None and rec:
        eff = ' '.join(rec.get('effects', [])).lower()
        if re.search(r'heal|absorb|increase|speed|immun', eff) and not re.search(r'damage|stun|root|snare|fear', eff):
            hostility = 'friendly'
        elif re.search(r'damage|stun|root|snare|fear|taunt|decrease', eff):
            hostility = 'hostile'
    return {'aura': aura, 'name': rec.get('name'), 'signals': sorted(sigs),
            'duration': rec.get('duration'), 'unit': unit, 'hostility': hostility,
            'alternatives': [a for a, _ in scored[1:]]}


def main():
    path = sys.argv[1]
    spells = parse(path)
    edges = link(spells)
    print(f"parsed {len(spells)} spells from {path}")
    print(f"cast spells with >=1 aura candidate: {len(edges)}")
    sig_counts = collections.Counter(s for v in edges.values() for _, s in v)
    print("signal breakdown:", dict(sig_counts))

    if '--score' in sys.argv:
        truth_path = sys.argv[sys.argv.index('--score') + 1]
        rows = json.load(open(truth_path, encoding='utf-8'))
        truth = {int(r['SpellID']): (int(r['BuffID'] or r['DebuffID']),
                                     r.get('AuraUnit'), r.get('AuraDuration'))
                 for r in rows if (r['BuffID'] or r['DebuffID'])}
        print(f"\n=== SCORING against {len(truth)} hand-verified auras ===")
        hit = miss = wrong = 0
        unit_ok = dur_ok = dur_cmp = 0
        details = []
        for cast, (want, wunit, wdur) in sorted(truth.items()):
            got = best(edges, spells, cast)
            if not got:
                miss += 1; details.append(('MISS ', cast, want, None, '')); continue
            if got['aura'] == want:
                hit += 1
                if got['unit'] and wunit:
                    unit_ok += got['unit'] == wunit
                if got['duration'] and wdur:
                    dur_cmp += 1
                    dur_ok += abs(got['duration'] - float(wdur)) < 0.6
                details.append(('OK   ', cast, want, got['aura'], '+'.join(got['signals'])))
            elif want in [a for a, _ in edges.get(cast, [])]:
                hit += 1
                details.append(('OK*  ', cast, want, got['aura'],
                                'correct was ranked lower'))
            else:
                wrong += 1
                details.append(('WRONG', cast, want, got['aura'], '+'.join(got['signals'])))
        for tag, cast, want, got, note in details:
            nm = spells.get(cast, {}).get('name', '?')
            print(f"  {tag} {nm:24} cast={cast:<8} want={want:<8} got={str(got):<8} {note}")
        tot = len(truth)
        print(f"\n  correct : {hit}/{tot}  ({100*hit/tot:.0f}%)")
        print(f"  wrong   : {wrong}/{tot}")
        print(f"  missing : {miss}/{tot}")
        if unit_ok:
            print(f"  unit correct on {unit_ok} of the hits")
        if dur_cmp:
            print(f"  duration correct on {dur_ok}/{dur_cmp} compared")


if __name__ == '__main__':
    main()
