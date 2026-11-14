# Zone server: quest script engine (Z15)

Source: `Files/Server/2016/w00_Zone00/5ZoneServer2.exe`. Code read in the PDB export `re-data/exports/zone-pdb`
(official names from the NA2016 `Zone.pdb`, same build *(pdb2016)*); view a function with
`python3 -I tools/protocol-re/clean.py re-data/exports/zone-pdb - <addr>`. Function, class, member, struct and enum names
below are the 2016 PDB names unless marked *(ours)*. Z15's names for the plain `zone` export:
`tools/protocol-re/names/zone/Z15.json`. Packet layouts: [`../../protocol/annotations/Z15.json`](../../protocol/annotations/Z15.json).

This item extends [`Z08-content.md`](Z08-content.md) §3 (quest packets and DB answers): Z08 lists the handlers, Z15
documents the engine behind them: the quest table, the script language and its interpreter, the diary rules, the reward
path and the other entry points. Facts already in Z08 §3 are linked, not repeated.

Evidence markers: plain = read in the 2016 code; *(pdb2016)* = name or type from the 2016 server PDB; *(pdb2017)* = 2017
client PDB only; *(data)* = read from the shipped 2016 `QuestData.shn` / `QuestParser.txt`; *(inferred)* = deduced.

---

## 1. Quest data: `QuestData.shn`

### 1.1 File and loader

The zone loads `../9Data/Shine/QuestData.shn` into the global `gQuestData` (`CQuestData`, `DAT_1328c0b0`, constructed
by the static initializer @ FUN_006994d0 with `m_pQuestDialog = NULL`) in the start stage `zs_start_sink`
(Z10 §7.1: `CQuestData::Read(path, 0)`, then `QuestParser.txt`, then the 3000-quest limit and the per-player diary
buffers). Despite the extension the file is **not** an SHN table (no SHN cipher, no column header); it has its own
format *(S01: "own format")*. The 2016 client ships the identical file (`ressystem/QuestData.shn`, byte-identical) and
reads it with the same library class in read-only mode (client FUN_006acdb0 → `CQuestData::Read(…, 1)`, together with
`QuestDialog.shn` for the texts); the client has no script parser (no `CQuestParserScript` in the 2017 client PDB).

```
file = QUEST_DATA_HEAD { u16 VersionNo (must be 6); u16 NumOfQuest }          # 4 bytes
       NumOfQuest × record
record = QUEST_DATA (0x2A8 bytes, §1.2)
         char ScriptStart[SizeOfScriptStart]     # NUL-terminated text, §2
         char ScriptDoing[SizeOfScriptDoing]
         char ScriptEnd[SizeOfScriptEnd]
         # file order Start, Doing, End; the three size fields are stored Start (+0x294), End (+0x296), Doing (+0x298)
```

The 2016 file *(data)*: version 6, 2306 quests (IDs 1 … 65200, all unique), 2 142 105 bytes, every record's
`nQuestDataSize` = 0x2A8 + the three script sizes, every script NUL-terminated inside its size. The three pointer
fields hold stale editor values in the file and are overwritten on load.

```pseudo
CQuestData::CQuestData(dialogReader):                                              @ FUN_006368a0
    m_pQuestDialog = dialogReader; m_pNULLSTR = &NULLSTR ("")
    m_ReadError = QDREV_FILE_NOT_FOUND (1); m_bReadonly = 0; m_pBF = m_pDataHead = m_ppQuestDataArray = NULL
    two empty hash maps (m_hashmap_QuestData, m_mhmap_QuestDataByMobID)

CQuestData::Read(path, readonly):  m_bReadonly = readonly                           @ FUN_00636f30
    return readonly ? ReadModeRead(path) : ReadModeEdit(path)          # the zone passes 0 → ReadModeEdit

CQuestData::ReadModeEdit(path):            # the zone's mode: one allocation per record and script   @ FUN_00636d20
    ClearBF()
    f = fopen(path, "rb"); none → m_ReadError = 1 FILE_NOT_FOUND; return 0
    m_pDataHead = new 4 bytes; fread(head, 4) fails → m_ReadError = 2 FILE_IS_NOT_QUEST_DATA → fail
    head.VersionNo != 6 → m_ReadError = 3 MISS_MATCH_VERSION → fail
    m_ppQuestDataArray = new QUEST_DATA*[NumOfQuest]           # not zeroed in this mode
    m_ReadError = 4 DATA_READ_FAILED                           # stays if a read below fails
    for i in 0 .. NumOfQuest-1:
        q = new QUEST_DATA (0x2A8, zeroed); m_ppQuestDataArray[i] = q
        fread(q, 0x2A8) fails → fail
        q.pScriptStart = new char[SizeOfScriptStart]; q.pScriptDoing = new char[SizeOfScriptDoing]
        q.pScriptEnd = new char[SizeOfScriptEnd]
        fread Start, then Doing, then End; any short read → fail
        q.nQuestDataSize = 0x2A8 + the three sizes
    fclose; m_ReadError = 0 NO_ERROR; QuestData_HashDataIn(); return 1
    fail: ClearBF(); fclose; return 0
    # a failure in the record loop leaves array cells after i unset; ClearBF then deletes them only when
    # m_bReadonly == 0 and the cell is non-NULL, so uninitialised cells may be freed (inferred; the zone exits
    # right after a failed load anyway, Z10 §7.1)

CQuestData::ReadModeRead(path):            # read-only mode (client): one buffer for the whole file   @ FUN_00636b90
    same header checks; m_pBF = new (filelength − 4); fread all of it (short → 4 DATA_READ_FAILED)
    m_ppQuestDataArray = new zeroed QUEST_DATA*[NumOfQuest]; walk the records in place:
        q.pScriptStart = q + 0x2AC; q.pScriptDoing = q + 0x2AC + SizeStart; q.pScriptEnd = q + 0x2AC + SizeStart + SizeDoing
        next record = q + 0x2A8 + SizeStart + SizeDoing + SizeEnd
    # the script pointers start at +0x2AC, 4 bytes after the record end (+0x2A8): every script loses its first
    # four characters and the End script runs 4 bytes into the next record (original bug) Z15-B6. The zone never
    # uses this mode; the client does but does not run scripts (inferred)
    fclose; m_ReadError = 0; QuestData_HashDataIn(); return 1

CQuestData::ClearBF():                                                             @ FUN_006367b0
    delete m_pBF
    if m_ppQuestDataArray: if !m_bReadonly: for each non-NULL record: delete its 3 scripts and the record
                           delete the array; m_ppQuestDataArray = NULL
    m_pDataHead ? delete m_pDataHead : clear m_hashmap_QuestData
    # m_pBF and m_pDataHead are deleted but not reset to NULL (a second ClearBF, e.g. Read twice, would
    # double-free; the zone reads once) (inferred)
CQuestData::~CQuestData(): ClearBF(); destroy both hash maps                        @ FUN_00636930

CQuestData::QuestData_HashDataIn():        # build the two indexes                  @ FUN_00636990
    clear both maps
    for each record q (array order):
        m_hashmap_QuestData.insert(q.ID → q)               # hash_map: a duplicate ID would keep the first (inferred)
        m_mhmap_QuestDataByMobID.insert(startNpc → q)      # startNpc = Start.NPCID if Start.bNPC else 0xFFFF
                                                           #   (looked up again through m_hashmap_QuestData by q.ID)
        for i in 0..4: e = End.NPCMobList[i]
            if e.bNPCMob and e.NPCMobAction ∈ {0 QNMA_REWARD_OBJECT, 3 QNMA_CONVERSATION}:
                m_mhmap_QuestDataByMobID.insert(e.NPCMobID → q)
    # despite its name the multimap indexes quests by the NPCs that start, end or talk in them (kill targets,
    # action 1, are not indexed); its users are the NPC status functions (§4)
```

| Accessor | Behaviour |
|---|---|
| `GetQuestData(id)` @ FUN_00635ff0 (Z08: `QuestData_Find`) | `m_hashmap_QuestData[id]` or NULL |
| `GetQuestDataByIndex(i)` @ FUN_00635ad0 | `m_ppQuestDataArray[i]` for `i < NumOfQuest`, else NULL |
| `GetStartNPC(id)` @ FUN_00636030 | `Start.NPCID` when the quest exists and `Start.bNPC`, else 0xFFFF |
| `GetQuestScriptStart/Doing/End(id)` @ FUN_00636080 / FUN_006360d0 / FUN_00636120 | the script pointer; unknown quest → `m_pNULLSTR` (""), which `ParserStart` refuses (§2.4) |

### 1.2 `QUEST_DATA` row layout *(pdb2016; offsets confirmed by the 2016 loader and by Z08's reads)*

| Off | Field | Meaning / values |
|---|---|---|
| +0x000 | u32 `nQuestDataSize` | 0x2A8 + script sizes (recomputed on load) |
| +0x004 | u16 `ID` | quest id (the diary and every packet use it) |
| +0x008 | u32 `NameID`, +0x00C u32 `BrifingID` | text ids (`QuestDialog.shn`, client) |
| +0x010 | u8 `Region` | quest-list region (client grouping) |
| +0x011 | u8 `Type` | `QUEST_TYPE`: 0 NORMAL, 1 STORY, 2 CLASS, 3 EVENT, 4 INSTANCE_DUNGEON, 5 NORMAL_PARTY, 6 EPIC, 7 EPIC_PARTY, 8 RAID, 9 CHAO_QUEST, 10 DAILY_QUEST |
| +0x012 | u8 `Repeatable` | Z08 §3.2 (give up of a repeatable quest) |
| +0x013 | u8 `nDailyQuestType` | `DAILY_QUEST_TYPE`: 0 NONE, 1 DAY, 2 WEEK, 3 MONTH, 4 YEAR (reset period, §4) |
| +0x018 | `QUEST_START_CONDITION Start` (0x40) | below |
| +0x058 | `QUEST_END_CONDITION End` (0x68) | below |
| +0x0C0 | u8 `NumOfAction` | used entries of `Action` |
| +0x0C4 | `QUEST_ACTION Action[10]` (0x20 each) | `{u8 IfType; u32 IfTarget; u8 ThenType; u32 ThenTarget, ThenPersent, ThenCountMin, ThenCountMax; u8 TargetGroup}`; IfType 1 MOB_KILL, 2 GATHER, 3 TOUCH_OBJECT, 4 AREAINFO; ThenType 1 DROP_ITEM, 2 DO_SCENARIO, 3 MOB_REGEN, 4 CALL_PS |
| +0x204 | `QUEST_REWARD Reward[12]` (0xC each) | `{u8 Use (0 UNUSE, 1 PRIMARY, 2 SELECTABLE); u8 Type; VALUE Value (8)}`; Type 0 EXP `{u32}`, 1 MONEY `{u32}`, 2 ITEM `{u16 ItemID, u16 ItemLot}`, 3 ABSTATE `{u32 KeepTime, u16 AbstateID, u8 Strength}`, 4 FAME `{u32}`, 5 PET `{u32}`, 6 MINIHOUSE `{u8}`, 7 TITLE `{u8 Type, u8 ElementNo}`, 8 KILLPOINT `{u32}` (§5) |
| +0x294 | u16 `SizeOfScriptStart`, +0x296 `SizeOfScriptEnd`, +0x298 `SizeOfScriptDoing` | |
| +0x29C | `char *pScriptStart`, +0x2A0 `pScriptDoing`, +0x2A4 `pScriptEnd` | set on load |
| +0x2A8 | `DialogData[]` | zero-length tail (unused by the zone) |

