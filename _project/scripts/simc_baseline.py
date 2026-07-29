"""
Parse SimC's class_spells.inc / specialization_spells.inc -> baseline abilities
and spell-replacement (override) chains, for any class, with no character needed.

These two generated tables are what the cross-class /ccx sweep structurally cannot
reach: C_SpellBook is player-only, so a swept class has no baseline spellbook, and
C_Spell.GetOverrideSpell only resolves for the ACTIVE talent build, so renames are
invisible for classes you are not currently playing.

Row shape (both files):
    { classID, specID, spellID, replacesSpellID, "Name" [, flags] }

specID 0 means the spell is class-wide rather than spec-specific.
replacesSpellID != 0 is a genuine rename/upgrade edge:
    {1, 72, 190411, 1680,  "Whirlwind"}  Fury Whirlwind replaces baseline Whirlwind
    {2, 65, 415091, 53600, "Shield of the Righteous"}  Holy variant replaces baseline

Source: https://raw.githubusercontent.com/simulationcraft/simc/midnight/engine/dbc/generated/
"""
import re, os, sys, collections

CLASS_BY_ID = {
    1: 'WARRIOR', 2: 'PALADIN', 3: 'HUNTER', 4: 'ROGUE', 5: 'PRIEST',
    6: 'DEATHKNIGHT', 7: 'SHAMAN', 8: 'MAGE', 9: 'WARLOCK', 10: 'MONK',
    11: 'DRUID', 12: 'DEMONHUNTER', 13: 'EVOKER',
}

ROW = re.compile(
    r'\{\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*"([^"]*)"')

SIMC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'simc')


def load(class_token):
    """Return (baseline, replaces) for one class.

    baseline  {spellID: {'name':, 'specs': set(specID), 'classwide': bool}}
    replaces  {oldSpellID: newSpellID}   -- follow to resolve a rename chain
    """
    want = None
    for cid, tok in CLASS_BY_ID.items():
        if tok == class_token.upper():
            want = cid
            break
    if want is None:
        return {}, {}

    baseline, replaces = {}, {}
    for fname in ('class_spells.inc', 'specialization_spells.inc'):
        path = os.path.join(SIMC_DIR, fname)
        if not os.path.exists(path):
            continue
        for line in open(path, encoding='utf-8', errors='replace'):
            m = ROW.search(line)
            if not m:
                continue
            cid, spec, sid, repl, name = (int(m.group(1)), int(m.group(2)),
                                          int(m.group(3)), int(m.group(4)), m.group(5))
            if cid != want or sid == 0:
                continue
            e = baseline.setdefault(sid, {'name': name.strip(), 'specs': set(),
                                          'classwide': False})
            if spec == 0:
                e['classwide'] = True
            else:
                e['specs'].add(spec)
            if repl and repl != sid:
                # `sid` replaces `repl` -- store forward so old -> new
                replaces[repl] = sid
    return baseline, replaces


def resolve(replaces, spellID, _seen=None):
    """Follow a rename chain to its end (cycle-safe)."""
    seen = _seen or set()
    cur = spellID
    while cur in replaces and cur not in seen:
        seen.add(cur)
        cur = replaces[cur]
    return cur


if __name__ == '__main__':
    tok = (sys.argv[1] if len(sys.argv) > 1 else 'WARRIOR').upper()
    base, repl = load(tok)
    print(f"{tok}: {len(base)} baseline spells, {len(repl)} replacement edges")
    cw = sum(1 for v in base.values() if v['classwide'])
    print(f"  {cw} class-wide, {len(base)-cw} spec-specific")
    print("\n  sample baseline:")
    for sid, v in sorted(base.items())[:10]:
        scope = 'class' if v['classwide'] else 'spec ' + ','.join(map(str, sorted(v['specs'])))
        print(f"    {sid:<9} {v['name']:32} [{scope}]")
    if repl:
        print("\n  replacement chains:")
        for old, new in sorted(repl.items())[:12]:
            on = base.get(old, {}).get('name', '?')
            nn = base.get(new, {}).get('name', '?')
            print(f"    {old:<9} {on:26} -> {new:<9} {nn}")
