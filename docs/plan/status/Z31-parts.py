#!/usr/bin/env python3
"""Z31 work list per part.

Runs X02-cov.py (class-named zone functions no document cites) and sorts every function into the Z31 part that
owns it. Run from the repo root:

    python3 -I docs/plan/status/Z31-parts.py          # functions / lines still uncited per part
    python3 -I docs/plan/status/Z31-parts.py 3        # list of part 3: addr lines name callers

Because X02-cov.py drops what a document already cites, the list shrinks as parts are written.
Part -> section of docs/pseudocode/zone/Z31-class-remainder.md: part n -> section n+1 (part 1 = §2 ... part 9 = §10).
'G' = gamble classes (Z32, not Z31).
"""
import collections
import re
import subprocess
import sys

NAMED = {"00473ea0", "00474250", "0056eae0", "0049b6c0", "004cd340", "00566930", "00562990", "00562bc0",
         "005651e0", "0043d3c0", "0043f520", "00563c70", "00559300", "004a8010"}

RULES = [
    ("G", r"^(CGambleDiceTaiSaiObject|CGambleObject|DiceTaiSai|SlotMachine::)"),
    ("2", r"^(InventoryLocking|CellStack|CharacterInventory|ItemBag|ItemBox|ItemInventory|ItemEquipment|ItemAttr"
          r"|ItemAccountStorage|ItemGuild|ItemRewardStorage|ItemSmallBag|ItemMall|ItemBelongAttribute"
          r"|ListEraser<InventoryLocking|ListEraser<CellStack"
          r"|ShineObjectClass::ShinePlayer::(<unnamed-type-sp_Item>|AccountStorage|ChargedInven)"
          r"|CChargedItem|ChargedItemEffectList)"),
    ("3", r"^ShineObjectClass::ShinePlayer"),
    ("4", r"^(ShineObjectClass::|ShineDynamicCast)"),
    ("5", r"^(AbnormalState|CharClass|BriefInfoExchanger|HitMeList|ListMaximumSearch<HitMeList|AttackRhythm"
          r"|RulesOfEngagement|EngSklAtt|EngNormAtt|Mob|ListEraser<Mob|CLooting|SlayerCollect|TargetAnalyser"
          r"|CharaterSkillList|UseEffect)"),
    ("6", r"^(Table$|ITableBase|IIDTableBase|LevelGap|BinaryData|SHND::)"),
    ("7", r"^(ItemMixData|AccUpGrade|BRAcc|MapDataBox|KQItemDataBox|EnchantSocket|ItemAction|ActionEffect"
          r"|ActionRange|OR|ListArray<ORRecord|ListEraser<OR|cStateItemDataBox|ItemOptionsData|ItemRandomOption"
          r"|ItemLotAnalyser|ListSearchSame<ItemLot|MakePrimaryKeyColumn|Column|OptionReader|SafePointer<OptionReader"
          r"|CDataReader|TokenArgument|OrderArgument|CSingleDataMap|BmpDataInfo|MapBlock|FieldOption|FieldMap"
          r"|FieldContainer|CBadNameFilterData|ListEraser<ItemActionObserve)"),
    ("8", r"^(NPC|MerchantCityData|CSellItemManager|ListEraser<SellItemInfo|BoothItem|BoothStoreManager|StreetBooth"
          r"|ItemOperateList|ListEraser<ItemOperateElement|ItemListMaker|CItemAuthorityBase|JunctionPointContainer"
          r"|Guild|ListEraser<Guild|ShineGuild|CGuildZone|ListEraser<CGuildZone|CParty|Raid|KingdomQuest"
          r"|ListEraser<KingdomQuest|PROTO_KQ|CLCReward|CWeaponTitle|CCharacterTitleZone|EventReserve"
          r"|ListEraser<EventReserve|EventSaveCheck|GMEventManager|CAnnounceSystem|BroadcastEventPopper"
          r"|CeaseFireSender|KickPlayer|MemoryQueue|BattleObjectGroup|ListEraser<BattleObject|TreasureChest"
          r"|RandomSlot|DuplicatedMenuControl|ListEraser<CardDeck|ListArray<CardDeck|Lua|ShineCharIDFinder"
          r"|ShineCharRegnumFinder|ShineMobIDFinder|PineEvent|ListEraser<PineEvent)"),
    ("9", r"."),   # sessions, packet containers, AxialList*, clusters, path finding, library classes
]


def load():
    out = subprocess.run([sys.executable, "-I", "docs/plan/status/X02-cov.py", "game", "zone", "5000"],
                         capture_output=True, text=True, check=True).stdout
    rows = []
    for line in out.splitlines():
        if not line.startswith("FUN_"):
            continue
        addr, n, name, rest = line.split(None, 3)
        cls = name.rsplit("::", 1)[0] if "::" in name else name
        part = "1" if addr[4:] in NAMED else next(k for k, r in RULES if re.match(r, cls))
        rows.append((part, addr, int(n), name, rest.strip()))
    return rows


def main():
    rows = load()
    if len(sys.argv) > 1:
        for part, addr, n, name, rest in rows:
            if part == sys.argv[1]:
                print(addr, n, name, rest)
        return
    tot = collections.defaultdict(lambda: [0, 0])
    for part, _, n, _, _ in rows:
        tot[part][0] += 1
        tot[part][1] += n
    for part in sorted(tot):
        print(f"part {part}: {tot[part][0]} functions, {tot[part][1]} lines")


if __name__ == "__main__":
    main()