`QUEST_START_CONDITION` (row +0x18): +0 `bIsWaitListView`, +1 `bIsWaitListProgress` (row +0x19), +2 `bLevel`, +3
`LevelMin`, +4 `LevelMax`, +5 `bNPC` (row +0x1D), +6 u16 `NPCID` (row +0x1E), +8 `bItem` (row +0x20), +0xA u16 `ItemID`,
+0xC u16 `ItemLot`, +0xE `bLocation`, +0x10 u16 `Location`, +0x14/+0x18/+0x1C u32 `LocationX/Y/Range`, +0x20 `bQuest`,
+0x22 u16 `QuestID` (prerequisite), +0x24 `bRace`/+0x25 `Race`, +0x26 `bClass`/+0x27 `Class`, +0x28 `bGender`/+0x29
`Gender`, +0x2A `bDate`, +0x2B `DateMode` (0 YEAR_TERM, 1 MONTH_TERM, 2 DATE_TERM, 3 PERIOD), +0x30/+0x38 i64
`DateStart`/`DateEnd`.

`QUEST_END_CONDITION` (row +0x58): +0 `bIsWaitListProgress` (row +0x58), +1 `bLevel`, +2 `Level`, +4
`NPCMobList[5]` (8 each: `{u8 bNPCMob; u16 NPCMobID; u8 NPCMobAction (0 REWARD_OBJECT, 1 KILL, 2 FIND, 3 CONVERSATION);
u8 NPCMobCount; u8 TargetGroup}`; entry 0 at row +0x5C, its NPC id at row +0x5E), +0x2C `ItemList[5]` (6 each:
`{u8 bItem; u16 ItemID; u16 ItemLot}`), +0x4A `bLocation`, +0x4C u16 `Location`, +0x50/+0x54/+0x58 u32
`LocationX/Y/Range`, +0x5C `bScenario`, +0x5E u16 `ScenarioID`, +0x60 `bRace`/+0x61 `Race`, +0x62 `bClass`/+0x63
`Class`, +0x64 `bTimeLimit`, +0x66 u16 `TimeLimit`.

What the shipped 2016 table uses *(data)*: Types 0 (1350), 1 (518), 2 (237), 3 (117), 4 (36), 5, 7, 8, 10 (30);
157 repeatable; 30 daily quests, all `nDailyQuestType` 1 DAY; start conditions in use: wait-list flags, level (2094),
start NPC (2093), item (20), prerequisite quest (1385), class (127), gender (2); never location, race or date. End
conditions: NPC/mob list (action 0 reward NPC 2293×, action 1 kill 953×, target group 2 in 158), item list, level (9),
scenario (3), wait-list progress (597); never location, race, class or time limit. 678 quests have actions (976
entries: IfType 1 MOB_KILL / 2 GATHER, ThenType always 1 DROP_ITEM). Rewards: EXP / MONEY primary in almost every
quest, ITEM primary 530× and selectable 362×, FAME 17×, one selectable EXP; never abstate, pet, mini-house, title or
kill points.

---

## 2. The script language and its parser (`CQuestParserScript`)

### 2.1 Objects

Every player's `CQuestZone` (p+0x173e8, Z08 §3.1; derived from the shared `CQuest`) embeds one parser
`m_ScriptParser` at +0xB8, so a player runs at most one script at a time. `CQuestZone` members *(pdb2016)*:

| `CQuestZone+` | Member | Meaning |
|---|---|---|
| +0x04 | `m_pQuestData` | → `gQuestData` (passed to `CQuest::CQuest` by the `CQuestZone` constructor *(inferred: stored there, part 3)*; `InitNewPlayer` @ FUN_005b9d40 asserts "m_pQuestData NULL" and repairs it) |
| +0xA4 | `m_QuestRestTime` | `PROTO_NC_QUEST_RESET_TIME_CMD` (Z08 §3.4) |
| +0xB4 | `m_pPlayer` | owner (`qz_SetObject` @ FUN_005b9ae0); NULL → every entry point returns |
| +0xB8 | `m_ScriptParser` | `CQuestParserScript` (0x844 bytes, below) |
| +0x8FC | `m_pQSC` | → the current command (`&m_ScriptParser.m_QSC`, set by the interpreter, §3) |
| +0x900 | `m_bWaitResult` | a client/DB answer is awaited |
| +0x904 | u16 `m_QuestClickNPC` | NPC of the running script (0xFFFF none) |
| +0x906 | u16 `m_ParsingQuestID` | quest of the running script (0xFFFF = no script open) |
| +0x908 | `m_ParsingQuestScriptType` | `QPST_START` 0 / `QPST_DOING` 1 / `QPST_END` 2 |
| +0x90C | u32 `m_nSelectedItem` | selected reward index (0x4411; 0xFFFFFFFF = none) |
| +0x910 | u16 `m_nClickNPCNo`, +0x914 int `m_ScriptIdent` | §3 / §6 |

`CQuestParserScript` (0x844) *(pdb2016)*: +0 vftable (one slot: `CommandRun`, vftable `0x0070876c`), +4…+0x14 the
keyword tables `m_ppQSC/QSV/QSAE/QST/QSIL` (§2.2), +0x18 `u32 m_Var[8]` (script variables; `m_Var[0]` = RESULT is
`CQuestZone+0xD0`, Z08's "last answer"), +0x38 `m_NumOfMark`, +0x3C `STRUCT_SQDC_MARK m_Mark[64]` (`{char
MarkName[16]; char *pMarkPoint}`), +0x53C `CToken m_Token` (the shared tokenizer, S02 §2.2), +0x7D0 `STRUCT_QSC
m_QSC` (the decoded current command; its `Cmd` is `CQuestZone+0x888`, Z08's "script state"), +0x838 `CQuest
*m_pQuest`, +0x83C u16 `m_QuestID`, +0x840 `m_NumOfError`.

`m_pQuest` is never written anywhere in the binary (no store to parser+0x838 / `CQuestZone`+0x8F0; the constructor
does not set it): the `PROGESS` variable (§2.6) reads the diary through this unset pointer (original bug) Z15-B2.

```pseudo
CQuestParserScript::CQuestParserScript():                                          @ FUN_00636f60
    CToken::CToken(&m_Token); m_QSC.IsPigeonStartType = 0
    m_ppQSC = gpQSC; m_ppQSV = gpQSV; m_ppQSAE = gpQSAE; m_ppQST = gpQST; m_ppQSIL = gpQSIL
    m_Token.SetSeprator(" ,\t\r\n")                # comma is a separator too
CQuestParserScript::~CQuestParserScript(): m_Token.Close(); ~CToken                 @ FUN_006371b0
CQuestParserScript::ParserClose(): m_Token.Close()                                 @ FUN_00637090
CQuestZone::CQuestZone(questData): CQuest::CQuest(questData); parser ctor; m_pPlayer = NULL; four more members 0   @ FUN_005b9a00
```

### 2.2 Keyword tables (static data)

Matching is case-insensitive and whole-token (`CToken::IsTokenID` → `_mbsicmp`, S02 §2.2); tokens are separated by
space, comma, tab, CR, LF.

| Table | Address | Entries (index = enum value) |
|---|---|---|
| `gpQSC` commands, searched with n = 0x22 | `0x008718f0` | 0 ERROR, 1 END, 2 SAY, 3 SCENARIO, 4 CALLPS, 5 CLEAR, 6 ACCEPT, 7 CANCEL, 8 PROGRESS, 9 FAILED, 10 DONE, 11 LINK, 12 ABORT, 13 DELETE_ITEM, 14 CREATE_ITEM, 15 DROP_ITEM, 16 `;`, 17 IF, 18 GOTO, 19 `:`, 20 SET, 21 ADD, 22 SUB, 23 GET_PLAYER_RACE, 24 GET_PLAYER_CLASS, 25 GET_PLAYER_LEVEL, 26 GET_PLAYER_GENDER, 27 GET_PLAYER_EMPTY_INVENTORY, 28 REPEAT_QUEST_GIVE_UP, 29 UNKNOWNED, 30 SET_ABSTATE, 31 RESET_ABSTATE, 32 IS_ABSTATE, 33 GET_ITEM_LOT (34 MAX, 35 EOF are outside the searched range) |
| `gpQSV` variables (n = 7 or 6) | `0x00871980` | 0 RESULT, 1 VAR1 … 5 VAR5, 6 **`PROGESS`** (sic), 7 CONSTANT (never matched) |
| `gpQSAE` operators (n = 6) | `0x008719a0` | 0 `==`, 1 `!=`, 2 `<`, 3 `>`, 4 `<=`, 5 `>=` |
| `gpQST` talkers (n = 2) | `0x008719b8` | 0 NPC, 1 ME |
| `gpQSIL` item lot (n = 1) | `0x008719c0` | 0 ALL |

The enum names (`QUEST_SCRIPT_COMMAND` `QSC_*`, `QUEST_SCRIPT_VARIABLE` `QSV_*` with `QSV_PROGRESS` = 6,
`QUEST_SCRIPT_ARITHMETIC_EXPRESSION` `QSAE_*`, `QUEST_SCRIPT_TALKER`) are *(pdb2016)*; the script keyword for variable 6
is spelled `PROGESS` in the table, so a script that writes `PROGRESS` as a variable fails to parse (it is the
command keyword 8 in the command table only) (original bug) Z15-B4.

### 2.3 Name table `QuestParser.txt`

`CQuestParserScript::m_MapConvertIndexNames` is a static `std::map<std::string, int>` (initialised @ FUN_0069bb40,
destroyed @ FUN_006a1310). It lets `IF` compare with a name instead of a number. The 2016 file
`../9Data/Shine/World/QuestParser.txt` *(data)* maps the 25 class names to their class numbers: `Fighter 1`,
`CleverFighter 2`, `Warrior 3`, `Gladiator 4`, `Knight 5`, `Cleric 6`, `HighCleric 7`, `Paladin 8`, `HolyKnight 9`,
`Guardian 10`, `Archer 11`, `HawkArcher 12`, `Scout 13`, `SharpShooter 14`, `Ranger 15`, `Mage 16`, `WizMage 17`,
`Enchanter 18`, `Warrock 19`, `Wizard 20`, `Joker 21`, `Chaser 22`, `Cruel 23`, `Closer 24`, `Assassin 25` (CRLF lines).
No 2016 script uses a name (§2.8).

```pseudo
static CQuestParserScript::LoadConvertIDfromIndexName(path) → bool:               @ FUN_00639c90
    ifstream f(path); not open → return false             # the zone then exits (Z10 §7.1)
    m_MapConvertIndexNames.clear()
    while getline(f, line, '\n'):                          # the CR stays in the line; >> skips it
        istringstream ss(line); string name; int value
        ss >> name
        if name empty: return false                        # an empty line aborts the load and with it the zone
                                                           # start (original bug) Z15-B7
        ss >> value                                        # a missing / non-numeric value is not checked: the
                                                           # name maps to the int's prior value (inferred: 0 on the
                                                           # first line, the previous line's value after that)
        if name already in the map: return false           # duplicates are refused
        map[name] = value
    return true                                            # at end of file
