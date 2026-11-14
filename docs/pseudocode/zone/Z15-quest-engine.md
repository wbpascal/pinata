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
parsing the next command (§3) *(inferred from the call order; verify in part 2)*.

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

<!-- Parts 2–4 add: §3 the interpreter (QuestNext and every action command), §4 diary, conditions and repeat resets,
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

## Not reconstructed / uncertain (so far)

- Whether the `CQuestZone` objects are zero-filled when the player pool is allocated (decides whether Z15-B2 crashes
  or reads garbage).
- `IS_ABSTATE`'s target variable is not parsed; its run-time behaviour is part of §3.
