"""
Hand-verified overrides, per class. These beat every automated source.

VERIFIED[CLASS][castSpellID] = dict(aura=, kind='buff'|'debuff', unit='player'|'target',
                                    dur=seconds or None, perm=True for permanent auras,
                                    n='display name', note='caveat')

Permanent auras (stances) report expirationTime 0 -- countdown logic must not read
that as already expired, hence perm=True rather than dur=0.
"""

JUNK = {6603, 83958, 125439, 251463, 58984, 1231411, 84098}  # racials/toys/mounts/prof

WARRIOR_VERIFIED = {
    # --- self buffs -------------------------------------------------------
    190456: dict(aura=190456, kind='buff',   unit='player', dur=12,  n='Ignore Pain'),
    436358: dict(aura=436358, kind='buff',   unit='player', dur=2,   n='Demolish (channel DR)'),
    6572:   dict(aura=5302,   kind='buff',   unit='player', dur=6,   n='Revenge!'),
    386196: dict(aura=386196, kind='buff',   unit='player', dur=None, perm=True, n='Berserker Stance'),
    386164: dict(aura=386164, kind='buff',   unit='player', dur=None, perm=True, n='Battle Stance'),
    386208: dict(aura=386208, kind='buff',   unit='player', dur=None, perm=True, n='Defensive Stance'),
    384100: dict(aura=384100, kind='buff',   unit='player', dur=6,   n='Berserker Shout'),
    227847: dict(aura=227847, kind='buff',   unit='player', dur=6,   n='Bladestorm'),
    228920: dict(aura=228920, kind='buff',   unit='player', dur=12,  n='Ravager',
                 note='aura data sits on the cast spell; may be an internal aura with no visible buff'),
    871:    dict(aura=871,    kind='buff',   unit='player', dur=8,   n='Shield Wall'),
    18499:  dict(aura=18499,  kind='buff',   unit='player', dur=6,   n='Berserker Rage'),
    23920:  dict(aura=23920,  kind='buff',   unit='player', dur=5,   n='Spell Reflection'),
    118038: dict(aura=118038, kind='buff',   unit='player', dur=8,   n='Die by the Sword'),
    260708: dict(aura=260708, kind='buff',   unit='player', dur=30,  n='Sweeping Strikes'),
    107574: dict(aura=107574, kind='buff',   unit='player', dur=20,  n='Avatar'),
    97462:  dict(aura=97463,  kind='buff',   unit='player', dur=10,  n='Rallying Cry'),
    2565:   dict(aura=132404, kind='buff',   unit='player', dur=6,   n='Shield Block'),
    # --- target debuffs ---------------------------------------------------
    1715:   dict(aura=1715,   kind='debuff', unit='target', dur=15,  n='Hamstring (snare)'),
    46968:  dict(aura=132168, kind='debuff', unit='target', dur=2,   n='Shockwave (stun)'),
    385952: dict(aura=385954, kind='debuff', unit='target', dur=4,   n='Shield Charge (stun)',
                 note='also grants Shield Block 132404 to the player'),
    385059: dict(aura=385060, kind='debuff', unit='target', dur=4,   n="Odyn's Fury (bleed)"),
    12323:  dict(aura=12323,  kind='debuff', unit='target', dur=8,   n='Piercing Howl (snare)',
                 note='also triggers player speed buff 1244157 (4s) — that is what auto-capture caught'),
    376079: dict(aura=376080, kind='debuff', unit='target', dur=6,   n="Champion's Spear (tether+DoT)",
                 note='player-side companion aura 1271981 (6s) enables the leap-back'),
    1161:   dict(aura=1161,   kind='debuff', unit='target', dur=6,   n='Challenging Shout (taunt)',
                 note='taunt auras may not surface through UNIT_AURA at all'),
    386071: dict(aura=386071, kind='debuff', unit='target', dur=6,   n='Disrupting Shout (taunt)',
                 note='taunt auras may not surface through UNIT_AURA at all'),
    5246:   dict(aura=5246,   kind='debuff', unit='target', dur=8,   n='Intimidating Shout (AoE fear)',
                 note='UNCERTAIN: 316593 is the primary-target cower/root variant; the two may be reversed'),
    100:    dict(aura=105771, kind='debuff', unit='target', dur=1,   n='Charge (root)'),
    # Corrected 2026-07-19 from SimC client data. The inherited handoff table assumed
    # aura == cast for both; in fact neither cast spell carries ANY Apply Aura effect
    # (School Damage + Dummy only). The real auras backref via $@spelldesc.
    772:    dict(aura=388539, kind='debuff', unit='target', dur=15,  n='Rend (bleed)'),
    6343:   dict(aura=435203, kind='debuff', unit='target', dur=10,  n='Thunder Clap (slow)'),
    355:    dict(aura=355,    kind='debuff', unit='target', dur=6,   n='Taunt'),
    3411:   dict(aura=147833, kind='buff',   unit='target', dur=6,   n='Intervene (ally)'),
}

VERIFIED = {
    'WARRIOR': WARRIOR_VERIFIED,
}

UNRESOLVED = {
    'WARRIOR': {
        1244088: 'Interpose: cast spell has NO aura effects in the game data (only '
                 '"Charge to Object"). The 8s damage-share must be a triggered aura with '
                 'a separate ID, like Intervene 3411 -> 147833. Needs an in-game probe.',
    },
}