static CQuestParserScript::GetIDbyIndex(name, &id) → bool:  exact, case-sensitive std::string lookup   @ FUN_006382e0
```

### 2.4 Opening a script: `ParserStart`

A script is the NUL-terminated text of one of the three record scripts (§1.1). It is tokenised in place (S02 §2.2:
tokens are NUL-terminated inside the buffer; `GoBegin` restores the pristine copy).

```pseudo
CQuestParserScript::ParserStart(questId, text) → int:                              @ FUN_00639650
    m_QuestID = questId; m_Var[0..7] = 0; m_NumOfMark = 0
    if !m_Token.OpenFromMemory(text): return 0             # empty text ("" for an unknown quest or an empty
                                                           # script) is refused
    m_NumOfError = 0
    repeat:                                                # validation pass over the whole script
        c = ParserNext()
        c.Cmd == ERROR  → m_NumOfError++
        c.Cmd == REMARK → vt[0] = CommandRun(c): skip the rest of the line
        c.Cmd == MARK   → MarkAdd(c.MarkName, c.MarkPoint) fails → m_NumOfError++
    until c.Cmd == EOF
    if m_NumOfError: return 0                              # one bad command anywhere refuses the whole script
    return m_Token.GoBegin()                               # rewind: execution re-parses from the start (§3)

CQuestParserScript::MarkAdd(name, point) → int:                                    @ FUN_00637210
    for each mark i: if _mbsicmp(Mark[i].MarkName, name) == 0:
        if Mark[i].pMarkPoint: return 0                    # duplicate label → script error
        break                                              # (an entry without point cannot exist: dead path)
    if m_NumOfMark >= 64: return 0                         # more than 64 labels → script error
    Mark[n].MarkName = first 15 bytes of name (_mbsnbcpy, NUL-padded); Mark[n].pMarkPoint = point; n++
    return 1
CQuestParserScript::MarkGo(name) → int:                                            @ FUN_00637030
    first mark with _mbsicmp(MarkName, name) == 0, else return 0
    return m_Token.RestoreTokenPositon(mark.pMarkPoint)    # reload the buffer, continue after the label token
    # labels are stored truncated to 15 bytes but compared against the full GOTO operand, so a GOTO to a label of
    # 16+ characters never finds it (original bug) Z15-B8 (the longest 2016 label has 15)
CQuestParserScript::IsDigitStr(s): s non-NULL, non-empty and every byte _ismbcdigit   @ FUN_00636ff0
    # no sign: negative constants cannot be written
```

### 2.5 `ParserNext`: the grammar

`ParserNext` @ FUN_006387f0 (Z08: `QuestScript_Next`) reads the next command into `m_QSC` and returns `&m_QSC`.
`STRUCT_QSC { QUEST_SCRIPT_COMMAND Cmd; u8 IsPigeonStartType; Data[0x60] }` (0x65 bytes) *(pdb2016)*; `Data` is a
union, one `tagSTRUCT_QSC_<CMD>` per command (offsets below are into `Data`). Fields the parser does not write keep
the previous command's bytes.

```pseudo
CQuestParserScript::ParserNext() → STRUCT_QSC*:                                     @ FUN_006387f0
    tok = m_Token.GetTokenID(&k, gpQSC, 0x22)
    if tok == NULL: Cmd = EOF (35); return            # end of buffer (also the empty end token, S02 §2.2)
    Cmd = k
    if k == -1 (not a keyword):
        if tok[0] == ':' (first char of gpQSC[19]):  Cmd = MARK; MarkName = tok+1; MarkPoint = m_Token.m_pToken
        else: parse error UNKNOWNED                   # ":" alone is keyword 19 and also an error (no case for it)
    else: parse the operands of k (table below)
    parse error (cmd X, token t): Cmd = ERROR (0); Data.ErrCmd = X; Data.pErrStr = t   # ErrCode not written
```

`opt N` = optional number: the parser saves the token position, reads the next token and, if it is not a number,
restores the position (`SaveTokenPositon` / `RestoreTokenPositon`, which reloads the buffer, S02 §2.2).

| Cmd | Syntax | `Data` written | Errors (`ErrCmd`) |
|---|---|---|---|
| 1 END, 16 `;` | `END`, `; any text` | none (the remark's line is skipped by `CommandRun`) | |
| 2 SAY | `SAY <textId> NPC [npcNo]` / `SAY <textId> ME` | +0 u32 `nID`, +4 `TalkerType` (0 NPC, 1 ME), +8 u16 `NPCNo` (0xFFFF unless given after NPC) | SAY: id not a number, talker missing/unknown |
| 3 SCENARIO | `SCENARIO <id>` | +0 u16 `nScenarioID` | SCENARIO |
| 4 CALLPS | `CALLPS <file> <block>` | +0 `char FileName[64]` (token < 64 chars), +0x40 `char StartBlockName[32]` (< 32) | CALLPS: too long |
| 5 CLEAR, 6 ACCEPT, 7 CANCEL, 9 FAILED, 10 DONE, 11 LINK, 12 ABORT | `<CMD> [questId]` | +0 u16 `nID` = the number, else the script's own quest (`m_QuestID`) | |
| 8 PROGRESS | `PROGRESS <step> [questId]` | +2 u8 `ProgressStep`, +0 u16 `nID` (as above) | PROGRESS: step not a number |
| 13 DELETE_ITEM | `DELETE_ITEM <itemId> [ALL | lot]` | +0 u16 `nItemID`, +2 u32 `nLot` = 1, ALL → 0xFFFFFFFF, or the number | CREATE_ITEM (sic) for a bad item id (original bug) Z15-B5 |
| 14 CREATE_ITEM, 15 DROP_ITEM | `<CMD> <itemId> [lot]` | +0 u16 `nItemID`, +2 u32 `nLot` (default 1) | CREATE_ITEM / DROP_ITEM |
| 17 IF | `IF <a> <op> <b>` | +0 `VarID1`, +4 `Value1`, +8 `ExpressionID` (`gpQSAE`), +0xC `VarID2`, +0x10 `Value2` | IF |
| 18 GOTO | `GOTO <label>` | +0 `pMarkName` (→ token) | |
| 19 MARK | `:<label>` | +0 `pMarkName` (→ token+1), +4 `pMarkPoint` | (MarkAdd, §2.4) |
| 20 SET, 21 ADD, 22 SUB | `<CMD> <var> <var|number>` | +0 `TargetVarID` (`gpQSV`, 7 entries incl. PROGESS), +4 `TargetValue` = current `m_Var[var]`, +8 `SourceVarID` (var or 7 CONSTANT), +0xC `SourceValue` (`m_Var[var]` or the number) | SET / ADD / SUB |
| 23–27 GET_PLAYER_RACE / CLASS / LEVEL / GENDER / EMPTY_INVENTORY | `<CMD> <var>` | +0 `TargetVarID` (RESULT, VAR1…VAR5 only), +4 `TargetValue` = `m_Var[var]` | the command |
| 30 SET_ABSTATE | `SET_ABSTATE <name> <strength> <keepTime>` | +0 `pAbStateName` (→ token), +4 u8 `nStrength`, +5 u32 `nKeepTime` | SET_ABSTATE |
| 31 RESET_ABSTATE, 32 IS_ABSTATE | `<CMD> <name>` | +0 `pAbStateName` (→ token); `IS_ABSTATE`'s `TargetVarID`/`TargetValue` (+4/+8, pdb2016) are **not** parsed | |
| 33 GET_ITEM_LOT | `GET_ITEM_LOT <itemId>` | +0 u16 `nItemID` | GET_ITEM_LOT |
| 0 ERROR, 19 `:` alone, 28 REPEAT_QUEST_GIVE_UP, 29 UNKNOWNED, unknown words | | | UNKNOWNED |

`IF` operands, in this order: a variable from `gpQSV` (7 entries; `Value` = the variable's current value, unused at
run time), a `QuestParser.txt` name (→ `VarID` 7 CONSTANT, `Value` = mapped id), a number (→ CONSTANT). For the
left operand the name lookup comes before the number test; for the right operand the variable test comes first, then
the name, then the number. A right operand found in `QuestParser.txt` is written to `VarID1`/`Value1` (Data+0/+4,
confirmed in the asm at 0x638dd0) instead of `VarID2`/`Value2`: the left operand is overwritten with the name's id and
the right operand keeps stale bytes, so `IF VAR1 == Fighter` compares `1` with whatever the previous command left
there (original bug) Z15-B3.

The string operands (`GOTO` label, abstate names) point into the token buffer; they stay valid only until the buffer is
reloaded by the next `RestoreTokenPositon` (an optional-operand peek or a `GOTO`). The interpreter uses them before
parsing the next command (§3.2, read in `QuestNext`).

### 2.6 `CommandRun`: control flow and variables

The interpreter (§3) calls `CommandRun` for every parsed command; a non-zero return means "handled by the parser".

```pseudo
CQuestParserScript::CommandRun(c) → int:                                           @ FUN_00639390
    switch c.Cmd:
    REMARK (16): m_Token.GoNextLine(); return 1              # skip the comment text
    IF (17):
        a = GetScriptVariableValue(m_QuestID, c.VarID1, c.Value1) else return 0
        b = GetScriptVariableValue(m_QuestID, c.VarID2, c.Value2) else return 0
        r = by ExpressionID, unsigned 32-bit: 0 a == b, 1 a != b, 2 a < b, 3 a > b, 4 a <= b, 5 a >= b
        if ExpressionID > 5 or !r: ParserNext()              # false: skip exactly one command (the GOTO)
        return 1
        # IF has no block form: "IF <cond> <command>" (in practice always "IF … GOTO <label>"); a false IF also
        # skips a following ";" remark keyword without skipping its text (that text is then parsed as commands)
    GOTO (18): return MarkGo(c.pMarkName)                     # 0 when the label does not exist
    SET (20): v = GetScriptVariableValue(c.SourceVarID, c.SourceValue) else return 0; m_Var[c.TargetVarID] = v; return 1
    ADD (21): … m_Var[t] += v; return 1                      # u32 wrap-around
    SUB (22): … m_Var[t] -= v; return 1
    0–15, 23–28, 30–33: return 0                             # action commands: executed by the interpreter (§3)
    other (19 MARK, 29, 34, 35 EOF): return 1                 # labels are no-ops at run time

CQuestParserScript::GetScriptVariableValue(&out, questId, var, value) → int:       @ FUN_006370a0
    var 0..5 (RESULT, VAR1..VAR5): out = m_Var[var]; return 1
    var 6 PROGESS: info = CQuest::GetQuestInfo(m_pQuest, m_QuestID) (FUN_0062f210); NULL → return 0
                   out = info.Data.ProgressStep; then out = value; return 1
                   # no break before the CONSTANT case (asm 0x6370df–0x6370e8): the progress step is overwritten by
                   # the operand's parse-time value, i.e. the current m_Var[6] (original bug) Z15-B1; and m_pQuest is
                   # never set (Z15-B2), so the diary lookup runs on an unset pointer
    var 7 CONSTANT: out = value; return 1
    other: return 0
```

So a script has six usable variables (RESULT, VAR1…VAR5) plus `m_Var[6]`, which `SET/ADD/SUB PROGESS` write and which
`IF PROGESS …` reads (only when the quest has a diary record, and only if the unset `m_pQuest` happens to work). All
variables are 0 when a script starts. `RESULT` also receives the answer of SAY / SCENARIO (Z08 §3.2) and the getters'
results go to their target variable (§3).

### 2.7 Choosing and opening the script of a quest

```pseudo
CQuestZone::QuestScriptRun(status, questId) → int:                                @ FUN_005c0080
    if !m_pPlayer: return 0
    status 4 REPEAT, 5 ABLE, 20 READ_ABLE: ok = QuestStart(questId)    # not yet accepted → Start script
    status 6 ING, 7 FAILED:               ok = QuestDoing(questId)    # in progress → Doing script
    status 8 REWARD:                      ok = QuestEnd(questId)      # conditions met → End script
    other: return 0
    return ok ? QuestNext() : 0                                        # run until the first wait (§3)

CQuestZone::QuestStart(questId) → int:                                             @ FUN_005bca30
    if !m_pPlayer: return 0
    if p.vt 0xAE0 so_GetIsQuestRewardReq() == 1: return 0             # a reward (0x441A) is in flight
    QuestClose()
    if !m_ScriptParser.ParserStart(questId, gQuestData.GetQuestScriptStart(questId)):
        m_ParsingQuestID = 0xFFFF; return 0
    m_ParsingQuestID = questId; m_ParsingQuestScriptType = QPST_START
    m_bWaitResult = 0; m_nSelectedItem = 0xFFFFFFFF; return 1
CQuestZone::QuestDoing(questId):  same with GetQuestScriptDoing and QPST_DOING, without the reward-request test   @ FUN_005bcb80
CQuestZone::QuestEnd(questId):    same with GetQuestScriptEnd and QPST_END, without the reward-request test       @ FUN_005bccb0

CQuestZone::QuestClose() → int:                                                    @ FUN_005b9e50
    if !m_pPlayer: return 0
    if m_ParsingQuestID != 0xFFFF: m_ScriptParser.ParserClose(); m_ParsingQuestID = 0xFFFF; m_bWaitResult = 0
    return 1
```

Opening a new script always closes the running one first, so a script interrupted by another NPC click or quest
start is abandoned without notice to the client *(inferred from the call order)*.

### 2.8 The shipped 2016 scripts *(data)*

Over all 2306 quests: 2304 Start, 2061 Doing and 2227 End scripts are non-empty; 2 Start, 245 Doing and 79 End scripts
are empty, so `QuestScriptRun` returns 0 for those states. A re-implementation of the §2.5 grammar parses every
non-empty script without error. Commands used (count of lines): `SAY` 19935 (`SAY n NPC` 12943, `SAY n ME` 6924,
`SAY n NPC npc` 68), `END` 9451, `IF` 3037 (`IF RESULT == n GOTO L` 2247, `IF VAR1 < n GOTO L` 676, `IF RESULT < n
GOTO L` 104, …), labels 2987, `DONE` 2605, `ACCEPT` 2412 (22 with a quest id), `DELETE_ITEM` 1474 (1035 with `ALL`),
`GET_PLAYER_EMPTY_INVENTORY VAR1` 676, `LINK` 350, `CREATE_ITEM` 206, `;` 201, `GET_ITEM_LOT` 104, `SCENARIO` 52,
`SET_ABSTATE` 51 (`StaQDayExpUp`, `StaQDayDropUp`, `StaQDayWcUp`, `StaQDayMaUp`), `CANCEL` 12, `GOTO` 4. Never used:
CALLPS, CLEAR, PROGRESS, FAILED, ABORT, DROP_ITEM, SET/ADD/SUB, GET_PLAYER_RACE/CLASS/LEVEL/GENDER, RESET_ABSTATE,
IS_ABSTATE, `QuestParser.txt` names. Labels: at most 9 per script, longest 15 characters.

21 `GOTO`s name a label their script does not define (copy-paste leftovers such as `IF RESULT == 1 GOTO MARK1`
after `DONE` in an End script): End scripts of quests 24, 25, 85, 96, 97, 100, 108, 111, 112, 116, 118, 228, 229, 416
and Start scripts of 2313, 60024, 60102, 60108. `MarkGo` fails for them (§3 describes what the interpreter then does).

Typical script (quest 24, Start / End):

```
SAY 2452 NPC                      SAY 2455 ME
SAY 2453 ME                       GET_PLAYER_EMPTY_INVENTORY VAR1
SAY 2454 NPC                      IF VAR1 < 2 GOTO MARK100
IF RESULT == 1 GOTO MARK1         DONE
END                               SAY 2457 NPC
:MARK1                            IF RESULT == 1 GOTO MARK1      ← no MARK1 in this script
ACCEPT                            END
END                               :MARK100
                                  SAY 106 NPC
                                  END
```

---

## 3. The interpreter (`CQuestZone::QuestNext`) and the action commands

### 3.1 Run state

A script runs in the player's `CQuestZone` (§2.1). The interpreter keeps no stack and no program counter of its own:
the position is the tokenizer position of `m_ScriptParser`, the current command is `m_QSC` (`m_pQSC` → it), and the
script pauses whenever a command needs an answer. State that controls a pause:

| Member | Set to 1 / a value by | Cleared by |
|---|---|---|
| `m_ParsingQuestID` (+0x906) | `QuestStart/Doing/End` (§2.7) | `QuestClose` (0xFFFF) |
| `m_bWaitResult` (+0x900) | SAY, CLEAR, CANCEL, PROGRESS, FAILED, ABORT, a client SCENARIO (§3.6); **not** ACCEPT, DONE, CALLPS, server SCENARIOs (Z15-B15) | every 0x4402 (§3.4), `Recv_NC_QUEST_DB_SET_INFO_ACK` (Z08 §3.3), `Recv_NC_QUEST_DB_CLEAR_ACK` success (§3.5), `Recv_NC_QUEST_DB_DONE_ACK` success (§5), `QuestStart/Doing/End`, `QuestClose`, `InitNewPlayer` |
| `m_Var[0]` RESULT (+0xD0) | SAY / SCENARIO answer (§3.4), `PsEnd` (§3.7), `IS_ABSTATE`, `GET_ITEM_LOT` | never reset while the script runs (0 at `ParserStart`, §2.4) |

`m_bWaitResult` only makes `QuestNext` return 2 and makes `QuestPlayer_NotCheckNPC` (0x4414, Z08 §3.2; §6) refuse; it
does not stop a new script from being opened (`QuestStart` closes the running one, §2.7).

Resuming: the answer handlers call `QuestNext` again: 0x4402 (§3.4), 0x4404 SET_INFO_ACK (Z08 §3.3, part 3),
0x4406 CLEAR_ACK (§3.5), 0x441B DONE_ACK (§5), `PsEnd` (§3.7), and `QuestScriptRun` / LINK for a freshly opened script.

### 3.2 The loop

```pseudo
CQuestZone::QuestNext() → int:                                                     @ FUN_005bdef0
    if !m_pPlayer or m_ParsingQuestID == 0xFFFF: return 0
    if m_bWaitResult: return 2                                    # an answer is still awaited
    m_pQSC = m_ScriptParser.ParserNext()                          # §2.5
    loop:
        if m_QSC.Cmd in {END 1, EOF 35, ERROR 0}:                 # tested before the command is executed
            QuestClose()                                          # §2.7
            sp_EndOfTrade(p, 1)                                   # Z02 §6.4: drops the NPC link, resets the server menu
            return m_QSC.Cmd != ERROR                             # 1 = normal end, 0 = parse/run error
        if m_ScriptParser.CommandRun(m_pQSC) != 0:                # control flow / variables (§2.6), vftable slot 0
            m_pQSC = ParserNext(); continue
        switch m_pQSC.Cmd:                                        # action commands (§3.3)
            … a command that pauses returns 1 (or its send result); one that fails sends an error and returns 0
            … a command that completes falls through to:
        m_pQSC = ParserNext()                                     # next command; loop
```

Consequences, all read in the loop:

- **END is never executed.** The `END` test at the loop head closes the script before the switch, so the switch's
  `QSC_END` case (which would send the command to the client with `Send_NC_QUEST_SCRIPT_CMD_REQ`) is dead code; the
  server never sends `Cmd 1` to the client, whose END handler would close the NPC dialog (§3.4) (original bug) Z15-B12.
  A script end is silent for the client; only `sp_EndOfTrade` runs on the server.
- **A failed GOTO, SET, ADD or SUB** (`CommandRun` returned 0: missing label, bad variable) reaches the switch, which
  turns it into an error in place: `m_QSC.Data.ErrCmd = Cmd; m_QSC.Cmd = ERROR`; the loop head then closes the script
  and returns 0. No error packet is sent (unlike every other failure, §3.10), so the client gets neither a message nor a
  dialog close (original bug) Z15-B14. This is what the 21 `GOTO`s to missing labels of the 2016 data do (§2.8): e.g.
  quest 24's End script, after a successful `DONE`, shows text 2457 and, if the player picks answer 1, ends this way.
- **A failed IF** (`CommandRun` returned 0 because a variable could not be read: `PROGESS` without a diary record,
  §2.6) reaches the switch, where `IF` has no case (default: next command): the command after the IF (its `GOTO`) is
  executed as if the condition were true (original bug) Z15-B13.
- **DROP_ITEM** (15) is parsed (§2.5) but has no case: it is skipped. Never used in 2016 (§2.8). `REPEAT_QUEST_GIVE_UP`
  (28, only used as a DB command code, part 3) and `UNKNOWNED` (29) cannot be parsed (§2.5).
- A command that fails with `Send_QUEST_ERROR_TO_CLIENT` + `QuestClose` and then `break`s (DELETE_ITEM, CREATE_ITEM, a
  refused LINK) continues the loop on the closed parser: `CToken::Close` (FUN_0063af10) frees and NULLs the buffer, so
  `ParserNext` returns EOF, the loop head runs `QuestClose` (no-op) and `sp_EndOfTrade` again and returns 1.
- String operands (`GOTO` label, abstate names, §2.5) are used (MarkGo, or copied to the stack, §3.3) before the next
  `ParserNext`, so the token-buffer lifetime problem noted in §2.5 does not arise.
- Z08 §3.1's "other: log QUEST UN-DRIVED COMMAND, stop" is not in `QuestNext`: that log belongs to the 0x4402 handler
  (§3.4); unknown commands cannot reach the interpreter (the parser turns them into ERROR).

Return value: 0 = no script / closed with an error, 1 = paused or ended normally, 2 = already waiting. Callers ignore it
except `QuestScriptRun` (§2.7) and LINK (below), which pass it on.

### 3.3 Action commands

Operands are the `Data` fields of §2.5 (`nID` = the command's quest id, default the script's own quest). `info` =
a 0x20-byte `PLAYER_QUEST_INFO` built on the stack, `rec` = the diary record `CQuest::GetQuestInfo(nID)` (FUN_0062f210),
`row` = `CQuestData::GetQuestData(nID)` (FUN_00635ff0, §1). Profiler names of the blocks are `"CQuestZone::QuestEnd -
QSC_<CMD>"` (sic, inside `QuestNext`). Error codes and their client texts: §3.10. "error X" below always means
`Send_QUEST_ERROR_TO_CLIENT(X)` (§3.4) followed by `QuestClose()`.

`PLAYER_QUEST_INFO` (0x20) *(pdb2016)*: +0 u16 `ID`, +2 u8 `Status`, +3 `PLAYER_QUEST_DATA Data` = { +3 i64
`StartTime`, +0xB i64 `EndTime`, +0x13 u32 `RepeatCount`, +0x17 u8 `ProgressStep`, +0x18 u8 `End_NPCMobCount[5]`,
+0x1D bits `End_Location` (bit 0) / `End_Scenario` (bit 1), +0x1E u16 `End_RunningTimeSec` }.

```pseudo
SAY  { nID textId, TalkerType, u16 NPCNo }:                                       @ FUN_005bdef0
    if NPCNo == 0xFFFF: NPCNo = m_nClickNPCNo (+0x910, the clicked NPC, §6)      # written into m_QSC itself
    m_bWaitResult = 1
    Send_NC_QUEST_SCRIPT_CMD_REQ(m_ParsingQuestID, m_pQSC)        # 0x4401 with the whole command (§3.4)
    return 1                                                      # resumes on 0x4402: RESULT = the answer

SCENARIO { u16 nScenarioID }:  QuestPlayer_ScenarioRun(m_ParsingQuestID, m_pQSC) (§3.6); return 1

CALLPS { FileName[64], StartBlockName[32] }:
    if !PsStart(FileName, StartBlockName) (§3.7): error 0xC10; return 0
    return 1                                                      # resumes when the Pine script returns (PsEnd)

CLEAR { nID }:
    m_bWaitResult = 1
    return Send_NC_QUEST_DB_CLEAR_REQ(nID)                        # 0x4405 (§3.5); resumes on 0x4406

ACCEPT { nID }:
    if !row: error 0xC02; return 0
    if CQuest::GetNumOfDoingQuest() >= 40: error 0xC0F; return 0  # the 40-quest limit (part 3: what counts)
    if !CQuest::IsDoingableQuest(nID): error 0xC03; return 0      # start conditions (part 3)
    if !rec or rec.Status == 20 READ_ABLE:
        info = { ID = nID, Status = 6 ING, Data = 0 except StartTime = _time64(NULL) }
    else:                                                         # an existing record (e.g. 4 REPEAT)
        info = copy of rec; info.Status = 6 ING
        CQuest::SetQuestInfoClearRepeat(&info)                    # part 3
    return Send_NC_QUEST_DB_SET_INFO_REQ(&info, m_pQSC)           # 0x4403 with nQSC 6 (§3.5); m_bWaitResult stays 0
    # the diary itself changes only when 0x4404 confirms (Z08 §3.3, part 3)

CANCEL { nID }:
    if !rec or !row: error 0xC04; return 0
    m_bWaitResult = 1
    if row.Repeatable:
        info = copy of rec; info.Status = 4 REPEAT; CQuest::SetQuestInfoClearRepeat(&info)
        return Send_NC_QUEST_DB_SET_INFO_REQ(&info, m_pQSC)       # nQSC 7
    return Send_NC_QUEST_DB_CLEAR_REQ(nID)                        # non-repeatable: delete the record (§3.5)

PROGRESS { u8 ProgressStep, nID }:
    if !rec: error 0xC05; return 0
    m_bWaitResult = 1
    info = copy of rec; info.Data.ProgressStep = ProgressStep     # Status unchanged
    return Send_NC_QUEST_DB_SET_INFO_REQ(&info, m_pQSC)           # nQSC 8

FAILED { nID }:
    if !rec: error 0xC06; return 0
    m_bWaitResult = 1; info = copy of rec; info.Status = 7 FAILED
    return Send_NC_QUEST_DB_SET_INFO_REQ(&info, m_pQSC)           # nQSC 9

ABORT { nID }:
    if !rec: error 0xC09; return 0
    m_bWaitResult = 1; info = copy of rec; info.Status = 1 ABORT
    return Send_NC_QUEST_DB_SET_INFO_REQ(&info, m_pQSC)           # nQSC 12

DONE { nID }:                                                     # the reward path itself: §5
    if !rec: error 0xC07; return 0
    if !CQuest::IsRewardAbleQuest(nID): error 0xC08; return 0     # end conditions (part 3)
    if !QuestCheckSelectReward(nID, m_nSelectedItem):             # a selectable reward exists and none / an invalid one is chosen
        Send_NC_QUEST_REWARD_NEED_SELECT_ITEM_CMD(nID)            # 0x4412 (client: "Please choose reward(s).")
        return 1                                                  # script stays open on DONE, not waiting (below)
    if !QuestCheckReward(nID, m_nSelectedItem, p.vt 0x498 so_ply_ChargedEffectContainer()):
        error 0xC01; return 0                                     # e.g. no inventory room
    if Send_NC_QUEST_DB_DONE_REQ(nID, m_nSelectedItem): return 1  # 0x441A; resumes on 0x441B (§5)
    lockList = p.vt 0x7d4 so_ply_GetInventoryLockList()
    lockList.vt 0x28 icl_Free(lockList+4 (u16, the lock index just used)); (u16)lockList+4 += 1   # §5
    error 0xC01; return 0

LINK { nID }:
    switch CQuest::GetNewQuestStatus(nID):                        # part 3
        4 REPEAT, 5 ABLE, 20 READ_ABLE: ok = QuestStart(nID)
        6 ING, 7 FAILED:                ok = QuestDoing(nID)
        8 REWARD:                       ok = QuestEnd(nID)
        other:                          ok = 0
    if ok: return QuestNext()                                     # the old script was closed by QuestStart/…; run the new one
    QuestClose()                                                  # no error packet; loop continues on EOF (§3.2)

DELETE_ITEM { u16 nItemID, u32 nLot }:
    if !ShinePlayer::sp_DestroyItem(p, p.handle, nItemID, nLot, NULL) (FUN_00527b60, Z09 §17.8):
        error 0xC0A                                               # more lots asked than owned; nLot 0xFFFFFFFF (ALL) = every lot
    # success: DB 0x3459 NC_ITEMDB_DESTROY_REQ per cell (Z05); the script does not wait for it

CREATE_ITEM { u16 nItemID, u32 nLot }:
    if !ShinePlayer::sp_MakeItem(p, p.handle, 2, nItemID, nLot) (FUN_00528930): error 0xC0B
    # FUN_00528930: iti_mkregnum(item, kind 2, zone, world); fails only for an item id without ItemInfo; default
    # attributes ("-o"), lot = nLot, then sp_MakeItem(p, handle, &info) FUN_00528690 (Z09 §24.2): first empty unlocked
    # inventory cell → 0x3401 NC_ITEMDB_ADMINCREATE_REQ. With no free cell nothing is made and the command still
    # succeeds (original bug) Z15-B21 (the 2016 scripts test GET_PLAYER_EMPTY_INVENTORY first)

GET_PLAYER_RACE / CLASS / LEVEL / GENDER / EMPTY_INVENTORY { TargetVarID }:
    m_Var[TargetVarID] = (u8) this.vt[0x6c / 0x70 / 0x64 / 0x74 / 0x78]()     # getters §3.8; values 0…255

SET_ABSTATE { pAbStateName, u8 nStrength, u32 nKeepTime }:
    name = strcpy to a 128-byte stack buffer (unbounded copy of the token) (original bug) Z15-B22
    as = AbnormalStateDictionary::AbState::as_FromName(&dic_abstate, name); if !as or !as.index: nothing
    s = nStrength; if s == 0 or s > 40: s = 1
    t = nKeepTime; if t == 0: t = as.subabstate[s].assa_info.KeepTime (no sub-row: nothing)
    if p.vt 0x638 so_AbnormalState_Set(setter p, as.index.AbStataIndex, s, as, clockwatch.cw_CurrTick, 0, 0xFFFFFFFF, t, 0, 0)
            (FUN_004162d0, Z03 §6.2): ShineObject::so_AbnormalState_BitSet(p, idx)
        p.vt 0x3f0 so_AbnormalState_Inform(idx, t, 1); ShineObject::so_AbnormalState_BroadcastSet(p, idx, t, s)
    # no error code on failure; 2016 data: StaQDayExpUp / DropUp / WcUp / MaUp strength 1, 3 600 000 (1 h, ms) and
    # StaValenReward 1, 5 400 000 (data)

RESET_ABSTATE { pAbStateName }:
    as = as_FromName(copy of the name); found with an index: p.vt 0x650 so_AbnormalState_Reset(idx)

IS_ABSTATE { pAbStateName }:
    as = as_FromName(copy); not found: RESULT unchanged
    RESULT = AbstateListInObject::asl_Abstate_IsSet(p.vt 0x52c so_mobile_AbstateList(), idx) != NULL
    # the result always goes to RESULT: the TargetVarID / TargetValue members of the 2016 struct are neither parsed
    # (§2.5) nor read here

GET_ITEM_LOT { u16 nItemID }:
    RESULT = this.vt 0x68 GetQuestPlayerItemLot(nItemID) (u16, §3.8)     # always RESULT; no target operand

GOTO / SET / ADD / SUB reaching the switch (CommandRun failed): Cmd = ERROR (§3.2)
DROP_ITEM, IF (failed), other: nothing; next command
```

`DONE` without a selected reward leaves the script open on the `DONE` command with `m_bWaitResult` 0: the reward choice
normally arrives *before* `DONE`, because the client sends 0x4411 `NC_QUEST_REWARD_SELECT_ITEM_INDEX_CMD` (Z08 §3.2)
together with the answer to the preceding `SAY` (client `GameFrameWork::OnNpcDialogCommand` FUN_004966a0, the
`quest_ack <n>` dialog link sends 0x4411 when a reward was picked, then 0x4402). After 0x4412 nothing re-runs `DONE`; the
player has to start the dialog again (a new NPC click opens a new script) *(inferred: no caller resumes it)*.

ACCEPT does not set `m_bWaitResult` although it waits for 0x4404 like CANCEL/PROGRESS/FAILED/ABORT, so during the DB
round trip `QuestPlayer_NotCheckNPC` (0x4414) and `QuestNext` are not blocked (original bug) Z15-B15.

### 3.4 The client dialog: 0x4401 / 0x4402

```pseudo
CQuestZone::Send_NC_QUEST_SCRIPT_CMD_REQ(questId, qsc):                          @ FUN_005ba960
    if !m_pPlayer: return
    0x4401 NC_QUEST_SCRIPT_CMD_REQ { u16 nQuestID = questId; STRUCT_QSC Command = *qsc (0x65 bytes copied) }   # payload 0x67
    → the player (p.vt 0x2fc so_GetGameSocketStream → vt 0xc send)
    # the copy includes the bytes of Data the current command does not use: leftovers of earlier commands, among them
    # heap pointers into the token buffer (GOTO/MARK label, abstate names) (original bug) Z15-B11

CQuestZone::Send_QUEST_ERROR_TO_CLIENT(code):                                     @ FUN_005bd870
    if !m_pPlayer: return
    sp_EndOfTrade(p, 1)
    if m_ParsingQuestID != 0xFFFF:                                # nothing is sent once the script is closed
        e = STRUCT_QSC on the stack { Cmd = 0 ERROR, IsPigeonStartType = 0,
                                       Data.ErrCmd (u32 +0) = m_pQSC.Cmd, Data.pErrStr (+4) = 0, Data.ErrCode (u16 +8) = code }
        Send_NC_QUEST_SCRIPT_CMD_REQ(m_ParsingQuestID, &e)
        # Data+0xA…+0x5F (86 bytes) are never written: uninitialised stack bytes on the wire (original bug) Z15-B10
```

Every caller closes the script right after the error (`QuestClose`), except 0xC0C (below) and 0xC00 / 0xC0E (DB
answers, §3.5 / part 3).

```pseudo
0x4402 NC_QUEST_SCRIPT_CMD_ACK { u16 nQuestID, u8 nQSC, u32 nResult }   (PROTO size 7)
    zone handler @ FUN_00578340 (Z08 §3.2: IsActiveMode, p+0x5cb4 = g_Now) →
CQuestZone::Recv_NC_QUEST_SCRIPT_CMD_ACK(ack):                                    @ FUN_005bf0d0
    if !m_pPlayer: return
    m_bWaitResult = 0                                             # before any check
    if m_ParsingQuestID == 0xFFFF: return                         # no script: silently ignored
    if ack.nQuestID != m_ParsingQuestID or ack.nQSC != m_pQSC.Cmd:
        Send_QUEST_ERROR_TO_CLIENT(0xC0C); return                 # the script stays open (original bug) Z15-B19
    switch m_pQSC.Cmd:
        SAY:      RESULT = ack.nResult; QuestNext()
        SCENARIO: RESULT = ack.nResult
                  if ack.nResult != 0: this.vt 0x18 CQuest::QuestPlayer_ScenarioDone(m_pQSC.Data.nScenarioID)   # §3.6
                  QuestNext()
        LINK:     QuestStart(m_pQSC.Data.nID)                     # dead: LINK never pauses for the client (§3.3),
                                                                  # and the new script would not be run (original bug) Z15-B20
        other:    _DebugMessageNew("ERROR, Recv_NC_QUEST_SCRIPT_CMD_ACK, QUEST UN-DRIVED COMMAND=%d, QuestID=%d At %s")
                  Send_QUEST_ERROR_TO_CLIENT(0xC0D); QuestClose()
```

The ack is not tied to `m_bWaitResult`: any 0x4402 whose quest id and command match the current command is accepted.
For SCENARIO this includes the scenarios the server resolves itself and never sends to the client (job dungeons 8 /
12 / 13, job changes 9 / 14, third promotions 16…27, §3.6): a client that sends `{quest, 3, 1}` while such a scenario
is pending gets RESULT 1 and `QuestPlayer_ScenarioDone` for that scenario id, i.e. the quest's "scenario" end condition
without the dungeon (original bug) Z15-B18 *(effect inferred; which quests use a scenario end condition: §1.2, 3 in 2016)*.

Callers of `Recv_NC_QUEST_SCRIPT_CMD_ACK` besides the client handler: `QuestPlayer_ScenarioRun` (synchronous
scenarios, §3.6), `ShinePlayer::sp_ThirdPromote` FUN_00591de0 (§3.6) and the job-dungeon ring answer
`zls_NC_QUEST_JOBDUNGEON_FIND_RNG` FUN_005bfde0 (Z14).

**Client** (2016 `GameFrameWork::On_NC_QUEST_SCRIPT_CMD_REQ` FUN_004ba970; payload offsets: +0 nQuestID, +2 Cmd, +6
IsPigeonStartType, +7 Data):

| Cmd | Client action |
|---|---|
| 0 ERROR | message by `Data.ErrCode` (+0xF), formatted with the quest name (`CQuestData::GetQuestName(nQuestID)`), §3.10; then as END |
| 1 END | `PgWinMgr::CloseWin(NPC dialog window)` (never sent, Z15-B12) |
| 2 SAY | `TalkerType` (+0xB) 0 → `NpcDialogWin::OpenNpcQuestDialog(NPCNo (+0xF), textId (+7), questId, Cmd, IsPigeonStartType == 0)`; 1 → `OpenUserQuestDialog(textId, questId, Cmd)`; show the window |
| 5 CLEAR, 6 ACCEPT, 7 CANCEL, 8 PROGRESS (+9 = step), 9 FAILED, 10 DONE, 12 ABORT | the client diary: `CQuest::SetQuestClear / Accept / Cancel / Progress / Failed / Done / Abort(nID (+7))`; ACCEPT also adds the quest to the quest helper, searches the start item, plays sound 7; DONE removes it from the helper, sound 8; CANCEL / DONE refresh the quest-finish window. These are sent by `Recv_NC_QUEST_DB_SET_INFO_ACK` / `DONE_ACK` after the DB confirmed (Z08 §3.3), never by the interpreter itself; CLEAR is never sent (§3.5) |
| 3 SCENARIO, 4, 11, others | not handled here *(2016 client: where a client scenario starts is §3.6 / uncertain)* |

The client answers a SAY from its dialog: a dialog link `quest_ack <n>` (`GameFrameWork::OnNpcDialogCommand`
FUN_004966a0) sends 0x4411 (when a reward was selected) and 0x4402 `{nQuestID, nQSC = the received Cmd, nResult = n}`
through `GameFrameWork::NcQuestScriptCmdAck` FUN_0048c7e0; other dialog actions answer 4, 5, 9 or 10. The tutorial
manager (`TutorialMgr::…` FUN_006aff70…FUN_006b0090: inventory opened, item equipped, skill learnt, soul-stone keys,
upgrade window, weapon-title window) answers a pending client scenario with `nResult = 1`.

### 3.5 Diary requests of the interpreter: 0x4403, 0x4405 / 0x4406

```pseudo
CQuestZone::Send_NC_QUEST_DB_SET_INFO_REQ(info, qsc) → int:                     @ FUN_005baa80
    if !m_pPlayer: return 0
    → GameDB (sock2gameDB, the Character server, D04) 0x4403 NC_QUEST_DB_SET_INFO_REQ {     # payload 0x27
        u16 clienthandle = p.handle (p+4); u32 charregistnumber = p.vt 0x344 so_GetCharRegistNumber()
        u8 nQSC = qsc.Cmd (low byte); PLAYER_QUEST_INFO QuestInfo = *info }
    return 1
    # answer 0x4404 → Recv_NC_QUEST_DB_SET_INFO_ACK FUN_005bf280 (Z08 §3.3; part 3): applies the status change to the
    # diary, sends 0x4401 {ID, Cmd = nQSC} to the client, QuestNext

CQuestZone::Send_NC_QUEST_DB_CLEAR_REQ(questId) → int:                           @ FUN_005babd0
    if !m_pPlayer: return 0
    if (u32 at gpp buffer + 4) != 0:                               # tests the global send buffer's stale bytes, asm 0x5bac72
        → GameDB 0x4405 NC_QUEST_DB_CLEAR_REQ { u16 clienthandle; u32 charregistnumber; u16 nQuestID }   # payload 8
    return 1
    # when bytes 4…7 of the previous packet in the shared buffer were 0, nothing is sent, the caller has set
    # m_bWaitResult = 1 and the script hangs until the next QuestStart (original bug) Z15-B9; the test probably meant
    # the char number written to that same offset a few instructions later

0x4406 NC_QUEST_DB_CLEAR_ACK { hdr6, u16 nQuestID, u16 ErrorType }  (GameDB handler @ FUN_00578510, Z08 §3.3) →
CQuestZone::Recv_NC_QUEST_DB_CLEAR_ACK(ack):                                     @ FUN_005bf640
    if !m_pPlayer: return
    if ack.nQuestID != m_pQSC.Data.nID: Send_QUEST_ERROR_TO_CLIENT(0xC00); return    # no test that a script is open
    if ack.ErrorType != 0xB41:
        _DebugMessageNew("ERROR, CQuestZone::NC_QUEST_DB_…" with char name, quest id, time)
        Send_QUEST_ERROR_TO_CLIENT(0xC00); return                 # m_bWaitResult stays 1, the script stays open (original bug) Z15-B17
    m_bWaitResult = 0; QuestNext()
```

CLEAR, and CANCEL of a non-repeatable quest, delete the quest's DB record (D04: 0x4405 procedure) but change neither the
zone diary (`CQuest`) nor the client: the CLEAR_ACK continues the script without touching the record and sends no
0x4401 `Cmd 5/7`, so until the next login the zone and the client still show the quest in its old state (original bug)
Z15-B16. 2016 data: CLEAR is never used; the 12 `CANCEL`s (quests 60022/60023, 60100…60111, all non-repeatable)
follow an `IF RESULT == 0` right after an `ACCEPT` whose RESULT is still the preceding SAY answer 1, so they are not
reached *(data)*.

### 3.6 SCENARIO: server and client scenarios

A `SCENARIO <id>` command is either resolved by the zone (job changes, job-change dungeons) or forwarded to the
client (tutorial steps). The id is also the key of the quest end condition "scenario" (`End.bScenario`,
`End.ScenarioID`, §1.2), which `QuestPlayer_ScenarioDone` checks off.

```pseudo
CQuestZone::QuestPlayer_ScenarioRun(questId, qsc) → int:                          @ FUN_005bd2f0
    if !m_pPlayer: return 0
    ack = PROTO_NC_QUEST_SCRIPT_CMD_ACK { nQuestID = questId, nQSC = 3 SCENARIO, nResult }
    switch qsc.Data.nScenarioID:
    8:  job dungeon "Job1_Dn01", Pine film "Promote/JobChange1"            ┐ ZoneRingPacketFindJobDungeon::zrpb_Request(
    11: map "Rou", film "Promote/JobChange2-1"                             │   &zonringpack_findJobdungeon, p, map, film, &ack{nResult 0})
    12: "Job2_Dn01", "Promote/Job2_Gamb/Job2_Gamb"                         │ (Z14): finds or creates the instance in any zone;
    13: "Job2_Dn02", "Promote/Job2_Forest/Job2_Forest"                     ┘ if it returns with ack.nResult == 2: Recv_NC_QUEST_SCRIPT_CMD_ACK(&ack)
        # otherwise the answer comes later through the zone ring 0x441F (zls_NC_QUEST_JOBDUNGEON_FIND_RNG FUN_005bfde0,
        # Z14): player in a mode outside cmc_AllowMode 0x46 → message 0x30C2 and ack nResult 2; dungeon found (0x30C0)
        # → the player is sent to it (p.vt 0x600) and no ack (the dungeon's Pine script finishes the quest step:
        # `scinariocode` → ScenarioDone_Server, `returnvalue` → PsEnd, Z09 §26.1 / §25.6); not found → ack nResult 0
    9, 14: c = p.vt 0x3d4 so_ply_FirstJobChange()                 # below
           if c: CAnnounceSystem::AnnounceSystem_ClassUp(&gAnnounceSystem, p.so_CharName(), c)
           ack.nResult = (c != 0); Recv_NC_QUEST_SCRIPT_CMD_ACK(&ack)          # synchronous: the script continues at once
    15: nothing (no packet, no wait)                              # the client has a `Scenario_15` class (FUN_006b0400)
                                                                  # *(inferred: a client-side step answered with 0x4402)*
    16→class 4, 17→5, 18→10, 19→9, 20→15, 21→14, 22→19, 23→20, 24→24, 25→25, 27→27:
        ShinePlayer::sp_ThirdPromote(p, questId, class)          # below; acks synchronously
    other (incl. 10, 26):                                         # client scenarios
        m_bWaitResult = 1; Send_NC_QUEST_SCRIPT_CMD_REQ(m_ParsingQuestID, m_pQSC)   # 0x4401 Cmd 3; resumes on 0x4402
    return 1
```

2016 data *(data)*: `SCENARIO 8` (10×, quests 60006/60010/60011…), 12 (10×), 13 (7×) in Start/Doing scripts; 9 and 14
(5× each) in End scripts of the same job quests; 10 in the Start scripts of 40001/40008/40015/40022 (tutorial); 16…25
and 27 once each (quests 60030, 60237…60240, 60508). 11, 15 and 26 are unused.

```pseudo
ShinePlayer::so_ply_FirstJobChange() → u8 class:                                  @ FUN_0049fa70
    cls = p+0xfbc (CharClass object); next = cls.vt 0x44(); cur = cls.vt 0x38()
    if cur != next:
        → GameDB 0x1056 NC_CHAR_CLASSCHANGE_REQ { u16 p.handle, u32 charregistnumber, u8 newclass = next, u8 level = p.so_GetLevel() }
          (D02: `p_Char_ChangeClass`; the class changes when the DB answers, not here)
    return next                                                   # also when already promoted (then no DB request)

ShinePlayer::sp_ThirdPromote(questId, class):                                     @ FUN_00591de0
    if CharClassManager[class].vt 0x48() != (p+0xfbc).vt 0x48():  # different class branch
        assert "ShineObjectClass::ShinePlayer::sp_ThirdPromote : ChassChange to another brench"; return
        # no ack: the script stays on SCENARIO, not waiting, until a 0x4402 or a new script (original bug) Z15-B23
    → GameDB 0x1056 { u16 so_GetZoneHandle_ItemLooter(p), u32 charregistnumber, u8 class, u8 level }
    if class: AnnounceSystem_ClassUp(name, class)
    CQuestZone.Recv_NC_QUEST_SCRIPT_CMD_ACK({questId, 3, class != 0})          # via `so_ShineMobileObject(&p.sp_QuestDiary)`
```

Completing a scenario (end condition):

```pseudo
CQuest::QuestPlayer_ScenarioDone(scenarioId) → int   (CQuest vftable slot 0x18)   @ FUN_00630ba0
    any = 0
    for i, rec in diary (m_pQuestArray[0 … m_NumOfQuest-1]):
        if rec.Status != 6 ING: continue
        row = GetQuestData(rec.ID)
        if row and row.End.bScenario == 1 and row.End.ScenarioID == scenarioId and !(rec.Data.End_Scenario):
            rec.Data.End_Scenario = 1 (bit 1 of +0x1D); any = 1
            this.vt 0x40(rec.ID, scenarioId)                      # empty hook in the zone (§3.8)
            st = CQuest::DoingQuestUpdateStatus(i)                # part 3
            if st == 8 REWARD: this.vt 0x50(rec, row)  elif st == 7 FAILED: this.vt 0x54(rec, row)   # empty hooks
    return any
    # the flag lives in the zone's diary copy; it reaches the DB with the character save (§5)

CQuestZone::QuestPlayer_ScenarioDone_Server(scenarioId) → int:                   @ FUN_005bd750
    if !m_pPlayer: return 0
    if this.vt 0x18 QuestPlayer_ScenarioDone(scenarioId) == 0: return 1
    return Send_NC_QUEST_CLIENT_SCENARIO_DONE_ACK(scenarioId)

CQuestZone::Send_NC_QUEST_CLIENT_SCENARIO_DONE_ACK(id):                           @ FUN_005bb0c0
    → player 0x440C NC_QUEST_CLIENT_SCENARIO_DONE_ACK { u16 nScenarioID }   # client handler FUN_007283e0 (reads the id)

0x440B NC_QUEST_CLIENT_SCENARIO_DONE_REQ { u16 nScenarioID }  (zone handler @ FUN_005789f0, Z08 §3.2) →
CQuestZone::Recv_NC_QUEST_CLIENT_SCENARIO_DONE_REQ(req): if m_pPlayer: return QuestPlayer_ScenarioDone_Server(req.nScenarioID)   @ FUN_005bdad0
    # unchecked: the client can complete any scenario end condition it names (original bug) Z15-B18 (same root)
```

Other callers of `QuestPlayer_ScenarioDone_Server`: the Pine nodes `scinariocode` (`ShineScinarioCode::sa_Step`
FUN_004f39d0, `ScinarioCodeParty::sa_Step` FUN_004f7600; Z09 §26.1), every item upgrade (code 5; Z05
`gds_NC_ITEMDB_UPGRADE_ACK` / `NEW_UPGRADE_ACK` / `BRACELET_UPGRADE_ACK`) and the weapon-licence set (code 7, Z08 §7.1,
`gds_NC_WT_LICENSE_SET_ACK`).

`Send_NC_QUEST_SCENARIO_RUN_CMD(id)` FUN_005bb200 sends 0x440E `NC_QUEST_SCENARIO_RUN_CMD { u16 nScenarioID }` *(name
pdb2016)* to the player; its only caller is `QuestActionMobKill` (§6). The 2016 client registers no handler for 0x440E
(C01 `re-data/client-handlers.json`), so the packet is ignored.

`ShineMobileObject::smo_MoveByScenario` FUN_0050d520 is unrelated to quests despite the name: scripted NPC/bandit
walking (Z09 §9.5).

### 3.7 CALLPS: Pine scripts

```pseudo
CQuestZone::PsStart(fileName, blockName) → int:                                   @ FUN_005bbd00
    if !m_pPlayer or !(map = p+0x7a FieldMap): return 0
    if Movie::CinemaComplex::cc_IsDuringPlay(map.fm_Multiflex, fileName): return 0    # that film already runs on the map
    args = sprintf("%s %d %s", p.so_CharName(), p.handle, blockName)                    # 64-byte buffer
    m_ScriptIdent = FieldMap::fm_QuestPS_Start(map, fileName, args)
    return m_ScriptIdent != -1

FieldMap::fm_QuestPS_Start(fileName, args) → int:                                 @ FUN_005b9970
    tok = PineScriptToken(args)
    r = Movie::CinemaComplex::cc_PlayFilm(fm_Multiflex, fileName, &tok, &fm_MapID)     # Z09 (Pine films)
    ~tok; return r                                                                     # film id, -1 on failure

ShinePlayer::so_ply_Return2Quest(v)   (ShinePlayer vt 0x8fc)                      @ FUN_005bfa80
    CQuestZone::PsEnd(&p.sp_QuestDiary.sqd_QuestDiary, v)
CQuestZone::PsEnd(v) → int:                                                        @ FUN_005bf990
    if !m_pPlayer: return 0
    RESULT = v; QuestNext(); return 1
```

The film gets the player's name, handle and the start block as its argument line and reports back with the Pine node
`returnvalue <handle> <value>` (`ShineReturnValue::sa_Step` FUN_004f45f0, Z09 §25.6), whose value becomes RESULT.
`PsEnd` checks neither that the current command is CALLPS nor `m_ParsingQuestID` (QuestNext returns 0 without a
script). No 2016 quest script uses CALLPS (§2.8); `returnvalue` is used by the job-dungeon films, which resume a script
paused on SCENARIO (§3.6).

### 3.8 Player getters and the `CQuestZone` vftable

`CQuest` is the shared library class; `CQuestZone` overrides only the player accessors (vftable recovered from RTTI, `rtti.py`):

| Slot | `CQuestZone` vftable entry | Notes |
|---|---|---|
| 0x00 | empty `ret 4` (folded) | |
| 0x04…0x24 | `CQuest::QuestPlayer_LevelChange` 0062fa20, `_NPCMobKill` 006306d0, `_TakeItem` 00630810, `_DestroyItem` 00630920, `_CheckLocation` 00630a60, `_ScenarioDone` 00630ba0, `_RaceChange` 00630c90, `_ClassChange` 00630d70, `_TimeProcess` 00630e50 | events, part 3 |
| 0x28 | `CQuest::IsQuestArea` 0062fab0 | part 3 |
| 0x2c…0x5c | empty stubs (`ret 0x10` / `ret 0xc` / `ret 8`, folded) | status-change hooks the zone does not implement (0x40 scenario done, 0x50 → REWARD, 0x54 → FAILED, …) |
| 0x60 | `GetPlayerCurrentLocation` 005ba3c0 | |
| 0x64 | `GetQuestPlayerLevel` 005b9be0 | |
| 0x68 | `GetQuestPlayerItemLot` 005ba4e0 | |
| 0x6c / 0x70 / 0x74 / 0x78 | `GetQuestPlayerRace` 005b9c00 / `Class` 005b9c20 / `Gender` 005b9c50 / `EmptyInventory` 005ba680 | |
| 0x7c | `IsQuestPlayerItemLock` 005b9c70 | |
| 0x80 | `CQuest::IsSoonableDailyQuest` 00630130 | part 3 |

```pseudo
(every getter: no player → 0, IsQuestPlayerItemLock → 1)
GetQuestPlayerLevel() → u8:   p.vt 0x4d8 so_GetLevel()                                          @ FUN_005b9be0
GetQuestPlayerRace() → u8:    p.sp_CharData.toclient.shape.race                                 @ FUN_005b9c00
GetQuestPlayerClass() → u8:   p.vt 0x49c so_CharacterClass().vt 0x38()  (current class id)      @ FUN_005b9c20
GetQuestPlayerGender() → u8:  p.vt 0x804 so_ply_GetGender()                                     @ FUN_005b9c50
GetQuestPlayerItemLot(itemId) → u16:                                                            @ FUN_005ba4e0
    sum of the lots (item.vt 0x1c) of every unlocked inventory cell holding itemId
    (ItemBoxIterIdent over p.vt 0x47c so_ItemInventory()+0xe54, UnlockedInventoryIterator with the lock list
    vt 0x7d4, inventory type 9); u16 (wraps above 65535)
GetQuestPlayerEmptyInventory() → u8:                                                            @ FUN_005ba680
    number of empty unlocked inventory cells (ItemBoxIterEmpty with the charged-effect bag expansions, vt 0x498)
IsQuestPlayerItemLock(itemId) → u8:                                                             @ FUN_005b9c70
    1 when no unlocked inventory cell holds itemId (none at all, or all of them locked)
GetPlayerCurrentLocation(&mapIdx, &x, &y):                                                      @ FUN_005ba3c0
    mapIdx = mapdatabox.mdb_btree[first 12 chars of the player's map name] (0xFFFF unknown); x, y = p position
GetSuccessItemCount(row, itemId) → int:                                                         @ FUN_005ba800
    sum of row.End.ItemList[i].ItemLot over the 5 entries with bItem == 1 and ItemID == itemId   # used by §6
IsConnectionEnd(row, i, mobId) → int:                                                           @ FUN_005b9af0
    raid member (p.vt 0xa84 so_GetRaid() != 0) needs row.Type == 8 RAID, a non-member needs Type != 8
    then End.NPCMobList[i] has bNPCMob 1, NPCMobAction 1 KILL and
    MobDataBox::mdb_IsSpeciesDistanceByQuest(NPCMobID, mobId, TargetGroup) (FUN_00641020, §6)
IsConnectionAction(row, i, mobId) → int:                                                        @ FUN_005b9b60
    same raid rule; Action[i].IfType == 1 MOB_KILL and mdb_IsSpeciesDistanceByQuest(IfTarget, mobId, TargetGroup)

CQuestZone::InitNewPlayer():                                                       @ FUN_005b9d40
    if !m_pQuestData: assert "CQuestZone::InitNewPlayer : m_pQuestData NULL"; m_pQuestData = &gQuestData
    CQuest::InitQuestBF(number of quests in the table (head.NumOfQuest, 0 without data)); CQuest::ClearQuest()   # part 3
    m_bWaitResult = 0; m_QuestClickNPC = 0xFFFF; m_ParsingQuestID = 0xFFFF
    # callers: so_FirstActionAfterSocketConnect FUN_00554870 (player enters the zone) and
    # wms_NC_CHAR_ZONE_CHARTITLE_CMD FUN_005a39f0
```

### 3.9 Worked trace

Quest 24, End script (§2.8), player with 1 free cell, reward needs 2:

1. NPC click → `QuestScriptRun(8 REWARD)` → `QuestEnd` → `QuestNext`: `SAY 2455 ME` → 0x4401 Cmd 2, wait.
2. 0x4402 `{24, 2, n}` → RESULT = n → `GET_PLAYER_EMPTY_INVENTORY VAR1` (VAR1 = 1) → `IF VAR1 < 2` true →
   `GOTO MARK100` → `SAY 106 NPC` → 0x4401, wait.
3. 0x4402 → `END` → `QuestClose`, `sp_EndOfTrade`; nothing is sent; the client closes its dialog itself
   *(inferred)*.

With 2 free cells step 2 runs `DONE` → (reward checks, §5) 0x441A, pause; 0x441B → `QuestNext` → `SAY 2457 NPC`; the
answer 1 runs `GOTO MARK1`, which does not exist: script closed as ERROR without any packet (Z15-B14).

### 3.10 Script error codes (0x4401 `Cmd 0`, `Data.ErrCode`)

Client texts from 2016 `On_NC_QUEST_SCRIPT_CMD_REQ` (TextData; `<%s>` = quest name). Codes without a text only close
the dialog. Part 5 (§7) adds the non-script quest codes 0xB41…0xB5A.

| Code | Raised by | Client text |
|---|---|---|
| 0xC00 | CLEAR_ACK: quest id mismatch or DB error (§3.5) | "<%s> an unknown error has occurred." |
| 0xC01 | DONE: `QuestCheckReward` failed or 0x441A not sent (§3.3, §5; part 4 adds the other reward-path callers) | "Inventory full. Cannot receive the reward item." |
| 0xC02 | ACCEPT: no quest row | (none) |
| 0xC03 | ACCEPT: start conditions not met | "<%s> ths quest is not proceedable." |
| 0xC04 | CANCEL: no diary record / row | "<%s> an unknown error has occurred while Giving Up the quest." |
| 0xC05 | PROGRESS: no record | "… while Proceeding the quest." |
| 0xC06 | FAILED: no record | "… while Failing the quest." |
| 0xC07 | DONE: no record | "… while Completing the quest." |
| 0xC08 | DONE: end conditions not met | "<%s> Quest complete condition(s) is(are) not met." |
| 0xC09 | ABORT: no record | "<%s> unverified quest (when aborting permanently)" |
| 0xC0A | DELETE_ITEM failed | "<%s> Error. Failed to delete quest item." |
| 0xC0B | CREATE_ITEM: unknown item | "<%s> Error. Failed to create quest item." |
| 0xC0C | 0x4402 for another quest or command | "<%s> a lag or an unknown error occurred during proceeding the quest." |
| 0xC0D | 0x4402 for a command that takes no answer | "<%s> internal command error occurred during proceeding the quest." |
| 0xC0E | DB answer 0x4404 / 0x441B with an error (Z08 §3.3, parts 3–4) | "<%s> DB writing error occurred during proceeding the quest." |
| 0xC0F | ACCEPT: 40 quests in progress | "Cannot accept 40 or more quests at once." (`fs(text, 0x28)`) |
| 0xC10 | CALLPS: film already running / not started | (none) |

---

<!-- Parts 3–5 add: §4 diary, conditions and repeat resets,
§5 the reward path, §6 other entry points, §7 quest error numbers. The sweep adds the bugs table, uncertain list and
coverage boundary. -->

## Original-server bugs (collected so far; the sweep part numbers this section)

| ID | Handler | 2016 behaviour | Effect | Likely intent |
|---|---|---|---|---|
| Z15-B1 | `GetScriptVariableValue` FUN_006370a0 | case `QSV_PROGRESS` stores the diary progress step and then falls through into the CONSTANT case, overwriting it with the operand's parse-time value | `IF PROGESS …` never sees the quest's progress step; it sees `m_Var[6]` (or fails when there is no diary record) | `break` after storing `ProgressStep` |
| Z15-B2 | `CQuestParserScript` (parser+0x838) | `m_pQuest` is never assigned (no constructor init, no store anywhere) | the PROGESS lookup calls `CQuest::GetQuestInfo` on an unset pointer: a crash if it is NULL, garbage otherwise *(inferred)*; latent, no 2016 script uses PROGESS | set `m_pQuest = this` (the owning `CQuestZone`) when the parser is constructed |
| Z15-B3 | `ParserNext` IF FUN_006387f0 | a right operand found in `QuestParser.txt` is stored into `VarID1`/`Value1` | the left operand is replaced by the name's id, the right operand is stale; latent (no 2016 script uses names) | store into `VarID2`/`Value2` |
| Z15-B4 | keyword table `gpQSV` | variable 6 is spelled `PROGESS` | scripts must use the misspelling; `PROGRESS` as a variable is a parse error that refuses the whole script | `PROGRESS` |
| Z15-B5 | `ParserNext` DELETE_ITEM | a non-numeric item id is reported with `ErrCmd = CREATE_ITEM` | wrong command in the error record (only counted by `ParserStart`) | `ErrCmd = DELETE_ITEM` |
| Z15-B6 | `CQuestData::ReadModeRead` FUN_00636b90 | script pointers start at record + 0x2AC instead of + 0x2A8 | in read-only mode every script loses 4 characters and the End script overruns into the next record; unused by the zone (it loads in edit mode) | + 0x2A8 |
| Z15-B7 | `LoadConvertIDfromIndexName` FUN_00639c90 | an empty line returns false | a blank line in `QuestParser.txt` (e.g. a trailing empty line) stops the zone at start-up | skip empty lines |
| Z15-B8 | `MarkAdd` / `MarkGo` | labels are stored truncated to 15 bytes, `GOTO` compares the full name | a `GOTO` to a label of 16+ characters fails at run time; latent (longest 2016 label 15) | compare with the same limit, or refuse long labels when parsing |
| Z15-B9 | `Send_NC_QUEST_DB_CLEAR_REQ` FUN_005babd0 | sends 0x4405 only if the u32 at offset 4 of the shared send buffer (left from the previous packet) is non-zero | CLEAR / CANCEL of a non-repeatable quest randomly sends nothing while `m_bWaitResult` is 1: the script hangs | test the char number (or nothing) |
| Z15-B10 | `Send_QUEST_ERROR_TO_CLIENT` FUN_005bd870 | builds the error `STRUCT_QSC` on the stack and writes only Cmd, IsPigeonStartType, ErrCmd, pErrStr, ErrCode | 86 uninitialised stack bytes in every 0x4401 error packet | zero the struct |
| Z15-B11 | `Send_NC_QUEST_SCRIPT_CMD_REQ` FUN_005ba960 | copies the whole parser `m_QSC` (0x65 bytes) | stale `Data` bytes of earlier commands go to the client, including heap pointers (labels, abstate names) | send only the command's fields / clear `Data` per command |
| Z15-B12 | `QuestNext` FUN_005bdef0 | `END` is tested at the loop head and closes the script before the switch; the switch's `QSC_END` case (send to client) is dead | the client never receives `Cmd 1`, whose handler closes the NPC dialog | execute the END case (send, then close) |
| Z15-B13 | `QuestNext` | an `IF` whose variable cannot be read (`CommandRun` 0) falls into the switch default | the following command (the GOTO) runs as if the condition were true | treat a failed condition as false (skip), or stop with an error |
| Z15-B14 | `QuestNext` | a failed GOTO / SET / ADD / SUB becomes `Cmd = ERROR` and the script closes without `Send_QUEST_ERROR_TO_CLIENT` | no message and no dialog close on the client; hit by the 21 GOTOs to missing labels of the 2016 data | send an error (e.g. 0xC0D) |
| Z15-B15 | `QuestNext` ACCEPT | sends 0x4403 without setting `m_bWaitResult` (CANCEL, PROGRESS, FAILED, ABORT set it) | `QuestNext` / 0x4414 are not blocked while the DB answer is pending | set `m_bWaitResult = 1` |
| Z15-B16 | CLEAR, CANCEL (non-repeatable) / `Recv_NC_QUEST_DB_CLEAR_ACK` FUN_005bf640 | the DB record is deleted but neither the zone diary nor the client (no 0x4401 Cmd 5/7) is updated | zone and client keep the quest until the next login; latent in 2016 (CLEAR unused, CANCEL unreachable) | remove the record and notify the client in the CLEAR_ACK |
| Z15-B17 | `Recv_NC_QUEST_DB_CLEAR_ACK` | on an error answer sends 0xC00 but leaves `m_bWaitResult` 1 and the script open | the player cannot use 0x4414 start until another script replaces this one | clear the flag and `QuestClose` |
| Z15-B18 | `Recv_NC_QUEST_SCRIPT_CMD_ACK` FUN_005bf0d0, 0x440B `Recv_NC_QUEST_CLIENT_SCENARIO_DONE_REQ` FUN_005bdad0 | a client 0x4402 `{quest, 3, ≠0}` is accepted for every pending SCENARIO, also the server-resolved ones; 0x440B completes any scenario id the client names | a client can check off a quest's scenario end condition (job dungeon) without doing it *(effect inferred)* | accept the ack only for scenarios sent to the client while `m_bWaitResult`; validate 0x440B |
| Z15-B19 | `Recv_NC_QUEST_SCRIPT_CMD_ACK` | quest/command mismatch → 0xC0C without `QuestClose` (0xC0D closes) | the server keeps a script the client has closed | close as for 0xC0D |
| Z15-B20 | `Recv_NC_QUEST_SCRIPT_CMD_ACK` | case LINK calls `QuestStart` and not `QuestNext`; LINK never waits for the client | dead branch; if reached it would open a script without running it | remove, or run it |
| Z15-B21 | `QuestNext` CREATE_ITEM / `sp_MakeItem` FUN_00528930 | success means only "item id exists"; the inner `sp_MakeItem` result (no free cell → nothing) is ignored | with a full inventory the item is silently not given | report 0xC0B (or check room) |
| Z15-B22 | `QuestNext` SET/RESET/IS_ABSTATE | copies the name token into a 128-byte stack buffer without a length check | stack overflow with a long name in a script file; latent (data) | bounded copy |
| Z15-B23 | `sp_ThirdPromote` FUN_00591de0 | class of another branch: assert only, no ack | the script stays on SCENARIO without a wait and never resumes | answer the ack with result 0 |

## Not reconstructed / uncertain (so far)

- Whether the `CQuestZone` objects are zero-filled when the player pool is allocated (decides whether Z15-B2 crashes
  or reads garbage).
- `IS_ABSTATE` always writes RESULT (§3.3); its 2016-struct target variable is unused by parser and interpreter.
- Where the 2016 client starts a client-side SCENARIO (Cmd 3 has no case in `On_NC_QUEST_SCRIPT_CMD_REQ` FUN_004ba970;
  `ScenarioMgr::RunScenario` FUN_006b00b0 is reached from FUN_0047b7c0 (a chat command) and the dialog parser
  FUN_005f80f0): not traced; and what scenario 15 (server: no packet, no wait) does on the client (`Scenario_15`).
- `ZoneRingPacketFindJobDungeon::zrpb_Request` and when it returns `nResult 2` synchronously: Z14.
- Whether the client closes its NPC dialog by itself after the last SAY (the server never sends END, Z15-B12).
