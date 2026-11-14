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

Log object: a static initializer creates a log list named `QuestLog` (`EraseOldLogList("QuestLog")`, FUN_0069b150; destructor
FUN_006a06b0), but no 2016 zone function writes to it; the quest error lines (e.g. "QUEST UN-DRIVED COMMAND" in
`Recv_NC_QUEST_SCRIPT_CMD_ACK`, time from `GetCurrentTimeString` FUN_0064f050) go to `_DebugMessageNew(1, "Msg", …)`.

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
entries: IfType 1 MOB_KILL / 2 GATHER, ThenType always 1 DROP_ITEM; the 18 GATHER entries, in quests 20005 and 20006
(IfTarget 5100 "Flower", DROP_ITEM 3486 at 1 %, count 1), never fire: the zone tests only IfType 1, §3.8, Z15-B46). Rewards: EXP / MONEY primary in almost every
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
CQuestZone::CQuestZone(questData): CQuest::CQuest(questData); parser ctor; m_pPlayer = NULL; m_QuestRestTime = 0 (4 × i32, §4.4)   @ FUN_005b9a00
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
| `m_bWaitResult` (+0x900) | SAY, CLEAR, CANCEL, PROGRESS, FAILED, ABORT, a client SCENARIO (§3.6), DONE (inside `Send_NC_QUEST_DB_DONE_REQ`, §5.2); **not** ACCEPT, CALLPS, server SCENARIOs (Z15-B15) | every 0x4402 (§3.4), `Recv_NC_QUEST_DB_SET_INFO_ACK` (Z08 §3.3), `Recv_NC_QUEST_DB_CLEAR_ACK` success (§3.5), `Recv_NC_QUEST_DB_DONE_ACK` success (§5), `QuestStart/Doing/End`, `QuestClose`, `InitNewPlayer` |
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
    12: "Job2_Dn01", "Promote/Job2_Gamb/Job2_Gamb"                         │ (FUN_005a8d30, Z14): finds or creates the instance in any zone;
    13: "Job2_Dn02", "Promote/Job2_Forest/Job2_Forest"                     ┘ if it returns with ack.nResult == 2: Recv_NC_QUEST_SCRIPT_CMD_ACK(&ack)
        # otherwise the answer comes later through the zone ring 0x441F (zls_NC_QUEST_JOBDUNGEON_FIND_RNG FUN_005bfde0,
        # Z14): player in a mode outside cmc_AllowMode 0x46 → so_SendErrorCode (vt 0x308) 0x4420
        # NC_QUEST_JOBDUNGEON_LINK_FAIL_CMD { u16 nError = 0x30C2 } (its only sender; client FUN_004b4430 shows text
        # 0x7aafcf08 "You cannot teleport to the saved locaion in current state." for 0x30C2 only) and ack nResult 2; dungeon found (0x30C0)
        # → the player is sent to it (p.vt 0x600) and no ack (the dungeon's Pine script finishes the quest step:
        # `scinariocode` → ScenarioDone_Server, `returnvalue` → PsEnd, Z09 §26.1 / §25.6); not found → ack nResult 0
    9, 14: c = p.vt 0x3d4 so_ply_FirstJobChange()                 # below
           if c: CAnnounceSystem::AnnounceSystem_ClassUp(&gAnnounceSystem, p.so_CharName(), c)   # FUN_005b9030: below
           ack.nResult = (c != 0); Recv_NC_QUEST_SCRIPT_CMD_ACK(&ack)          # synchronous: the script continues at once
    15: nothing (no packet, no wait)                              # the client has a `Scenario_15` class (FUN_006b0400)
                                                                  # *(inferred: a client-side step answered with 0x4402)*
    16→class 4, 17→5, 18→10, 19→9, 20→15, 21→14, 22→19, 23→20, 24→24, 25→25, 27→27:
        ShinePlayer::sp_ThirdPromote(p, questId, class)          # below; acks synchronously
    other (incl. 10, 26):                                         # client scenarios
        m_bWaitResult = 1; Send_NC_QUEST_SCRIPT_CMD_REQ(m_ParsingQuestID, m_pQSC)   # 0x4401 Cmd 3; resumes on 0x4402
    return 1
ZoneRingPacketFindJobDungeon::zrpb_Request(p, map, film, ack) (Z14 owns the ring transport)    @ FUN_005a8d30
    if any argument NULL: return                                  # no ack (server SCENARIO: no wait flag, §3.1): stuck
    if (1 << p.smo_GetMode() (vt 0x484)) & 0x46 == 0:             # static cmc_AllowMode 0x46 = modes 1, 2, 6
        p.so_SendErrorCode(0x11, 0x20, 0x30C2) → 0x4420 NC_QUEST_JOBDUNGEON_LINK_FAIL_CMD { nError 0x30C2 }; ack.nResult = 2
        return                                                    # the caller then runs Recv_NC_QUEST_SCRIPT_CMD_ACK
    if !p.so_ply_IsLink_OutMap_AndSendErrorMsg() (vt 0xa74): return   # no ack, script stuck (original bug) Z15-B45
    if map = cm_FindEmpty(map) in this zone: p.so_ply_2JobDungeon(map, film) (vt 0x3d0, Z09 §27 / Z14)   # no ack
    else: zone ring 0x441F { u8 zoneNo, u16 handle, u32 charRegNo, u16 0x30C1, char map[33] +0xB, mapId[33] +0x2C = 0,
                             char film[33] +0x4D, ack (7 bytes) +0x6E }  (0x75 bytes)  → the other zones answer 0x441F
                             through zls_NC_QUEST_JOBDUNGEON_FIND_RNG FUN_005bfde0 (code 0x30C0 found / other: not found)
ShinePlayer::so_ply_IsLink_OutMap_AndSendErrorMsg() → bool:                      @ FUN_005603d0
    if !so_Field: return 0
    attr = so_Field.fm_FieldOption (FieldOption::FieldAttr, FieldAttribute data)
    if !attr.LinkOut (+0x6c): so_SendErrorCode(6, 0x1D, 0x1E42) → 0x181D NC_MAP_LINK_FAIL_CMD; return 0   # map forbids links out
    if attr.SystemMap (+0x6d) == 1: so_SendErrorCode(6, 0x1D, 0x1E41); return 0                       # system map
    return 1
    # client On_NC_MAP_LINK_FAIL_CMD FUN_004b0e70: for 0x1E41 / 0x1E42 adds system message TextData2 0x35ac8487,
    # whose 2016 text is a single blank: the player sees no reason
CAnnounceSystem::AnnounceSystem_ClassUp(name, class) → int:                         @ FUN_005b9030
    if AnnounceData.shn has ≤ 5 rows: return 0                     # row 5 = "\"%s\" has just become level %s. Congratulations!"
    text = sprintf(row5.Message, name, ClassName.shn[class] name)   # the "level %s" wording is the shipped text
    Send_PROTO_NC_ANNOUNCE_Z2W_CMD(type 5, text) @ FUN_005b8d30 → WM 0x6401 (W01: re-broadcast to the world); return 1
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
    # the only IfType test in the zone (QuestActionMobKill and IsQuestDropItem read ThenType only): IfType 2 GATHER,
    # 3 TOUCH_OBJECT, 4 AREAINFO actions never fire (original bug) Z15-B46; 18 GATHER entries in 2016 (§1.2)

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
the dialog. The non-script quest codes 0xB41…0xB5A are §7.

| Code | Raised by | Client text |
|---|---|---|
| 0xC00 | CLEAR_ACK: quest id mismatch or DB error (§3.5) | "<%s> an unknown error has occurred." |
| 0xC01 | DONE only: `QuestCheckReward` failed (no room), or `Send_NC_QUEST_DB_DONE_REQ` returned 0: a reward already pending, an item lock open, no row / record / title object (§3.3, §5.2, Z15-B37) | "Inventory full. Cannot receive the reward item." |
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
| 0xC0E | DB answer with an error: 0x4404 (also an unknown nQSC, §4.7), 0x441B (§5.3), 0x345C (dead path, §5.5) | "<%s> DB writing error occurred during proceeding the quest." |
| 0xC0F | ACCEPT: 40 quests in progress | "Cannot accept 40 or more quests at once." (`fs(text, 0x28)`) |
| 0xC10 | CALLPS: film already running / not started | (none) |

---

## 4. The diary (`CQuest`), quest conditions and repeat resets

`CQuest` is the shared quest library (the 2016 client runs the same code, client FUN_00727ab0…FUN_007298e0, names in
`names/client/C02.json`; checked for `IsQuestArea` and `QuestPlayer_TimeProcess`, identical bugs). The zone uses it
through `CQuestZone` (§2.1, vftable §3.8). This section corrects Z08 §3.1's helper names: `Diary_Find` = `GetQuestInfo`,
`Diary_Store` = `AddQuestInfo`, `Diary_Touch` = `SetQuestInfoClearRepeat`, `Diary_Count` = `GetNumOfDoingQuest`.

### 4.1 Members and the diary array

| `CQuest+` | Member *(pdb2016)* | Meaning |
|---|---|---|
| +0x00 | vftable | `CQuestZone` vftable in the zone (§3.8) |
| +0x04 | `CQuestData *m_pQuestData` | → `gQuestData` (§1) |
| +0x08 | int `m_NumOfQuest` | used diary entries |
| +0x0C | int `m_NumOfQuestBF` | capacity (entries allocated) |
| +0x10 | `PLAYER_QUEST_INFO *m_pQuestArray` | the diary: unsorted array of 0x20-byte records, searched linearly by ID |
| +0x14 | long `m_ProcessedTime` | `_time32` of the last `QuestPlayer_TimeProcess` pass (§4.5) |
| +0x18 / +0x1C / +0x20 | `m_MaxOfQuestListWithNPC`, `m_NumOfQuestListWithNPC`, `NPC_QUEST_STATUS *m_pQuestListWithNPC` | client-side NPC quest list (`GetQuestListWithNPC`, client FUN_007298e0); the zone never fills it (0 / NULL from the constructor, freed by the destructor) |
| +0x24 | u32 `m_QuestStatusPriority[21]` | rank of a status for the NPC choice (§4.4), lower wins |
| +0x78 | u32 `m_QuestTypePriority[11]` | rank of a `QUEST_TYPE` for the NPC choice, lower wins |
| +0xA4 | `PROTO_NC_QUEST_RESET_TIME_CMD m_QuestRestTime` | period starts from the WM (Z08 §3.4, W05 §2.3) |

`PLAYER_QUEST_INFO` (0x20) *(pdb2016)*: +0 u16 `ID`, +2 u8 `Status` (`PLAYER_QUEST_STATUS`, Z08 §3.1), +3
`PLAYER_QUEST_DATA Data` (0x1D): +0 i64 `StartTime`, +8 i64 `EndTime`, +0x10 u32 `RepeatCount`, +0x14 u8
`ProgressStep` (the script's `PROGRESS` value), +0x15 u8 `End_NPCMobCount[5]` (counters for `End.NPCMobList[i]`), +0x1A
bit 0 `End_Location`, bit 1 `End_Scenario`, +0x1B u16 `End_RunningTimeSec`. (Record offsets: Status +2, counts +0x18,
flags +0x1D, running time +0x1E.)

```pseudo
CQuest::CQuest(questData):                                                          @ FUN_006301d0
    m_pQuestData = questData; m_NumOfQuest = 0; m_ProcessedTime = _time32(); m_NumOfQuestBF = 0; m_pQuestArray = NULL
    m_Max/NumOfQuestListWithNPC = 0; m_pQuestListWithNPC = NULL          # m_QuestRestTime: CQuestZone ctor (§2.1)
    m_QuestStatusPriority: 8 REWARD 0, 6 ING 1, 5 ABLE / 7 FAILED / 20 READ_ABLE 2, 0 NONE 0x16, every other 0x15
    m_QuestTypePriority:   3 EVENT 0, 2 CLASS 1, 6 EPIC / 7 EPIC_PARTY / 8 RAID 2, 5 NORMAL_PARTY 3, 9 CHAO_QUEST 4,
                           0 NORMAL 5, 1 STORY / 4 INSTANCE_DUNGEON / 10 DAILY_QUEST 0xB
CQuest::~CQuest(): free(m_pQuestArray); delete[] m_pQuestListWithNPC; counters 0                @ FUN_0062f0f0

# the per-player object: ShinePlayer.sp_QuestDiary (p + 0x173e8, reached through vt 0x808 so_ply_QuestDiary   @ FUN_0055a270)
ShineQuestDiary::ShineQuestDiary(): CQuestZone::CQuestZone(&sqd_QuestDiary, &gQuestData)   @ FUN_00578040
ShineQuestDiary::~ShineQuestDiary() / CQuestZone::~CQuestZone(): vftable = CQuestZone; ~CQuestParserScript(m_ScriptParser);
    ~CQuest()                                                                       @ FUN_00578060 / FUN_005b9a80
# The diary lives as long as the ShinePlayer object (pool object, §4.1 capacity); InitNewPlayer (§3.8) resets it per login.

CQuest::InitQuestBF(n) → int:                                                       @ FUN_0062f130
    if m_NumOfQuestBF < n: free(m_pQuestArray); m_pQuestArray = NULL; m_NumOfQuestBF = 0
    if !m_pQuestArray: m_pQuestArray = malloc(n·0x20) zero-filled (fail → m_NumOfQuest = 0; return 0); m_NumOfQuestBF = n
    m_NumOfQuest = 0; return 1
CQuest::ClearQuest(): m_NumOfQuest = 0; m_ProcessedTime = _time32()                    @ FUN_0062f1b0
```

Capacity: `ZoneServer_zs_start_sink` FUN_005aeff0 asserts "Too Many Quest (MAXQUEST …)" and exits when the table has
more than 3000 quests, then calls `InitQuestBF(NumOfQuest)` for each of the 1500 player objects of the object pool
(indexes 0…0x5DB; "Fail to player quest bf alloc" + exit on a failed malloc); `InitNewPlayer` (§3.8) repeats it per
login. The diary therefore has room for **one record per quest in the table** (2306 in 2016 *(data)*), so the
"diary full" branches below (`AddQuestInfo`, `SetQuestAccept`) cannot be reached. The only count limit is the 40
quests in progress of §4.3.

```pseudo
GetQuestIndex(id) → int:        index of the record with ID == id, -1 if none (also -1 when m_NumOfQuestBF == 0)   @ FUN_0062f1d0
GetQuestInfo(id) → rec*:        the record or NULL                                                               @ FUN_0062f210
GetQuestInfoByIndex(i) → rec*:  m_pQuestArray + i for 0 <= i < m_NumOfQuest, else NULL                          @ FUN_0062f260
SetQuestInfo(info) → int:       overwrite the record with info.ID by *info (32 bytes); 0 if none                @ FUN_0062f280
AddQuestInfo(info) → int:       SetQuestInfo, else append if m_NumOfQuest < m_NumOfQuestBF (else return 0); 1   @ FUN_0062f2e0
SetQuestInfoClearRepeat(rec):   if rec: ProgressStep = 0, End_NPCMobCount[0…4] = 0, End_Location = End_Scenario = 0,
                                End_RunningTimeSec = 0     (StartTime, EndTime, RepeatCount, Status kept)    @ FUN_0062f320
SetQuestClear(id):              remove the record (memcpy of the tail one slot down; overlapping copy, works with
                                the CRT's forward memcpy); m_NumOfQuest -= 1                                    @ FUN_0062f350
GetNumOfDoingQuest() → int:     number of records with Status 6 ING, 7 FAILED or 8 REWARD                       @ FUN_0062fb10
```

### 4.2 Loading the diary at login (WM 0x1021 / 0x1022 / 0x10CD / 0x10D6)

The WM sends the character's quest lists when the player enters the map (Z07 §1.2: `wms_NC_CHAR_ZONE_QUEST_DOING_CMD`
FUN_0044af80, `…_DONE_CMD` FUN_0044b090, `…_READ_CMD` FUN_0044b1a0, `…_REPEAT_CMD` FUN_0044b2b0 find the player and call
ShinePlayer vt 0x67c…0x688); `so_StoreQuestDoing/Done/Read/Repeat` (0044b3c0…, §5.7) hand them to these four functions. Each record is merged with `SetQuestInfo`-or-append
semantics (inlined); the return value is 1 when every record found a place.

```pseudo
CQuest::Recv_NC_CHAR_QUEST_DOING_CMD_ACK(cmd {u32 chrregnum, u8 bNeedClear, u8 nNumOfDoingQuest,
                                         PLAYER_QUEST_INFO QuestDoingArray[]}) → int:   @ FUN_0062f6e0
    if bNeedClear: m_NumOfQuest = 0; m_ProcessedTime = _time32()        # first packet of a login
    for each of the n records: store it as is (32 bytes, Status from the DB)
CQuest::Recv_NC_CHAR_QUEST_REPEAT_CMD_ACK(cmd {u32 chrregnum, u16 nNumOfRepeatQuest,
                                          PLAYER_QUEST_INFO QuestRepeatArray[]}) → int: @ FUN_0062f960
    for each record: store it as is
CQuest::Recv_NC_CHAR_QUEST_DONE_CMD_ACK(cmd {u32 chrregnum, u16 nTotalDoneQuest, nTotalDoneQuestSize, nDoneQuestCount,
                                        nIndex, PLAYER_QUEST_DONE_INFO QuestDoneArray[] {u16 ID, i64 tEndTime}}) → int:   @ FUN_0062f7c0
    for each entry: store { ID, Status = 2 DONE, Data.EndTime = tEndTime }
CQuest::Recv_NC_CHAR_QUEST_READ_CMD_ACK(cmd {u32 chrregnum, u16 nNumOfReadQuest, u16 QuestReadIDArray[]}) → int:   @ FUN_0062f890
    for each id: store { ID = id, Status = 20 READ_ABLE }
```

The DONE and READ records are built in one stack buffer of which only `ID`, `Status` (and `EndTime`) are written: the
rest of `Data` (`StartTime`, `RepeatCount`, `ProgressStep`, counters, flags, running time) is whatever the stack held
(original bug) Z15-B31. For READ records this is harmless (`SetQuestAccept` zeroes a READ_ABLE record), but a DONE
record that is accepted again (a daily quest after its reset, §4.6) keeps its garbage `StartTime` and `RepeatCount`:
`QuestNext` ACCEPT copies the record into the 0x4403 request (§3.3) and the Character server stores it (D04 §1.2).

### 4.3 Status changes after a DB answer

`Recv_NC_QUEST_DB_SET_INFO_ACK` (§4.7) applies the change only after the Character server confirmed it; it uses only
`QuestInfo.ID` from the answer and recomputes the record locally:

```pseudo
CQuest::SetQuestAccept(id) → int:                                                   @ FUN_0062f3b0
    if !GetQuestData(id): return 0
    rec = GetQuestInfo(id)
    if rec:
        old = rec.Status; rec.Status = 6 ING
        if old == 20 READ_ABLE: rec.Data = 0 except StartTime = _time64()      # a fresh start
        else: SetQuestInfoClearRepeat(rec)                                       # e.g. 4 REPEAT, 2 DONE (daily): StartTime,
                                                                                 # EndTime, RepeatCount kept
        return 1
    if m_NumOfQuest >= m_NumOfQuestBF: return 0
    append { ID = id, Status = 6, Data = 0 except StartTime = _time64() }; return 1
CQuest::SetQuestCancel(id) → int:                                                   @ FUN_0062f4b0
    rec, row required (else 0)
    if row.Repeatable: rec.Status = 4 REPEAT; SetQuestInfoClearRepeat(rec)
    else: SetQuestClear(id)                                                      # record removed
    return 1
CQuest::SetQuestProgress(id, step) → int: rec.Data.ProgressStep = step              @ FUN_0062f550
CQuest::SetQuestFailed(id) → int:         rec.Status = 7 FAILED                     @ FUN_0062f5b0
CQuest::SetQuestAbort(id) → int:          rec.Status = 1 ABORT                      @ FUN_0062f680
CQuest::SetQuestDone(id) → int:  SetQuestDone(GetQuestInfo(id))  (NULL → 0)          @ FUN_006302b0
CQuest::SetQuestDone(rec) → int:                                                    @ FUN_0062f610
    if !rec or !GetQuestData(rec.ID): return 0
    rec.Status = row.Repeatable ? 4 REPEAT : 2 DONE
    rec.Data.RepeatCount += 1; rec.Data.EndTime = _time64()
    this.vt 0x5c(rec, row)                                                       # empty hook in the zone (§3.8)
    return 1
```

`SetQuestDone` is called from the SET_INFO_ACK (`nQSC 10`, unreachable, §4.7) and from the reward path
(`Send_NC_QUEST_DB_DONE_REQ`, `Recv_NC_QUEST_DB_DONE_ACK`, `Recv_NC_ITEMDB_QUESTREWARD_ACK`: §5). Note the
ProgressStep / counters are not cleared on DONE; the next ACCEPT clears them.

### 4.4 Quest conditions and the computed status

The stored `Status` is only a base: what a quest "is" for the player right now is computed by `GetNewQuestStatus`
from the stored status and the quest's start / end conditions (`QUEST_DATA` §1.2). Player values come from the
`CQuestZone` getters (§3.8): level vt 0x64, item lot vt 0x68 (`GetQuestPlayerItemLot`, unlocked cells only), race 0x6c,
class 0x70, gender 0x74, item lock 0x7c, location 0x60, area test 0x28.

```pseudo
CQuest::IsSoonableQuest(row) → int:      "the quest can be shown as coming soon"    @ FUN_0062fc80
    if Start.bLevel and !(Start.LevelMin <= (u8)(level + 5) and level <= Start.LevelMax): return 0   # 5 levels early
    if Start.bItem and GetQuestPlayerItemLot(Start.ItemID) < Start.ItemLot: return 0
    if Start.bLocation:
        GetPlayerCurrentLocation(&map, &x, &y)
        if map != Start.Location or !IsQuestArea(x, y, Start.LocationX, Start.LocationY, Start.LocationRange): return 0
    if Start.bQuest:                                                             # prerequisite quest
        pre = GetQuestInfo(Start.QuestID); if !pre: return 0
        if pre.Status == 2 DONE: if IsSoonableDailyQuest(pre) == 1: return 0   # a daily prerequisite counts only in the
                                                                                 # period it was done in (2 quests, data)
        elif pre.Status != 4 REPEAT: return 0
    if Start.bRace and race != Start.Race: return 0
    if Start.bClass and class != Start.Class: return 0
    if Start.bGender and gender != Start.Gender: return 0
    if Start.bDate:                                                              # local time, _localtime64
        now, s, e = localtime(now), localtime(Start.DateStart), localtime(Start.DateEnd)
        DateMode 0 YEAR_TERM:  require s.tm_year <= now.tm_year <= e.tm_year
                 1 MONTH_TERM: require s.tm_mon  <= now.tm_mon  <= e.tm_mon     # month only, any year
                 2 DATE_TERM:  require s.tm_mday <= now.tm_mday <= e.tm_mday    # day of month only
                 3 PERIOD:     require DateStart <= now <= DateEnd              # full 64-bit time
                 other: no test
    return 1
CQuest::IsDoingableQuest(row) → int:     "the quest can be accepted"                @ FUN_0062fea0
    IsSoonableQuest(row) and (!Start.bLevel or Start.LevelMin <= level <= Start.LevelMax)
CQuest::IsDoingableQuest(id) → int:      same with GetQuestData(id) (NULL → 0)       @ FUN_0062fee0   (QuestNext ACCEPT, 0xC03)

CQuest::IsRewardAbleQuest(rec) → int:    "the end conditions are met"               @ FUN_0062ff40
    row = GetQuestData(rec.ID); if !row: return 0
    if End.bLevel and level < End.Level: return 0
    for i in 0..4: if End.NPCMobList[i].bNPCMob and NPCMobAction in {1 KILL, 2 FIND, 3 CONVERSATION}
                      and rec.Data.End_NPCMobCount[i] < NPCMobCount: return 0
    for i in 0..4: if End.ItemList[i].bItem:
        if IsQuestPlayerItemLock(ItemID) == 1: return 0                          # no unlocked cell holds the item
        if GetQuestPlayerItemLot(ItemID) < ItemLot: return 0
    if End.bLocation: same map / area test as above with End.Location…; else return 0
    if End.bScenario and !rec.Data.End_Scenario: return 0
    if End.bRace and race != End.Race: return 0
    if End.bClass and class != End.Class: return 0
    if End.bTimeLimit and rec.Data.End_RunningTimeSec >= End.TimeLimit: return 0
    return 1
CQuest::IsRewardAbleQuest(id) → int:     on GetQuestInfo(id) (none → 0)              @ FUN_006300d0   (QuestNext DONE, 0xC08)

CQuest::IsQuestArea(x, y, cx, cy, range) → int:                                     @ FUN_0062fab0
    return (u32)trunc(sqrt(|x − cy| + |y − cy|)) <= range
    # (original bug) Z15-B24: `cx` is never read (both differences use cy) and the sum of the absolute differences
    # is not squared, so the test accepts a far larger, wrongly placed area; no 2016 quest has a location
    # condition (§1.2 data), the client has the same code (client FUN_007284d0)

CQuest::IsSoonableDailyQuest(rec) → u8   (vftable 0x80)  "a daily quest may be done again"   @ FUN_00630130
    row = GetQuestData(rec.ID); if !rec or !row or row.Type != 10 DAILY_QUEST: return 0
    t = by row.nDailyQuestType: 1 DAY tResetDayQuest, 2 WEEK tResetWeekQuest, 3 MONTH tResetMonthQuest,
        4 YEAR tResetYearQuest, other: return 0
    return rec.Data.EndTime < (i64)t                                             # done before the current period began
```

`m_QuestRestTime` holds the start of the current day / week (Monday 00:00) / month / year (WM `CDailyQuestTimer`, W05
§2.3); it arrives with 0x441D at map login and with every 0x441C at the daily rollover (Z08 §3.4; handlers §5). Before
the first 0x441D it is 0 (`CQuestZone::CQuestZone` zeroes it, asm 0x5b9a4f…0x5b9a61; `CQuest::CQuest` does not), so
no daily quest is repeatable until then.

```pseudo
CQuest::GetNewQuestStatus(row) → PLAYER_QUEST_STATUS:                                @ FUN_00630320
    rec = GetQuestInfo(row.ID)
    if rec: switch rec.Status:
        2 DONE:       return (IsSoonableDailyQuest(rec) == 1 and IsDoingableQuest(row) == 1) ? 5 ABLE : 2 DONE
        3 SOON:       if IsDoingableQuest(row): return 5 ABLE
                      return IsSoonableQuest(row) ? 3 SOON : 0 NONE
        4 REPEAT:     return IsDoingableQuest(row) ? 4 REPEAT : 0 NONE
        5 ABLE:       return IsDoingableQuest(row) ? 5 ABLE : 0 NONE
        6 ING, 8 REWARD: return IsRewardAbleQuest(rec) ? 8 REWARD : 6 ING
        20 READ_ABLE: return IsDoingableQuest(row) ? 20 READ_ABLE : 0 NONE
        other (0 NONE, 1 ABORT, 7 FAILED, 9 LOWABLE, …): return rec.Status           # sticky
    # no record:
    if IsSoonableQuest(row) and (!Start.bLevel or LevelMin <= level <= LevelMax): return 5 ABLE
    return IsSoonableQuest(row) ? 3 SOON : 0 NONE
CQuest::GetNewQuestStatus(id): GetQuestData(id) → GetNewQuestStatus(row); unknown id → 0 NONE   @ FUN_006304a0
CQuest::IsDoingQuest(id) → int:  row exists and GetNewQuestStatus(row) ∈ {6 ING, 7 FAILED, 8 REWARD}   @ FUN_006304d0
    # callers: 0x4407 give-up (§4.7), FieldContainer::fc_CanEnterIndun FUN_004624d0 (a map's NeedQuest:
    # ENTER_MAP_ERR_NEED_PARTY_OR_QUEST otherwise, Z08 §5)
CQuest::DoingQuestUpdateStatus(i) → status:                                          @ FUN_00630510
    rec = GetQuestInfoByIndex(i); if !rec: return 0
    rec.Status = GetQuestData(rec.ID) ? GetNewQuestStatus(row) : 0 NONE; return rec.Status
```

The computed status is written back into the diary only by `DoingQuestUpdateStatus` (the event functions of §4.5 and
`QuestPlayer_NPCMobKill` / `ScriptMobKill` of §6) and by `QuestPlayer_DestroyItem`. A record never reaches the DB with
a computed status except through the next 0x4403 / 0x441A / character save (§5). REWARD ↔ ING therefore flips in
both directions as items are gained and lost. Nothing in the zone ever computes 7 FAILED (only the script `FAILED`
command sets it) or 9 LOWABLE except `GetQuestStatusWithNPC` with `bLow` (never set by a zone caller).

NPC side (which quest an NPC offers):

```pseudo
CQuest::IsQuestNPCMob(row, npc) → int:                                              @ FUN_0062fb50
    (Start.bNPC and Start.NPCID == npc) or some End.NPCMobList[i] {bNPCMob, NPCMobID == npc, action 0 REWARD_OBJECT or 3 CONVERSATION}
CQuest::IsConversationNPCMob(row, npc) → int: some End.NPCMobList[i] {bNPCMob, NPCMobID == npc, action 3}   @ FUN_0062fbb0
CQuest::GetRewardNPC(row) → u16:  NPCMobID of the first End.NPCMobList entry with bNPCMob and action 0; 0xFFFF   @ FUN_0062fbf0
CQuest::GetRewardNPC(id)  → u16:  same on GetQuestData(id)                           @ FUN_0062fc40   (used by §5 DONE_REQ)
CQuest::GetStartNPC(id)   → u16:  CQuestData::GetStartNPC(id) (§1)                   @ FUN_0062fc30   (GameLog 0xC80F, §4.7)

CQuest::GetQuestStatusWithNPC(st {u16 hID = npc}, row, level, bLow, unused) → int:   @ FUN_00630570
    st.eResultState = 0; st.lpQuestData = row
    if !IsQuestNPCMob(row, st.hID): return 0
    s = GetNewQuestStatus(row)
    switch s:
        0 NONE, 1 ABORT, 2 DONE, 3 SOON: return 0                               # nothing to offer
        4 REPEAT, 5 ABLE, 7 FAILED, 20 READ_ABLE: require Start.bNPC and Start.NPCID == hID, else return 0
        6 ING:      require IsConversationNPCMob(row, hID) or the start NPC, else return 0
        8 REWARD:   if hID != GetRewardNPC(row): require the start NPC (else return 0); s = 6 ING   # the start NPC
                                                                                 # runs the Doing script
    if bLow and s ∈ {5, 20} and Start.LevelMin + 5 < level: s = 9 LOWABLE      # far below the player's level
    st.eResultState = s; st.nLevel = Start.LevelMin; return s != 0
    # zone caller: 0x440F select-start (§4.7) with level 0, bLow false

CQuest::GetQuestStatusWithNPC(st {hID}):   the quest an NPC click opens (§6: NPCClick, NPCClickCheck)   @ FUN_00630f60
    best = NULL; bestState = 0 NONE; bestLevel = 0
    for every quest row of the table (index order):
        if !GetQuestStatusWithNPC(&tmp {hID}, row, 0, false, false): continue
        if !best: best = row
        pn, pb = m_QuestStatusPriority[tmp.eResultState], m_QuestStatusPriority[bestState]
        if pn < pb: best = row; bestState = tmp.eResultState; if Start.bLevel: bestLevel = Start.LevelMin
        elif pn == pb and Start.bLevel:                                          # tie-breaks, in this order:
            higher Start.LevelMin wins (bestLevel updated); lower loses
            then Type 3 EVENT beats non-EVENT; then a quest with a prerequisite (Start.bQuest) beats one without;
            then one with a start item (Start.bItem); then a Repeatable one beats a non-repeatable one;
            between two non-repeatable ones the lower m_QuestTypePriority[Type] wins; otherwise the earlier row stays
    st.lpQuestData = best; st.eResultState = bestState; st.nLevel = bestLevel
```

Priority (lower first): REWARD 0, ING 1, ABLE / FAILED / READ_ABLE 2, REPEAT (and LOWABLE) 0x15. So an NPC opens the
End script of a finished quest first, then a quest in progress, then a new one. A tie-break replaces `best` but keeps
`bestState` of the previous winner (original bug) Z15-B27: with an ABLE / READ_ABLE quest and a FAILED quest of the same
rank, the NPC click runs `QuestScriptRun(bestState, best.ID)` (§6) with the other quest's status, i.e. the Doing
script of a quest not yet accepted or the Start script of a failed one. Quests without a level condition never win a
tie (`Start.bLevel == 0` keeps the earlier row).

### 4.5 Event functions (`CQuest` vftable 0x04…0x24)

All iterate over the diary; "update" means `st = DoingQuestUpdateStatus(i)` followed, for a record that was 6 ING, by
`vt 0x50(rec, row)` if `st == 8 REWARD` or `vt 0x54(rec, row)` if `st == 7 FAILED` (both empty in the zone, §3.8).
Each returns 1 when some record matched. The per-event hooks `vt 0x2c…0x4c` are empty in the zone.

```pseudo
QuestPlayer_LevelChange(level) (0x04):                                              @ FUN_0062fa20
    for ING records with End.bLevel == 1 and End.Level <= level: vt 0x30(id, level, End.Level)   # hook only, no update
    # callers: ShinePlayer::sp_GainExp FUN_0042d830 and so_AmpersandCommand_LevelUp FUN_0042fa00 (after a level-up).
    # The status is not re-evaluated here; it is recomputed at the next NPC click / DONE (§4.4).
QuestPlayer_NPCMobKill(mobId, questId) (0x08):                                      @ FUN_006306d0
    only the ING record with ID == questId: for each End.NPCMobList[i] {bNPCMob == 1, NPCMobID == mobId, action 1 KILL}:
        if End_NPCMobCount[i] < NPCMobCount: End_NPCMobCount[i] += 1; vt 0x2c(id, mobId, count, needed); update
    # the zone calls its own CQuestZone::QuestPlayer_NPCMobKill / ScriptMobKill instead (§6)
QuestPlayer_TakeItem(itemId, lot) (0x0c):                                           @ FUN_00630810
    for ING records, for each End.ItemList[i] {bItem == 1, ItemID == itemId}: vt 0x34(…); if lot >= ItemLot: update
QuestPlayer_DestroyItem(itemId, lot) (0x10):                                        @ FUN_00630920
    for every record (any status), for each End.ItemList[i] {bItem == 1, ItemID == itemId}: vt 0x38(…)
        if lot < ItemLot: rec.Status = GetNewQuestStatus(row) (0 without row)
            if old status was 8 REWARD: vt 0x58 if now ING, vt 0x54 if now FAILED (empty)
    # (original bug) Z15-B26: no status filter: a REPEAT or READ_ABLE record whose start conditions fail at that
    # moment (e.g. level above LevelMax) is stored as 0 NONE, and NONE is sticky in GetNewQuestStatus, so the
    # quest cannot be started again until the next login; a DONE daily quest after its reset is stored as 5 ABLE
so_ply_ItemLotChange(itemId, delta) (ShinePlayer, the caller of 0x0c / 0x10):       @ FUN_00578270
    lot = q.vt 0x68 GetQuestPlayerItemLot(itemId)                                # the new total
    delta > 0: q.QuestPlayer_TakeItem(itemId, lot); delta < 0: q.QuestPlayer_DestroyItem(itemId, lot); 0: nothing
    # callers (item gain / loss paths): §6
QuestPlayer_CheckLocation() (0x14):                                                 @ FUN_00630a60
    GetPlayerCurrentLocation(&map, &x, &y)
    for ING records with End.bLocation == 1, End.Location == map, End_Location not yet set, IsQuestArea(…):
        End_Location = 1; vt 0x3c(id, map); update
QuestPlayer_ScenarioDone(scenarioId) (0x18): §3.6                                   @ FUN_00630ba0
QuestPlayer_RaceChange(race) (0x1c) / QuestPlayer_ClassChange(class) (0x20):        @ FUN_00630c90 / FUN_00630d70
    for ING records with End.bRace / End.bClass == 1 and the value equal: vt 0x44 / 0x48; update
QuestPlayer_TimeProcess() (0x24):                                                   @ FUN_00630e50
    now = _time32(); if now == m_ProcessedTime: return 0
    prev = m_ProcessedTime; m_ProcessedTime = now
    for ING records with End.bTimeLimit == 1 and End_RunningTimeSec <= End.TimeLimit:
        End_RunningTimeSec = (u16)(End_RunningTimeSec + (u16)(prev − now)); vt 0x4c(…); update
    # caller: ShinePlayer::so_Routine FUN_0056c790 (player tick), so at most once per second
    # (original bug) Z15-B25: adds prev − now (negative): the counter wraps from 0 to ≈65535 at the first second,
    # which makes IsRewardAbleQuest fail forever (>= TimeLimit) and stops the counting; a time-limited quest can
    # never be finished. There is also no FAILED on timeout (GetNewQuestStatus never yields 7). No 2016 quest has a
    # time limit (§1.2 data); the 2016 client has the same code (client FUN_00729780)
CQuest::Occure_LevelChange(id, level, needed):  empty body (PDB name of a shared, folded empty function; Z01 calls
    the same address ShinePlayer_HeartbeatNoOp)                                    @ FUN_004c2450
```

No call of `QuestPlayer_CheckLocation`, `QuestPlayer_RaceChange` or `QuestPlayer_ClassChange` exists in the zone (direct
or through `sp_QuestDiary` / vt 0x808; searched the whole export): location and race / class end conditions are
re-checked only inside `IsRewardAbleQuest` (which tests the area itself, not the `End_Location` flag), so
`End_Location` is never set and unused in the zone. Kill counts for `End.NPCMobList` actions 2 FIND and 3 CONVERSATION are never incremented by
`CQuest` (§6 checks the zone's own counters); no 2016 quest uses them (§1.2 data: actions 0 and 1 only).

### 4.6 Repeat rules (repeatable, daily, give-up)

| Quest | After DONE | Can start again when |
|---|---|---|
| non-repeatable, not daily | Status 2 DONE (sticky) | never |
| `Repeatable` ≠ 0 (157 in 2016) | Status 4 REPEAT, `RepeatCount` + 1 | at once, while `IsDoingableQuest` holds (REPEAT is offered at the start NPC) |
| `Type 10 DAILY_QUEST` (30 in 2016, all `Repeatable 0`, `nDailyQuestType 1 DAY` *(data)*) | Status 2 DONE, `EndTime` = now | when `EndTime` < start of the current period (`IsSoonableDailyQuest`): computed status 5 ABLE |
| given up, non-repeatable | DB record → 20 READ_ABLE with zero data (D04 0x4409); zone record 20 | at once (Start script) |
| given up, repeatable | 4 REPEAT, progress cleared (0x4403 with nQSC 28) | at once |
| CANCEL command | repeatable: 4 REPEAT; non-repeatable: record deleted in the DB only (Z15-B16) | at once |

A daily quest needs `Type 10`; `nDailyQuestType` on another type has no effect. `Repeatable` together with `Type 10`
would give REPEAT and skip the period test. The 40-quest limit counts ING, FAILED and REWARD records
(`GetNumOfDoingQuest`); `QuestNext` ACCEPT goes ahead while fewer than 40 are counted (`< 0x28`), so the 40th is
accepted and a 41st is refused with 0xC0F (§3.3).

### 4.7 Give-up, select-start, read and the SET_INFO answer

Z08 §3.2 / §3.3 list these packets; this is the full logic (with corrections to Z08).

```pseudo
0x4407 NC_QUEST_GIVE_UP_REQ { u16 nQuestID }   ShinePlayer::sp_NC_QUEST_GIVE_UP_REQ  @ FUN_00578910
    if !smo_IsActiveMode: return                                                  # no answer
    if clockwatch.cw_CurrTick < p.sp_ScriptCommand (p+0x5cb4) + 100:              # 10 s after the last 0x4402 (§3.4)
        Send_NC_QUEST_GIVE_UP_ACK(nQuestID, 0xB49); return
    q.Recv_NC_QUEST_GIVE_UP_REQ(req)
CQuestZone::Recv_NC_QUEST_GIVE_UP_REQ(req):                                         @ FUN_005bd960
    if !m_pPlayer: return
    rec = GetQuestInfo(nQuestID); row = GetQuestData(nQuestID)
    if !rec or !row: Send_NC_QUEST_GIVE_UP_ACK(nQuestID, 0xB45); return
    if !IsDoingQuest(nQuestID): return                                            # computed status not ING/FAILED/REWARD
    if !row.Repeatable: Send_NC_QUEST_DB_GIVE_UP_REQ(nQuestID); return
    info = copy of rec; info.Status = 4 REPEAT; SetQuestInfoClearRepeat(&info)
    Send_NC_QUEST_DB_SET_INFO_REQ(&info, &{Cmd 28 QSC_REPEAT_QUEST_GIVE_UP, Data.nID = rec.ID})   # §3.5; the diary
                                                                                  # is changed by the answer
```

**Z08-B6 settled:** the silent case is `IsDoingQuest` = 0, i.e. the quest has a diary record whose computed status is
not ING / FAILED / REWARD: a record in 1 ABORT, 2 DONE, 4 REPEAT, 20 READ_ABLE, or one turned NONE (Z15-B26). The
client offers "give up" only for quests it lists as in progress *(inferred)*, so this happens when the client's and the zone's
diaries disagree, e.g. after a CANCEL / CLEAR (Z15-B16: the client still shows the quest) or an ABORT; the client then
gets no answer at all (original bug, Z08-B6). It is not a timing case: the 10 s rule always answers (0xB49).

```pseudo
CQuestZone::Send_NC_QUEST_DB_GIVE_UP_REQ(id) → int:                                 @ FUN_005bae70
    if !m_pPlayer: return 0
    if (u32 at gpp buffer + 4) != 0:                                              # stale buffer test, asm 0x5baf12
        → GameDB 0x4409 NC_QUEST_DB_GIVE_UP_REQ { u16 clienthandle = p.handle; u32 charregistnumber; u16 nQuestID }   # payload 8
    return 1
    # (original bug) Z15-B30: the same stale-buffer test as Z15-B9: when bytes 4…7 of the previous packet in the
    # shared buffer were 0, nothing is sent and the client never gets 0x4408

0x440A NC_QUEST_DB_GIVE_UP_ACK { hdr6, u16 nQuestID, u16 ErrorType }  (gds handler FUN_00578610: player by handle,
    charNo must match, vt 0x300 == 0 (not closing, Z08 §3.3), then via vt 0x808) →
CQuestZone::Recv_NC_QUEST_DB_GIVE_UP_ACK(ack):                                      @ FUN_005bafc0
    if !m_pPlayer: return
    if ErrorType == 0xB41: AddQuestInfo({ID = nQuestID, Status = 20 READ_ABLE, Data = 0})   # matches the DB (D04)
    Send_NC_QUEST_GIVE_UP_ACK(nQuestID, ErrorType)                                # 0xB41 or the DB's 0xB46

CQuestZone::Send_NC_QUEST_GIVE_UP_ACK(id, err) → int:                               @ FUN_005bad20
    → player 0x4408 NC_QUEST_GIVE_UP_ACK { u16 nQuestID, u16 ErrorCode }  (via p.vt 0x2fc)
```

Client (`GameFrameWork::On_NC_QUEST_GIVE_UP_ACK` client FUN_004ba720): `ErrorCode 0xB41` → `CQuest::Recv_NC_QUEST_GIVE_UP_ACK`
(client FUN_00728180: `SetQuestCancel(id)`), system message "Abandoned <%s> quest." (text 0xCAF22853), removes the quest
from the quest helper, re-scans the start items (`SearchQuestStartItem`) and stores `{id, 20 READ_ABLE}`; every other
code (0xB45, 0xB46, 0xB49, …) → "Failed to give up <%s> quest." (0x96F4E9C7). For a repeatable quest the client thus
holds 20 READ_ABLE where the zone and the DB hold 4 REPEAT (original bug) Z15-B32; both allow a restart, but the
client's quest list shows it as a new quest until the next login.

```pseudo
0x440F NC_QUEST_SELECT_START_REQ { u16 nNPCID, u16 nQuestID }   sp_ handler FUN_00578ab0 (requires IsActiveMode) →
CQuestZone::Recv_NC_QUEST_SELECT_START_REQ(req) → int:                              @ FUN_005c0550
    if !m_pPlayer: return 0
    row = GetQuestData(nQuestID)                                                  # Z08 said "current quest row": no
    err = 0xB47
    if row and GetQuestStatusWithNPC(&st {hID = nNPCID}, row, 0, false, false):
        if m_ParsingQuestID != nQuestID and m_QuestClickNPC == nNPCID              # the NPC the player clicked (§6)
           and QuestScriptRun(st.eResultState, nQuestID) != 0: err = 0xB41        # the script runs (§2.7)
    return Send_NC_QUEST_SELECT_START_ACK(nNPCID, nQuestID, err)
CQuestZone::Send_NC_QUEST_SELECT_START_ACK(npc, id, err):                          @ FUN_005bb340
    → player 0x4410 { u16 nNPCID, u16 nQuestID, u16 ErrorType }                    # the 2016 client ignores it (C01)
```

The client sends 0x440F when the player picks one quest from an NPC's list; the zone re-checks that this NPC offers
it now, and runs the Start / Doing / End script chosen by its computed status. Running the same quest again is refused
(0xB47), as is a pick at an NPC other than the last clicked one.

```pseudo
0x4416 NC_QUEST_READ_REQ { u16 nQuestID }   ShinePlayer::sp_NC_QUEST_READ_REQ        @ FUN_00578f90
    if !smo_IsActiveMode: _ErrorSendPlayer<PROTO_NC_QUEST_START_ACK>(p, 0xB5A)     # FUN_00578c30: 0x4415 {u16 err}
        # (original bug) Z15-B28: the "not active" answer of a READ request goes out as 0x4415 NC_QUEST_START_ACK
        # (Z08 said 0x4417); the client acts on 0x4415 only for 0xB50, so the code is ignored either way
    elif q.Send_NC_QUEST_DB_READ_REQ(nQuestID) == 0: _ErrorSendPlayer<PROTO_NC_QUEST_READ_ACK>(p, 0xB59)   # FUN_00578d60
    # (`&p.sp_QuestDiary != NULL` before the call is always true; dead check like Z08-B15)
CQuestZone::Send_NC_QUEST_DB_READ_REQ(id) → int:                                    @ FUN_005bb6b0
    if !m_pPlayer or !GetQuestData(id): return 0
    if GetNewQuestStatus(id) ∈ {2 DONE, 6 ING, 7 FAILED, 8 REWARD}: return 0      # computed status
    → GameDB 0x4418 NC_QUEST_DB_READ_REQ { u16 clienthandle; u32 charregistnumber; u16 nQuestID }   # payload 8
    return 1
    # the DB overwrites any record with 20 READ_ABLE / zero data (D04): reading a REPEAT quest resets its RepeatCount

0x4419 NC_QUEST_DB_READ_ACK { hdr6, u16 err, u16 nQuestID }  (gds handler FUN_00578710) →
CQuestZone::Recv_NC_QUEST_DB_READ_ACK(ack):                                         @ FUN_005c06c0
    if !m_pPlayer: return
    if err == 0xB41: AddQuestInfo({nQuestID, 20 READ_ABLE, Data = 0}); → player 0x4417 { u16 err = 0xB58, u16 nQuestID }
    else: _ErrorSendPlayer<PROTO_NC_QUEST_READ_ACK>(p, err)                        # the DB's 0xB43
_ErrorSendPlayer<PROTO_NC_QUEST_READ_ACK>(p, err): → 0x4417 { u16 err, u16 nQuestID = stale buffer bytes }  (payload 4, via p.vt 0x2f8)
    # (original bug) Z15-B29: nQuestID is never written (whatever the previous packet left at buffer+4); the 2016
    # client handler (client FUN_0049c8e0) only prints "%d ??? Read OK" to the debugger, so no visible effect
```

"Reading" marks a quest the player has looked at (status 20 READ_ABLE, which the Start script accepts like ABLE).

```pseudo
0x4404 NC_QUEST_DB_SET_INFO_ACK { hdr6, u8 nQSC, PLAYER_QUEST_INFO QuestInfo, u16 ErrorType }  (gds FUN_00578410) →
CQuestZone::Recv_NC_QUEST_DB_SET_INFO_ACK(ack):                                     @ FUN_005bf280
    if !m_pPlayer: return
    p.vt 0xae4 so_SetIsQuestRewardReq(0); m_bWaitResult = 0                        # for every nQSC, see Z15-B33
    if nQSC == 28 REPEAT_QUEST_GIVE_UP:                                            # from 0x4407 above
        rec = GetQuestInfo(QuestInfo.ID)
        if ErrorType == 0xB41 and rec: rec.Status = 4 REPEAT; SetQuestInfoClearRepeat(rec); err = 0xB41 else err = 0xB46
        Send_NC_QUEST_GIVE_UP_ACK(QuestInfo.ID, err); return                        # no QuestNext
    if ErrorType != 0xB41:
        _DebugMessageNew("ERROR, CQuestZone::Recv_NC_QUEST_DB_SET_INFO_ACK …" char name, m_ParsingQuestID, ID, Status, time)
        Send_QUEST_ERROR_TO_CLIENT(0xC0E); return                                  # §3.4; the script was waiting
    switch nQSC:
        6 ACCEPT:   ok = SetQuestAccept(ID)
        7 CANCEL:   ok = SetQuestCancel(ID)
        8 PROGRESS: ok = SetQuestProgress(ID, QuestInfo.Data.ProgressStep)
        9 FAILED:   ok = SetQuestFailed(ID)
        10 DONE:    ok = SetQuestDone(ID); if ok and !row.Repeatable: p.vt 0x420 → CCharacterTitleZone::CT_QuestSuccess(ID) (§5)
                    # unreachable: the zone sends DONE through 0x441A, never 0x4403 with nQSC 10
        12 ABORT:   ok = SetQuestAbort(ID)
        other:      _DebugMessageNew("ERROR, Recv_NC_QUEST_DB_SET_INFO_ACK, QUEST UN-DRIVED COMMAND=%d, QuestID=%d At %s")
                    Send_QUEST_ERROR_TO_CLIENT(0xC0E); return
    if ok: Send_NC_QUEST_SCRIPT_CMD_REQ(ID, &{Cmd = nQSC, IsPigeonStartType 0, Data.nID = ID,
                                              Data[2] = ProgressStep for PROGRESS})   # 0x4401, client §3.4
    if nQSC == 6: → GameLog 0xC80F NC_SYSLOG_CHAR_QUEST_STARTED { u32 userNo (vt 0x348), u32 charNo (vt 0x344),
                     u16 questId, u8 zoneNo, u16 GetStartNPC(questId) }   (payload 13)
                  (a packet-length failure asserts and skips the send)
    QuestNext()                                                                   # also when ok == 0
```

The local `STRUCT_QSC` for the 0x4401 sets only `Cmd`, `IsPigeonStartType`, `Data.nID` (and the progress byte); the
other `Data` bytes are stack leftovers (same class as Z15-B10). `so_SetIsQuestRewardReq(0)` and `m_bWaitResult = 0` run
for every answer, also for a repeat give-up that has nothing to do with the running script: a give-up answer that
arrives while a reward request (0x441A) or another 0x4403 is pending clears both flags early (original bug) Z15-B33
(narrow: 0x4407 is refused for 10 s after the last 0x4402).

---

## 5. Rewards, the DONE round trip, reset times and the character save

The reward path starts at the script command `DONE` (§3.3) and ends with the answer 0x441B. The zone checks and
reserves everything first (money, exp, fame, title, item cells under one inventory lock index), the Character server
writes everything in one request (D04 §1.2 0x441A), and only the success answer applies the reservations in memory
(Z05 §1.1 style 1). The quest record itself is updated on the zone only after the answer.

### 5.1 Reward data, selection and the room check

Rewards are `QUEST_DATA.Reward[12]` (row +0x204, §1.2): `{u8 Use (0 UNUSE, 1 PRIMARY, 2 SELECTABLE); u8 Type; VALUE}`.
Every PRIMARY entry is given; of the SELECTABLE entries only the one the player picked. The pick is the **absolute
slot index 0…11** in `Reward[]`: `QuestCheckSelectReward` compares it with the slot number, and the 2017 client converts
its UI choice (n-th selectable) into that slot number before sending (`RewardWin::GetRealSelectReword` 0057cc80
*(pdb2017)*).

```pseudo
0x4411 NC_QUEST_REWARD_SELECT_ITEM_INDEX_CMD { u16 nQuestID; u32 nSelectedItemIndex }  (zone handler @ FUN_00578b70, Z08 §3.2) →
CQuestZone::Recv_NC_QUEST_REWARD_SELECT_ITEM_INDEX_CMD(cmd) → int:                 @ FUN_005bb490
    if !m_pPlayer: return 0
    if m_ParsingQuestID == cmd.nQuestID: m_nSelectedItem = cmd.nSelectedItemIndex   # no range check; validated at DONE
    return 1
# m_nSelectedItem = 0xFFFFFFFF on every QuestStart / QuestDoing / QuestEnd (§2.7); nothing else writes it

CQuestZone::Send_NC_QUEST_REWARD_NEED_SELECT_ITEM_CMD(questId) → int:              @ FUN_005bb570
    if !m_pPlayer: return 0
    → client 0x4412 NC_QUEST_REWARD_NEED_SELECT_ITEM_CMD { u16 nQuestID }  (payload 2, game socket vt 0x2fc)
    # client FUN_00479fa0: message "Please choose reward(s)." (TextData 0x90fcd9c7); the field is not read
    return 1

CQuestZone::QuestCheckSelectReward(questId, sel) → int:   "the choice is valid"   @ FUN_005ba0e0
    if !m_pPlayer or !(row = GetQuestData(questId)): return 0
    for i in 0..11: if row.Reward[i].Use == 2 SELECTABLE and i == sel: return 1
    return (no SELECTABLE entry exists)            # 1 for a quest without choice, whatever sel holds

CQuestZone::QuestCheckReward(questId, sel, chargedEffects) → int:  "enough free cells"   @ FUN_005bcde0
    if !m_pPlayer or !(row = GetQuestData(questId)): return 0
    need = number of i with Reward[i].Type ∈ {2 ITEM, 5 PET} and (Use == 1 PRIMARY or (Use == 2 and i == sel))
    return QuestCheckRewardInven(need, chargedEffects)

CQuestZone::QuestCheckRewardInven(need, chargedEffects) → int:                     @ FUN_005b9f60
    if !m_pPlayer: return 0
    box = the inventory (p.sp_Item.itembag.ci_Inventory); limit = chargedEffects ? box.vt 4(chargedEffects) : box.vt 8()
                                                   # usable size with the bought inventory pages / full size (Z04 §1.2)
    free = number of empty cells below limit that are not locked (ItemBoxIterEmpty + UnlockedInventoryIterator,
           inventory type 9, lock list p.vt 0x7d4)
    return need <= free
```

`QuestNext` (`DONE`, §3.3) always passes `so_ply_ChargedEffectContainer()` (p.vt 0x498), so the usable size counts.

What the zone gives per reward type (`Send_NC_QUEST_DB_DONE_REQ`, §5.2):

| Type | Given as | 2016 data *(data)* |
|---|---|---|
| 0 EXP | `nExp = Value` | PRIMARY 2129, SELECTABLE 1 (quest 1060, slot 0, its only selectable entry) |
| 1 MONEY | `nMoney = Value` | PRIMARY 2125 |
| 2 ITEM | one `ItemCreate` of `ItemID` × `ItemLot` (§5.2) | PRIMARY 530, SELECTABLE 362 |
| 4 FAME | `nFame = Value` | PRIMARY 17 |
| 7 TITLE | `CT_Type = Value[0]`, `CT_ElementNo = Value[1]`; Type is cleared when ElementNo > 3 | none |
| 3 ABSTATE, 5 PET, 6 MINIHOUSE, 8 KILLPOINT | **nothing** (no case; PET still needs a free cell in `QuestCheckReward`) | none |

EXP, MONEY and FAME are assigned, not added: a second PRIMARY entry of the same type would replace the first
*(none in the 2016 data)*. 122 quests have selectable rewards (121 with more than one); a quest needs at most 8 free
cells.

### 5.2 `0x441A NC_QUEST_DB_DONE_REQ`: reserve and send

The function carries the profiler string `CQuestZone::QuestTakeReward` (the name Z01 gave it).

```pseudo
CQuestZone::Send_NC_QUEST_DB_DONE_REQ(questId, sel) → int:                         @ FUN_005bbe60
    if !m_pPlayer: return 0
    if p.vt 0xae0 so_GetIsQuestRewardReq() == 1: return 0        # a reward is already in flight (§5.4)
    L = p.vt 0x7d4 (InventoryCellLockList)
    if L.vt 0x10 icl_IsAnyLock(): return 0                       # any open item reservation / DB-pending item request
    if !(row = GetQuestData(questId)): return 0
    req = gpp: opcode 0x441A, payload {                          # PROTO_NC_QUEST_DB_DONE_REQ (pdb2016)
        +0x00 NETPACKETZONEHEADER { u16 clienthandle = p.handle (p+4); u32 charregistnumber = p.vt 0x344 }
        +0x06 u32 UserNo = p.vt 0x348 so_GetUserRegistNumber()
        +0x0A u16 NPCID  = CQuest::GetRewardNPC(questId)          # first End NPC with action 0; 0xFFFF (§4.4)
        +0x2D…+0x4F zeroed (buf+0x2F…+0x51): nMoney, nExp, nFame, nCur_*, CT_Type, CT_ElementNo, nCur_CT_ElementValue
        +0x50 u16 nLockIndex = 0, +0x52 u8 nItemCreateCount = 0 }
    if !(rec = GetQuestInfo(questId)): return 0
    req.QuestInfo (+0x0D, 0x20) = copy of rec; CQuest::SetQuestDone(&req.QuestInfo)
                                     # status 4 REPEAT (repeatable) or 2 DONE, RepeatCount + 1, EndTime = now (§4.3)
    req.nQSC (+0x0C) = m_pQSC.Cmd                                # 10 DONE
    m_bWaitResult = 1                                            # the script pauses here (corrects §3.1's table)
    for i in 0..11 with Reward[i].Use ≠ 0 and (Use ≠ 2 or i == sel):   # table §5.1
        0 EXP → nExp (+0x31); 1 MONEY → nMoney (+0x2D); 4 FAME → nFame (+0x35)
        2 ITEM → itemId[n] = Value.ItemID, lot[n] = Value.ItemLot, n += 1 (nItemCreateCount)
        7 TITLE → CT_Type (+0x4D) = Value.Type, CT_ElementNo (+0x4E) = Value.ElementNo; if CT_Type ≠ 0 and ElementNo > 3: CT_Type = 0
    req.nLockIndex   = L.icll_index (L+4, u16)
    req.nCur_Money   = p.vt 0x434 so_ply_CurrentMoney()  (u64, +0x39)
    req.nCur_Exp     = p.vt 0x438 so_ply_CurrentExp()    (u64, +0x41)
    req.nCur_Fame    = p.vt 0x43c so_ply_CurrentFame()   (u32, +0x49)
    title = p.vt 0x420 so_GetCharacterTitle(); if !title: return 0
    req.nCur_CT_ElementValue (+0x4F) = CCharacterTitle::GetTitleStatus(title, CT_Type, req.nCur_CT_ElementValue)   @ FUN_0062e180
        # passes the byte it is about to fill (still 0) as the element: always the state of element 0, not of
        # CT_ElementNo (original bug) Z15-B36. GetTitleStatus(type < 128, e 0..3) = m_Titles[type].Element<e>, else 0
    L.vt 0x48 icl_StoreMoney(lock, u64 nMoney, +1)              # CenChange reservation (Z05 §1.4), also when nMoney == 0
    L.vt 0x60 icl_QuestReward(lock, nExp, nFame, CT_Type, CT_ElementNo)    @ FUN_00489800
        # LockedCell { lc_Index = lock, lc_Releaser = icll_Releaser_QuestReward, both locations = inventory 0x11 slot 0,
        #              lc_Argument.questreward { i32 exp, i32 fame, u8 ct_type, u8 ct_elementno } };
        # a full lock list asserts "…icl_QuestReward : List Full" and reserves nothing
    attr = req + 0x53 + n × 0x26                                 # attribute bytes follow the ItemCreate array
    if n > 0:
        it = empty unlocked inventory cells (ItemBoxIterEmpty with the charged container, inventory type 9, as §5.1)
        if !it.Home(): return 0
        for k in 0..n-1:
            if no current cell: return 0                         # cannot happen after QuestCheckReward (inferred)
            key = ItemTotalInformation::iti_mkregnum(itemId[k], kind 2, own zoneNo, own worldNo)   # kind 2 = quest reward
            cls = ItemAttributeClassContainer[itemId[k]]; item = {itemId[k], cls.vt 0x14 init attribute(itemId, &key, "-o")}
            if ItemDataBox[itemId].dataserv.RandomOptionDropGroup names a RandomOptionTable row and cls.vt 0x70(item) gives
                an option storage: rot_FillOption(storage, row)  # random options rolled now (Z04)
            cls.vt 0x20 SetLot(item, lot[k])
            ItemCreate[k] (0x26) = { u32 owner = p.vt 0x344 charNo; MAPPOS map = 12-byte map name (*(p+0x7a)) + x, y
                (*(p+0x66)); ITEM_INVEN location = 9 << 10 | cell; SHINE_ITEM_REGISTNUMBER createitemregnum = key;
                u16 createitemid = itemId[k]; u16 attr = (attr − payload start) }   # payload offset of its attribute bytes
            attr = cls.vt 4(item, attr)                          # writes the attribute bytes, returns the new end
            L.vt 0x40 icl_StoreItem(lock, cell, &{key, item}, &location, &location)   # CellChange reservation (Z05 §1.4)
            it.Next()
    pp_SetPacketLen(attr − buffer); too long → assert "Send_NC_QUEST_DB_DONE_REQ : Packet Too Long" (no send), but the
        lines below still run: reservations held, flag 1, script waiting, return 1, and no answer will ever come;
        unreachable with at most 12 creates of 0x26 bytes plus their attributes in the packet buffer *(inferred)*
    else → GameDB (Character server, D04 §1.2) 0x441A, total payload 0x53 + n × 0x26 + attribute bytes
    L.icll_index += 1
    p.vt 0xae4 so_SetIsQuestRewardReq(1)
    QuestNext()                                                  # returns 2 at once: m_bWaitResult is set
    return 1
```

On `return 0`, `QuestNext` frees whatever was reserved under the current index (`L.vt 0x28 icl_Free(L+4)`), moves the
index on and sends error 0xC01 + `QuestClose` (§3.3); `QuestClose` clears the `m_bWaitResult` set above. So 0xC01
"Inventory full. Cannot receive the reward item." is also what the player reads when a reward is already pending or any
other item operation is still open (`icl_IsAnyLock`) (original bug) Z15-B37.

The reservations lock the chosen empty cells (other item requests skip them) and the open lock makes `icl_IsAnyLock`
true, so every other item request that tests it is refused until the answer (Z04 §1.4).

### 5.3 `0x441B NC_QUEST_DB_DONE_ACK`: apply or drop

The DB answer `{ hdr6, u8 nQSC, PLAYER_QUEST_INFO QuestInfo, u16 nLockIndex, u16 ErrorType }` (0x2B; Character server
D04 §1.2: 0xB41 ok, 0xB43 quest store failed, 0xBC2 item insert failed, 0xBC3 money failed, 0xBC5 title failed; the DB has
rolled back on failure) reaches the quest object through `gds_NC_QUEST_DB_DONE_ACK` FUN_00578810 (Z08 §3.3).

```pseudo
CQuestZone::Recv_NC_QUEST_DB_DONE_ACK(ack) → int:                                  @ FUN_005bfb30
    if !m_pPlayer: return 0
    L = p.vt 0x7d4
    if ack.ErrorType == 0xB41:
        if !L.vt 0x1c icl_Apply_N_Free(p, ack.nLockIndex, 0):     # apply every reservation of the index (Z05 §1.3)
            LockIndexLog << "CQuestZone::Recv_NC_ITEMDB_QUESTREWARD_ACK : " << lock    (copy-pasted text)
        m_bWaitResult = 0
        if CQuest::SetQuestDone(ack.QuestInfo.ID):               # the diary record by id (§4.3); 0 = no record
            if (row = GetQuestData(ID)) and !row.Repeatable:
                CCharacterTitleZone::CT_QuestSuccess(p.vt 0x420(), ID)
            Send_NC_QUEST_SCRIPT_CMD_REQ(ID, &{Cmd = ack.nQSC (10 DONE), IsPigeonStartType 0, Data.nID = ID})
                # 0x4401 to the client (§3.4: the client runs CQuest::SetQuestDone(nID)); other Data bytes are stack leftovers
                # (same class as Z15-B10)
        p.vt 0xae4 so_SetIsQuestRewardReq(0)
        QuestNext()                                               # the command after DONE
        return 1
    # failure
    _DebugMessageNew("ERROR, CQuestZone::Recv_NC_QUEST_DB_DONE_ACK …", char name, m_ParsingQuestID, ID, Status, time)
    L.vt 0x28 icl_Free(ack.nLockIndex)                            # drop the reservations; nothing was applied
    Send_QUEST_ERROR_TO_CLIENT(0xC0E)                             # "DB writing error …", NPC dialog closed (§3.4)
    p.vt 0xae4 so_SetIsQuestRewardReq(0)
    return 0
```

The answer is not matched with the running script: neither `ack.QuestInfo.ID` nor `nQSC` is compared with
`m_ParsingQuestID` / the current command. While the reward is pending only `QuestStart` is refused (§2.7); `QuestDoing` /
`QuestEnd` (an ING or REWARD quest at another NPC) still open a new script, which closes the waiting one. When 0x441B then
arrives, it clears the new script's `m_bWaitResult` and runs `QuestNext` on it, so a `SAY` waiting for its answer is
passed with the stale RESULT (original bug) Z15-B35. On a failure answer `m_bWaitResult` stays 1 and the script stays
open: `QuestNext` and 0x4414 (§6) are blocked until the next script opens (original bug) Z15-B34 (as Z15-B17 for CLEAR).

What the apply does (releasers, Z05 §1.4), in reservation order *(inferred: list order)*:

```pseudo
CenChange (money):  money += nMoney → client 0x1033 NC_CHAR_CENCHANGE_CMD { u64 cen }            (Z05 §1.4)
InvenCellReleaser_QuestReward::icr_Apply(this, obj, cell, ctx):  obj.vt 0x464(cell)                @ FUN_004881a0
ShinePlayer::so_ply_InvenCellReleaser_QuestReward(cell):                                         @ FUN_0052d980
    sp_GainExp(this, cell.questreward.exp, 0xFFFF, 0xFFFF)       # Z03: exp gain, level-ups
    this.vt 0x20 so_GainFame(cell.questreward.fame)
    if cell.questreward.ct_type ≠ 0:
        CCharacterTitleZone::SetTitleStatus(p.vt 0x420(), ct_type, ct_elementno, 2 ELEMENT_USABLE)
CellChange (each item): the new item is written into its reserved cell → client 0x3001 NC_ITEM_CELLCHANGE_CMD (Z05 §1.5)
```

`CT_ELEMENT_VALUE` *(pdb2016)*: 0 UNKNOWNED, 1 KNOWNED, 2 USABLE, 3 USE. The DB stores the title as value 2 too
(D04 §1.2), so zone and DB agree.

```pseudo
CCharacterTitleZone::CT_QuestSuccess(questId):                                             @ FUN_005cc270
    m_TitleValues[40 ID_QUEST_SUC_COUNT].TitleValue (u64) += 1; .bTitleSave = 1
    CheckNewTitle(40)                                            # unlock a "quests completed" title (Z18, Z07 section; Z09 §17.8)
```
`questId` is not used: the counter counts non-repeatable quest completions.

### 5.4 The reward-request flag

`ShinePlayer.sp_IsQuestRewardReq` (u8 at p+0x2AA50 *(pdb2016)*) is read by `so_GetIsQuestRewardReq` (vt 0xAE0, FUN_0054a7a0)
and written by `so_SetIsQuestRewardReq` (vt 0xAE4, FUN_0054a7b0).

| Set to | By |
|---|---|
| 1 | `Send_NC_QUEST_DB_DONE_REQ` after the send (§5.2) |
| 0 | `Recv_NC_QUEST_DB_DONE_ACK` (both outcomes), `Recv_NC_QUEST_DB_SET_INFO_ACK` (every answer, Z15-B33), `Recv_NC_ITEMDB_QUESTREWARD_ACK` failure (§5.5) |

Readers while it is 1: `QuestStart` refuses (§2.7), `Send_NC_QUEST_DB_DONE_REQ` refuses (0xC01), and the item code
refuses: `sp_NC_ITEM_USE_REQ` FUN_005416b0 (fail code 0x701 "Cannot use the item due to an Abnormal State."),
`UseItemRecallScroll::uib_CanUseItem` FUN_005980d0, `sp_NC_ITEM_MOVER_UPGRADE_REQ` FUN_0051c850,
`sp_NC_ITEM_MAPLINK_SCROLL_REQ` FUN_00520130, `sp_NC_ITEM_RANDOMOPTION_RECOVER_COUNT_LIMIT_REQ` FUN_0051dd40,
`sp_NC_ITEM_CHAT_COLOR_CHANGE_REQ` FUN_0051e580, `sp_NC_ITEM_TERMEXTEND_REQ` FUN_0051eb40,
`sp_NC_ITEM_CLASS_CHANGE_REQ` FUN_0051f5c0, `sp_NC_ITEM_RANDOMOPTION_CHANGE_REQ` FUN_00520e40,
`sp_NC_ITEM_USE_ACTIVESKILL_REQ` FUN_00540b90, and the minimon auto-use routine `sp_UseItemMinimon_Routine`
FUN_00564d40 (skips its run). Their own replies are Z04's. Nothing else writes p+0x2AA50: the `ShinePlayer` constructor
FUN_0055bc80 does not initialise it and no raw write or memset of that offset exists in the zone. So if a 0x441B is lost
(Character server down, connection dropped) the flag stays 1 for the rest of the session, and also for the next
character that gets the same pooled player object: quests cannot be started or finished and the items above cannot be
used (original bug) Z15-B47. Its value in a fresh pool object depends on the open zero-fill question (§9).

### 5.5 The older two-step path: `0x345C NC_ITEMDB_QUESTREWARD_ACK`

The zone still handles the answer of the Character server's `0x345B NC_ITEMDB_QUESTREWARD_REQ` (D03 §7.5; success
code 0xBC1), but **the 2016 zone never sends 0x345B** (no send site in the code; the only `0x345b` constants are pet
item-use fail codes in `UseItemPet::uib_CanUseItem`). The handler is dead code for a 2016 Character server that only
answers what it is asked.

```pseudo
0x345C { hdr6, u16 lockindex, u16 nQuestID, u16 err }  (gds_NC_ITEMDB_QUESTREWARD_ACK FUN_00527ff0, profiler string
        "gds_NC_ITEMDB_DESTROY_ACK", Z05 §6.5) → q = p.vt 0x808 so_ply_QuestDiary()
CQuestZone::Recv_NC_ITEMDB_QUESTREWARD_ACK(ack):                                    @ FUN_005bf7f0
    if !m_pPlayer: return
    if ack.err == 0xBC1:
        L.icl_Apply_N_Free(p, lockindex, 0) (failure logged as above)
        if rec = GetQuestInfo(nQuestID):
            info = copy of rec; CQuest::SetQuestDone(&info); m_bWaitResult = 1
            Send_NC_QUEST_DB_SET_INFO_REQ(&info, m_pQSC)          # 0x4403 with nQSC = the current command (10 DONE)
            QuestNext()                                           # returns 2
    else:
        L.icl_Free(lockindex); Send_QUEST_ERROR_TO_CLIENT(0xC0E); p.so_SetIsQuestRewardReq(0)
```

This is the only path that would reach the `nQSC 10 DONE` case of `Recv_NC_QUEST_DB_SET_INFO_ACK` (§4.7), which part 3
found unreachable: items first through ITEMDB, the quest status second through SET_INFO. The 2016 design does both in
0x441A *(inferred: an earlier protocol kept for compatibility)*.

### 5.6 Reset times: 0x441C / 0x441D → 0x441E

`CQuest.m_QuestRestTime` (+0xA4, `PROTO_NC_QUEST_RESET_TIME_CMD` *(pdb2016)*: `i32 tResetYearQuest, tResetMonthQuest,
tResetWeekQuest, tResetDayQuest`) holds the last reset instant of each period; `IsSoonableQuest` / `IsSoonableDailyQuest`
compare a DONE record's `EndTime` with it (§4.4, §4.6). The `CQuestZone` constructor zeroes it.

```pseudo
WM 0x441C NC_QUEST_RESET_TIME_CMD { Year, Month, Week, Day }  (wms FUN_005a6520: every player, Z08 §3.4) →
CQuestZone::Recv_NC_QUEST_RESET_TIME_CMD(cmd) → int:                               @ FUN_005bdc80
    if !cmd or !m_pPlayer: return 0
    m_QuestRestTime = cmd (16 bytes)
    if !Send_NC_QUEST_RESET_TIME_ZONE_CMD(0): assert "CQuestZone::Recv_NC_QUEST_RESET_TIME_CMD"; return 0
    return 1

WM 0x441D NC_QUEST_RESET_TIME_ZONE_CMD { u32 nCharNo; Year, Month, Week, Day }  (wms FUN_005a5b90: one player, at map
        login, Z08 §3.4) →
CQuestZone::Recv_NC_QUEST_RESET_TIME_ZONE_CMD(cmd) → int:                          @ FUN_005bddb0
    if !cmd or !m_pPlayer: return 0
    m_QuestRestTime = cmd.{Year, Month, Week, Day}
    if !Send_NC_QUEST_RESET_TIME_ZONE_CMD(1): assert "CQuestZone::Recv_NC_QUEST_RESET_TIME_ZONE_CMD"
    return 1

CQuestZone::Send_NC_QUEST_RESET_TIME_ZONE_CMD(viaData) → int:                      @ FUN_005bc570
    if !m_pPlayer: return 0
    → client 0x441E NC_QUEST_RESET_TIME_CLIENT_CMD { i32 Year, Month, Week, Day } = m_QuestRestTime   (payload 16)
      through p.vt 0x2f8 so_GetDataSocketStream() when viaData == 1 (login), else p.vt 0x2fc so_GetGameSocketStream()
    return 1                                       # also when the length check asserts (no send)
```

The client stores the four values at the same offset of its own `CQuest` (FUN_006ac760: quest object +0xA4…+0xB0), so its
`IsSoonableQuest` uses the same reset instants as the server (shared library, §4) *(inferred)*. Nothing on the zone computes reset
times itself: without a 0x441D/0x441C all four are 0 and every period counts as reset long ago (§4.4).

### 5.7 The diary in the character save and at map login

The DB receives single records as they change (0x4403, 0x4405, 0x4409, 0x4418, 0x441A: D04 §1.2). The character save
(`WholeSaver`, Z01 §8.4) additionally writes the in-progress list to the DB and the whole diary to the WM's cache (W01
§6.3, W05 §5.4), which hands it to the next zone at the map login (0x1021 / 0x1022 / 0x10CD / 0x10D6, §4.2). Each list is
selected by the **stored** `Status`:

```pseudo
so_SaveQuestDoing(PROTO_NC_CHARSAVE_QUEST_DOING_REQ*)  vt 0x398 @ FUN_004534a0 → (ws_save2DB, GameDB 0x4005 NC_CHARSAVE_QUEST_DOING_REQ)
CQuestZone::MakeStruct_NC_CHARSAVE_QUEST_DOING_REQ(out) → n:                        @ FUN_005bb850
    if !m_pPlayer: return 0
    out = { handle (6, filled by the caller), u8 bNeedClear = 1, u8 nNumOfDoingQuest = n, PLAYER_QUEST_INFO[n] @+8 }
    n = records with Status ∈ {6 ING, 7 FAILED, 8 REWARD}, copied in diary order; stop once the end offset passes 7999
    # the GameDB answer 0x4006 NC_CHARSAVE_QUEST_DOING_ACK is ignored (GameDBSession::NC_CHARSAVE_QUEST_DOING_ACK FUN_004553b0,
    # a no-op shared with 0x401B, Z01): a failed save is never noticed by the zone

so_SaveQuestDoing(PROTO_NC_CHARSAVE_2WLDMAN_QUEST_DOING_CMD*)  vt 0x394 @ FUN_004534b0 → (ws_save2worldmanager, WM 0x400F)
CQuestZone::MakeStruct_NC_CHARSAVE_2WLDMAN_QUEST_DOING_CMD(out) → n:                @ FUN_005bb980
    same selection into { u16 wldmanhandle (caller), u32 chrregnum (caller), u8 bNeedClear = 1, u8 n, records @+8 }
    # no size limit (the 40-quest rule keeps n small, §4.6)

so_SaveQuestRead  vt 0x39c @ FUN_004534d0 → WM 0x4029
CQuestZone::MakeStruct_NC_CHARSAVE_2WLDMAN_QUEST_READ_CMD(out) → n:                 @ FUN_005bbab0
    { wldmanhandle, chrregnum, u16 nNumOfReadQuest = n, u16 QuestReadIDArray[n] @+8 }: ids of records with Status 20
    READ_ABLE; stop past offset 7999

so_SaveQuestRepeat  vt 0x3a0 @ FUN_004534e0 → WM 0x402B
CQuestZone::MakeStruct_NC_CHARSAVE_2WLDMAN_QUEST_REPEAT_CMD(out) → n:               @ FUN_005bbbd0
    { wldmanhandle, chrregnum, u16 nNumOfRepeatQuest = n, PLAYER_QUEST_INFO[n] @+8 }: records with Status 4 REPEAT;
    stop past offset 7999

so_Send_NC_CHARSAVE_2WLDMAN_QUEST_DONE_CMD(buf)  vt 0xd20 @ FUN_004534c0 (from ws_save2worldmanager) →
CQuestZone::Send_NC_CHARSAVE_2WLDMAN_QUEST_DONE_CMD(buf = gpp):                    @ FUN_005bc6f0
    list = { u16 ID, i64 EndTime } (PLAYER_QUEST_DONE_INFO, 10 bytes) of every record with Status 2 DONE
           (built in a 30000-byte stack buffer: room for the 3000-record diary maximum, §4.1)
    header: opcode 0x4010 NC_CHARSAVE_2WLDMAN_QUEST_DONE_CMD; u16 wldmanhandle = p.vt 0x340; u32 chrregnum = p.vt 0x344;
            u16 nTotalDoneQuest = N; u16 nTotalDoneQuestSize = N × 10 + 12; u16 nDoneQuestCount; u16 nIndex = 0
    split into packets of at most 799 records (a packet is sent when its length would pass 7999):
        each: nDoneQuestCount = records in it; send to the WM; next nIndex = nIndex + count
    the last (or only) packet is always sent, also with N = 0
    # WM CharDataStore FUN_00433210 copies each chunk to blob + 12 + nIndex × 10 of a blob of nTotalDoneQuestSize (W05 §5.4)
```

So a record whose stored status is 0 NONE, 1 ABORT, 3 SOON, 5 ABLE or 9 LOWABLE is in none of the lists: it is not
carried to the next zone through the WM cache, and comes back only with the next character login from the DB (which
stores every record the zone sent with 0x4403). For a 0 NONE record (Z15-B26) this heals the sticky status at the map
change; an ABORT record would be forgotten until the next login, but `ABORT` is never used in the 2016 scripts (§2.8)
*(inferred)*.

The four WM blobs come back at the next map login as 0x1021 / 0x1022 / 0x10CD / 0x10D6 (Z07 §1.2). Their
`so_StoreQuest*` methods merge the list into the diary (§4.2) and forward it unchanged to the client:

```pseudo
so_StoreQuestDoing(cmd)  vt 0x67c @ FUN_0044b3c0:  CQuest::Recv_NC_CHAR_QUEST_DOING_CMD_ACK(cmd) (§4.2);
    → client 0x103A NC_CHAR_CLIENT_QUEST_DOING_CMD { u32 chrregnum, u8 bNeedClear, u8 n, PLAYER_QUEST_INFO[n] }  (8 + 32n)
so_StoreQuestDone(cmd)   vt 0x680 @ FUN_0044b500:  Recv_NC_CHAR_QUEST_DONE_CMD_ACK(cmd);
    → client 0x103B NC_CHAR_CLIENT_QUEST_DONE_CMD { u32 chrregnum, u16 nTotalDoneQuest, u16 nTotalDoneQuestSize,
         u16 nDoneQuestCount, u16 nIndex, PLAYER_QUEST_DONE_INFO[nDoneQuestCount] }  (0xE + 10n)
so_StoreQuestRead(cmd)   vt 0x684 @ FUN_0044b640:  Recv_NC_CHAR_QUEST_READ_CMD_ACK(cmd);
    → client 0x10CE NC_CHAR_CLIENT_QUEST_READ_CMD { u32 chrregnum, u16 n, u16 ids[n] }  (8 + 2n)
so_StoreQuestRepeat(cmd) vt 0x688 @ FUN_0044b770:  Recv_NC_CHAR_QUEST_REPEAT_CMD_ACK(cmd);
    → client 0x10D7 NC_CHAR_CLIENT_QUEST_REPEAT_CMD { u32 chrregnum, u16 n, PLAYER_QUEST_INFO[n] }  (8 + 32n)
all four: data socket (p.vt 0x2f8); a too long packet asserts "<method> : Packet Too Long" and is not sent
```

Client handlers (C01): 0x103A FUN_00727fd0, 0x103B FUN_007280b0, 0x10CE FUN_007281b0, 0x10D7 FUN_00728280 store the
records in the client's `CQuest` (`FUN_006acdb0()`), the same merge as the server's §4.2.

### 5.8 Worked trace: a quest with an item reward

Quest with PRIMARY EXP 500, MONEY 100, ITEM (id 2000 × 1), status 8 REWARD, player at the End NPC, 1 free cell:

1. NPC click → `QuestEnd` → `QuestNext`: `SAY` → 0x4401 Cmd 2, wait; the answer 0x4402 (no 0x4411: nothing to choose).
2. `DONE`: `IsRewardAbleQuest` ok; `QuestCheckSelectReward` 1 (no SELECTABLE); `QuestCheckReward`: need 1 ≤ free 1.
3. `Send_NC_QUEST_DB_DONE_REQ`: reserves money 100 and {exp 500, fame 0, no title} and one cell with a new key (kind 2);
   0x441A {NPCID, nQSC 10, QuestInfo (status 2, RepeatCount + 1, EndTime now), nMoney 100, nExp 500, nCur_*, lock L,
   1 × ItemCreate + attribute bytes}; L + 1; reward flag 1; `m_bWaitResult` 1.
4. Character server: item row, money, exp, quest record, logs (D04 §1.2) → 0x441B {nQSC 10, QuestInfo, L, 0xB41}.
5. Zone: apply L → 0x1033 (money), exp gain (level-up packets of Z03), 0x3001 (the item); diary record → DONE;
   quest counter title + 1; 0x4401 {Cmd 10, nID}; flag 0; `QuestNext` → the script's next command (or END).

---

## 6. Other entry points: NPC click, start request, kills, quest drops, Lua, GM

Besides the client's quest packets (§3–§5), a script starts from an NPC click or a 0x4414 start request, and quest
counters move on mob kills (the killer's party or raid shares them) and on Lua / Pine calls. All of these work on the
player's `CQuestZone` (`p+0x173e8`, `ShinePlayer::sp_QuestDiary.sqd_QuestDiary`).

### 6.1 NPC click and the start request 0x4414

```pseudo
# caller: ShinePlayer::InteractWithNPC FUN_004c4660 (Z02 §6.2, after 0x200A NC_ACT_NPCCLICK_CMD), with
#         mobId = npc.vt 0x708 (the NPC's mob ID, not its handle). Result 1 → QuestPlayer_NPCClick(mobId) and the
#         1000-unit range check; 2 → nothing; 0 → the NPC's own role / menu (0x201C), Z02 §6.2.
CQuestZone::QuestPlayer_NPCClickCheck(mobId) → int:                                @ FUN_005ba250
    if !m_pPlayer: return 0
    m_nClickNPCNo = mobId                                         # default speaker of SAY (§3.3)
    st = { hID = mobId }; CQuest::GetQuestStatusWithNPC(&st)      # FUN_00630f60: this NPC's best quest over the table (§4.4)
    if st.lpQuestData and st.lpQuestData.ID != 0xFFFF and m_ParsingQuestID == st.lpQuestData.ID
       and m_bWaitResult == 1 and m_QuestClickNPC == mobId:
        return 2                                                  # this NPC's dialog is open and waits for an answer
    if st.eResultState ∈ {4 REPEAT, 5 ABLE, 6 ING, 7 FAILED, 8 REWARD, 20 READ_ABLE}: return 1
    return 0                                                      # 0 NONE (no quest), 9 LOWABLE (never produced, §4.4)

CQuestZone::QuestPlayer_NPCClick(mobId) → int:                                     @ FUN_005c0250
    if !m_pPlayer: return 0
    m_nClickNPCNo = mobId
    st = { hID = mobId }; CQuest::GetQuestStatusWithNPC(&st)      # the same full-table scan again
    if (same "already waiting" test as above): return 2
    m_QuestClickNPC = mobId                                       # the NPC of the running script (0x440F compares it, §4.7)
    m_QSC.IsPigeonStartType = 0                                   # NPC dialog (the client's SAY uses it, §3.4)
    return QuestScriptRun(st.eResultState, st.lpQuestData.ID)     # §2.7: Start / Doing / End script by status
        # st.lpQuestData is not tested here; only reached after NPCClickCheck returned 1, which implies a quest
```

So an NPC that has a quest for the player (any of the six statuses) never opens its shop / menu: the quest script
replaces it, and `QuestNext` ends with `sp_EndOfTrade` (§3.2). Which quest and which script come from the priority table
of §4.4 (REWARD before ING before ABLE / FAILED / READ_ABLE before REPEAT), including the status mix-up of Z15-B27.
A click on the NPC whose dialog is still open is ignored (2) rather than restarting the script.

```pseudo
0x4414 NC_QUEST_START_REQ { u16 nQuestID }   ShinePlayer::sp_NC_QUEST_START_REQ      @ FUN_00578e90 (Z08 §3.2)
    !smo_IsActiveMode:  → 0x4415 NC_QUEST_START_ACK { u16 err = 0xB53 }
    (&p.sp_QuestDiary == NULL: assert "… NULL == sp_QuestDiary.sqd_GetZoneQuest()", 0xB51; can never be true, Z08-B15)
    r = QuestPlayer_NotCheckNPC(nQuestID); r != 0: → 0x4415 { 0xB50 }   # r == 0: no answer at all
        # client GameFrameWork::On_NC_QUEST_START_ACK FUN_0049c890: on 0xB50 it closes its quest window (+0x2f8) and
        # that window's child (+0x2a0); every other code is ignored

CQuestZone::QuestPlayer_NotCheckNPC(nQuestID) → int:   "start without an NPC"       @ FUN_005c03c0
    if !m_pPlayer or m_bWaitResult == 1: return 0                 # a script waits (also while a 0x441A is pending, §3.1)
    s = CQuest::GetNewQuestStatus(nQuestID)                       # computed status (§4.4)
    row = GetQuestData(nQuestID); if !row: return 0               # also the GM default 0xFFFF (§6.6)
    if Start.bNPC == 1: m_nClickNPCNo = Start.NPCID               # SAY speaker = the start NPC
    if s == 8 REWARD:
        first End.NPCMobList[i] (i < 5) with bNPCMob == 1 and TargetGroup == 0: m_nClickNPCNo = its NPCMobID
        # (original bug) Z15-B38: tests TargetGroup (entry +6), not NPCMobAction == 0 REWARD_OBJECT as GetRewardNPC
        # (§4.4) does, so a kill entry could be taken as the speaker; no 2016 quest gives a different NPC (data check)
    # otherwise m_nClickNPCNo keeps the last clicked NPC (original bug) Z15-B39: 5 start-able quests of the 2016 data
    # have no start NPC, so their SAYs without an NPC speak as whatever NPC the player clicked last
    if Start.bItem == 0:                                          # quests started by an item ("pigeon") always pass
        flag = s == 8 REWARD ? End.bIsWaitListProgress : Start.bIsWaitListProgress
        if flag == 0: return 0                                    # the quest needs its NPC: refused, no answer
    m_QSC.IsPigeonStartType = 1                                   # client: not an NPC dialog (§3.4)
    return QuestScriptRun(s, nQuestID)                            # §2.7; status not checked here: 0 for other statuses
```

`m_QuestClickNPC` is not set by this path: it keeps the last NPC click, so a 0x440F select-start (§4.7) after a 0x4414
start compares against that older NPC. Data *(2016)*: 663 quests are start-able this way (20 by a start item, the rest by
`Start.bIsWaitListProgress`), 616 can be finished this way (start item or `End.bIsWaitListProgress`), all with a reward
NPC. The client sends 0x4414 `{u16 questId}` from `GameFrameWork::NcQuestStartReq` (client FUN_004a58e0) in three places:
the epic-quest window's accept button (`EpicQuestWin::OnQuestAccept` FUN_00600950, selected quest), the quest window's
second button (`CQuestWin2::OnGiveUp` FUN_00602ef0, names from `names/client`): on the second list tab it always sends
0x4414 for the selected quest; on the first tab it sends 0x4414 when the client's own `GetNewQuestStatus` says 8 REWARD,
otherwise it opens a confirmation box whose OK posts frame message 0x101 → 0x4407 give-up; and frame message 0x102 in the
`GameFrameWork` message dispatcher FUN_00494890 (posted by a message box on close).

### 6.2 Mob kills: `so_KilledBy` → party / raid → the diary

```pseudo
# ShineMob::so_KilledBy FUN_00432760 (Z03 §8.1 mob death: EXP, drops), then:
    killer.vt 0xa84 so_GetRaid() == 0: PartyManufacture::pm_QuestCheck(&partymanufacture, sqd_MobDead, killer, mob, mob.sm_MobDataBox)
    else:                              RaidTask::rt_QuestCheck(sqd_MobDead, killer, mob, mob.sm_MobDataBox)

PartyManufacture::pm_QuestCheck(fn, killer, mob, box):                             @ FUN_004ccbf0
    if !killer: return
    party = killer.vt 0x550 so_PartyRegistNumber()
    party == 0xFFFF: killer.vt 0x7f4 so_ply_QuestCheck(fn, killer, mob, box)       # alone
    else: for each member object of CParty[party] (partycontainer):
              if so_DistanceSquar(killer, member) < 1 000 001: member.vt 0x7f4(fn, killer, mob, box)
              # within 1000 units of the killer (not of the mob); the killer is one of the members
RaidTask::rt_QuestCheck(fn, killer, mob, box) → u8:                                @ FUN_005ce710
    raid = killer.vt 0xa84; if !raid: return 0
    _GetRaidPlayer(&near, raid id (+4), mob, 1000) fails: return 0               # raid members near the mob (Z09 §11.5)
    for each near player: player.vt 0x7f4(fn, killer, mob, box); return 1
ShinePlayer::so_ply_QuestCheck(fn, a, b, c):  fn(this = p + 0x173e8 (the player's ShineQuestDiary), a, b, c)   @ FUN_005780c0 (vt 0x7f4)
ShineObject::so_ply_QuestCheck:               empty (non-players)                    @ FUN_00578070
ShineQuestDiary::sqd_MobDead(killer, mob, box): CQuestZone::QuestPlayer_NPCMobKill(&sqd_QuestDiary, mob)   @ FUN_00578170

CQuestZone::QuestPlayer_NPCMobKill(mob) → int:                                     @ FUN_005c08d0
    if !m_pPlayer or !mob: return 0
    box = mob.vt 0x710 so_mob_DataBoxforQuest()                   # FUN_00554fc0 = vt 0x70c so_mob_DataBox; mobs only
    if !box: return 0
    mobId = box.data.ID; list = []; any = 0; credited = 0
    for i in 0 … m_NumOfQuest−1:
        rec = GetQuestInfoByIndex(i); need rec.Status == 6 ING and row = GetQuestData(rec.ID)
        hit = 0
        for k in 0…4:
            if IsConnectionEnd(row, k, mobId):                    # §3.8: raid rule, bNPCMob, action 1 KILL, species match
                list.append({ nMobID = End.NPCMobList[k].NPCMobID, nQuestID = row.ID })   # also when already full
                if Data.End_NPCMobCount[k] < End.NPCMobList[k].NPCMobCount: Data.End_NPCMobCount[k] += 1; hit = credited = 1
        for a in 0 … row.NumOfAction−1:
            if IsConnectionAction(row, a, mobId): hit |= QuestActionMobKill(rec, row, a, mob)
        if hit:
            st = DoingQuestUpdateStatus(i)                        # §4.4; REWARD once every counter and item is complete
            (rec was ING) st == 8: vt 0x50(rec, row); st == 7: vt 0x54(rec, row)   # empty in the zone (§3.8)
        any |= hit
    if credited: Send_NC_QUEST_NOTIFY_MOB_KILL_CMD(list)
    return any

CQuestZone::QuestActionMobKill(rec, row, a, mob) → int:                            @ FUN_005bd000
    if !m_pPlayer: return 0
    switch row.Action[a].ThenType:
      1 DROP_ITEM:                                                # the only ThenType of the 2016 data (§1.2)
        item = (u16) ThenTarget
        need = GetSuccessItemCount(row, item) (§3.8); have = sp_GetItemInvenLot(item)   # FUN_005280d0: sum of the lot (vt 0x1c of each item's class) over every inventory cell holding item id `item`, limit = the charged-extended bag size
        if have < need and well512_GetRandom(1 000 000) < ThenPersent:     # chance in millionths
            n = (ThenCountMax − ThenCountMin) × well512_GetRandom(1 000 000) / 999 999 + ThenCountMin
            n = min(n, need − have)
            repeat n times: ShinePlayer::sp_QuestItemGet(p, item, mob)       # §6.3
            return 1                                              # also when n == 0
        return 0
      2 DO_SCENARIO: return Send_NC_QUEST_SCENARIO_RUN_CMD(ThenTarget)       # 0x440E (§3.6; no client handler)
      3 MOB_REGEN:   well512_GetRandom(1 000 000); return 0       # the roll is drawn and discarded
      other (4 CALL_PS): return 0
      # (original bug) Z15-B40: MOB_REGEN and CALL_PS do nothing (unused in 2016)

CQuestZone::Send_NC_QUEST_NOTIFY_MOB_KILL_CMD(list) → int:                         @ FUN_005bdb00
    if !m_pPlayer: return 0
    → player 0x440D NC_QUEST_NOTIFY_MOB_KILL_CMD { u8 NumOfActionQuest = |list|,
          MobOfQuest[] { u16 nMobID, u16 nQuestID } }             # 3 + 4n bytes; too long: assert "… Packet Too Long"
    return 1
```

Client: `GameFrameWork::On_NC_QUEST_NOTIFY_MOB_KILL_CMD` (client FUN_0049b170) → `CQuest::Recv_NC_QUEST_NOTIFY_MOB_KILL_CMD`
(client FUN_00728400): for each entry the shared-library `CQuest::QuestPlayer_NPCMobKill(nMobID, nQuestID)` (vt 0x08,
§4.5: the ING record of that quest, every list entry with that exact `NPCMobID` and action KILL, +1 up to the needed
count), then refreshes the quest-finish window. The server sends the row's `NPCMobID`, not the killed mob's, so the
client's exact-ID test works for species matches too; the client caps at the needed count, so the entries of already
full counters do no harm. The client also recomputes the status itself (its own diary).

Kill credit goes to every party member within 1000 units of the killer, or every raid member near the mob, each for
their own quests; a player in a raid gets credit only for RAID (type 8) quests, a player outside a raid only for the
other types (`IsConnectionEnd`, §3.8).

Who the killer is: `so_KilledBy` is ShineMob vt 0x5bc, and every damage path calls it with the object that dealt the
blow (`so_attack` FUN_0042cb80, `so_smash` FUN_0042c650, `so_skillsmash` FUN_0042ba90, `smo_AttackedDamage`
FUN_0042aeb0, damage over time `so_mobile_DamageOverTime` FUN_00409cd0 with the stored caster, skill damage
`SkillDamageSender::sds_TemplateStore` FUN_005803c0, `AxialListDeathAura::ali_Work` FUN_0055e190, NPC `DieAction` /
`DamageAbsorbAction` FUN_005c10c0 / FUN_005c11a0, Lua `cKillObject` FUN_005e6d40; gathering `sp_GatherComplete`
FUN_0046b2f0 kills the gathered object with the player as killer). Quest credit uses this last hitter, not the looter of
`el_FindLooter` and not the top damage dealer. What a non-player killer gives (resolved with `rtti.vtables`):

| Killer object | vt 0x550 party | vt 0xa84 raid | vt 0x7f4 QuestCheck | Quest credit |
|---|---|---|---|---|
| `ShinePlayer` | its party | its raid | the diary | as above |
| `ShineServant` (summon), `ShineMob`, `ShinePet`, … | 0xFFFF (FUN_005550b0) | 0 (FUN_00570b00) | empty FUN_00578070 | nobody, not even the summoner |
| `ShineMover` (vehicle) | the master's party (FUN_0055ee50) | the master's raid (FUN_00560480) | empty | master in a party: every member within 1000 of the mover; in a raid: raid members near the mob; master alone: nobody (original bug) Z15-B48 |

Z03 §8.1 calls FUN_005cbe70 `killer.questDiary.MobKill`; it is not quest code but the kill-count title. The only quest
path from a kill is the one above.

```pseudo
# in so_KilledBy, before the drops: killer.vt 0x420 so_GetCharacterTitle() (players: their title object FUN_0055a1b0;
# every other object: the shared dummy so_DefCharTitle, FUN_005550e0; what its m_pPlayer holds was not checked)
CCharacterTitleZone::CT_KillMob(mobId):                                            @ FUN_005cbe70
    row = MobDataBox[mobId]; missing → return; row.ID ≠ mobId → assert "MobDataBox::operator [] :Invalid mob index"; return
    if m_pPlayer.vt 0x4d8 level (u8) <= row.Level + 10:
        m_TitleValues[11].TitleValue += 1 (u64); m_TitleValues[11].bTitleSave = 1
        CheckNewTitle(11)                                    # title unlocking: Z18 (Z07 section)
```

```pseudo
# scripted kills: Pine `questmobkill` (Z09 §25.6) and Lua cQuestMobKill / cQuestMobKill_AllInMap (§6.5)
CQuestZone::QuestPlayer_ScriptMobKill(questId, mobId) → int:                       @ FUN_005c0b40
    if !m_pPlayer or questId == 0xFFFF or !MobDataBox[mobId]: return 0
    i = GetQuestIndex(questId); if i == −1: return 0
    rec = GetQuestInfoByIndex(i); need rec.Status ∈ {6 ING, 8 REWARD} and row
    for k in 0…4: IsConnectionEnd(row, k, mobId): append { NPCMobID, row.ID }; count < needed: +1, hit = 1
    if hit:                                                       # no QUEST_ACTION drops for scripted kills
        st = DoingQuestUpdateStatus(i); (rec was ING) st 8 → vt 0x50, st 7 → vt 0x54 (empty)
        Send_NC_QUEST_NOTIFY_MOB_KILL_CMD(list); return 1
    return 0                                                      # 0 = nothing left to count: the callers' repeat loops stop
CQuestZone::QuestPlayer_ScriptMobKill_All(mobId) → int:                            @ FUN_005c0cf0
    if !m_pPlayer or mobId > mdb_maxmobhandle or !mdb_index[mobId].data: return 0
    if data.ID != mobId: assert "MobDataBox::operator [] :Invalid mob index"; return 0
    the same for every diary record with status ING or REWARD; one 0x440D for all; returns 1 if any counter rose
```

The 2016 books use the scripted kill for the instance-dungeon "daily check" quests: `cQuestMobKill_AllInMap(map,
2665 / 2666 / …, "Daliy_Check_d_…", 5)` in 22 Lua dungeon scripts, and the Pine node `questmobkill` in 9 books (Z09 §25.6). A REWARD
quest still takes credit for an entry not yet full (several entries).

### 6.3 Quest drops

```pseudo
ShinePlayer::sp_QuestItemGet(p, itemId, mob):                                      @ FUN_00528240
    # only caller: QuestActionMobKill DROP_ITEM (§6.2); one call = one item of lot 1
    attr = itmattcontainer[itemId]
    item = ItemTotalInformation; iti_mkregnum(itemId, kind 2, zone, world) (item key); itemid = itemId
    attr.vt 0x14(itemId, &item, "-o")                             # default attributes (Z04)
    attr.vt 0x20(&item.iti_itemstruct, 1)                         # lot 1
    o = som_AllocObject(1); none: assert "DropItemGroupScope::ElementItemIdent::eii_dropitem : itembuf full" (copied text)
    looter = ShineMultiTypeHandle of p                            # owner = this player only
    o.vt 0x544 so_ItemDrop(handle, mob, &item, 1, &looter, questOnly = 1)   # FUN_0052a7a0: dropped at the mob (Z09 §11.3)
    result != 0x301: assert "ShineObjectClass::ShinePlayer::sp_QuestItemGet : Drop mark fail"   # object not freed
```

The drop lies on the ground like a normal mob drop (owner = the player, 20 s owner time, 60 s vanish, Z09 §11.3) with
`sdi_bQuestDropItem` = 1 (`so_drpitm_bQuestDropItem_Set/Get` FUN_00555320 / FUN_00555330). Looting it
(`so_drpitm_CanLooting`, Z09 §11.4) additionally requires `p.vt 0xe28` = `ShinePlayer::so_ply_QuestItemCheck` FUN_00561790
→ `CQuestZone::IsQuestDropItem(itemId)`:

```pseudo
CQuestZone::IsQuestDropItem(itemId) → int:                                         @ FUN_005bc900
    1 if some diary record with Status 6 ING has, in its row, an Action[a] with ThenType 1 DROP_ITEM and
      (u16) ThenTarget == itemId; else 0
```

So a quest drop can be picked up only while the player still has a quest in progress that drops it; the item goes into
the normal inventory (type 9) and counts for `End.ItemList` through the item-gain events (§4.5, `so_ply_ItemLotChange`).

The character inventory also has a 5-cell quest box (`CharacterInventory::ci_QuestBox`, `ItemQuestItemBox` ctor
FUN_006448b0 / dtor FUN_006430e0, `ib_BagSizeInput` FUN_00643140 = 5 cells of 0x74 bytes), registered as inventory type
7 in `CharacterInventoryManager` (`cim_quest` FUN_00642e10, `charinvenman.cim_Array[7]`) and cleared at the map login
(`sp_NC_MAP_LOGIN_REQ`). No quest function of the 2016 zone reads or fills it *(no other writer found)*; Z04's inventory
type table has no row 7.

### 6.4 Other quest helpers reached from the world

- `MobDataBox::mdb_IsSpeciesDistanceByQuest(id1, id2, col)` FUN_00641020 (Z09 §28.8): the species match of
  `IsConnectionEnd` / `IsConnectionAction`; `col` = the entry's `TargetGroup` = a `QuestSpecies.MobGroupName` column
  (`QuestSpecies` table, `BinaryDataBox<QuestSpecies>::bdb_ReadData` FUN_00641410, loaded with the mob tables, Z09 §5.1).
  So "kill 10 of X" also counts the mobs that share X's group name in that column.
- `ShinePlayer::so_ply_Return2Quest` FUN_005bfa80: end of a CALLPS film (§3.7).
- `AxialQuesterFind` (ctor FUN_00429bd0, `ali_Work` FUN_00429c80): only used by Lua `cGetQuestHero_NPC` (§6.5).

### 6.5 Lua functions (handed over by Z09 §14.9)

Lua C functions of the zone (registration and argument conventions: Z09 §14). Numbers are read with `lua_tonumberx`
(missing → 0), strings with `lua_tolstring`. "Player" = `som_GetObject(handle)`.

```pseudo
cQuestMobKill(handle, questId, mobIndexName)                                       @ FUN_005d6010
    o = som_GetObject(handle), not leaving (vt 0x300 so_IsEmpty != 1), with a diary (vt 0x808 so_ply_QuestDiary)
    q = (int) questId == −1 ? 0xFFFF : (u16) questId              # nil → 0 (no such quest: nothing)
    mob = mdb_2MobID(mobIndexName); 0xFFFF → nothing
    q == 0xFFFF ? QuestPlayer_ScriptMobKill_All(mob) : QuestPlayer_ScriptMobKill(q, mob)   # one credit; 0 results
cQuestMobKill_AllInMap(mapIndex, questId, mobIndexName, count)                     @ FUN_005d6150
    map = fc_FindMap(mapIndex), with a centre object; q as above; mob as above
    players = AxialListNearScanObjectType(kind 2) over so_AllInMap of the centre object
    limit = min(number of players, (int) count)
        # (original bug) Z15-B41: as Z09-B109 (Pine questmobkill): the credits per player are capped by the number
        # of players on the map; a player alone in the dungeon gets 1 of the 5 "daily check" kills
    for each player (not leaving, with a diary): repeat up to limit times while the ScriptMobKill call returns ≠ 0
    0 results
cGetQuestHero_NPC(questId, npcHandle, range) → (handle, partyRegnum) | nothing       @ FUN_005d8f60
    npc = som_GetObject(npcHandle) (arg 2 nil or no object: nothing)
    f = AxialQuesterFind{ aqf_QuestID = questId, &handle, &party }  (FUN_00429bd0)
    so_AllOfRange(npc, allofrangearg, npc position, range, no sector, f, 0, 0xFFFF)
    AxialQuesterFind::ali_Work(f, _, o):                                            @ FUN_00429c80
        o.vt 0x4d0 so_ObjectType == 2 (player) and o.vt 0x484 smo_GetMode() != 0: handle = o.handle,
        party = o.vt 0x550 so_PartyRegistNumber(); stop the scan
    stopped: return handle, party (2 numbers); else nothing
    # (original bug) Z15-B42: aqf_QuestID is stored but never tested: the "quest hero" is the first player in
    # range whatever their quests. No 2016 Lua script calls it
cGetQuestHero_ItemUse(?, mapIndex, itemIndexName)                                  @ FUN_005d9140
    reads its arguments, finds the map, its centre object and the item ID (idb_2itemid), then returns nothing
    # (original bug) Z15-B43: a stub with no effect and no result; unused in 2016
cQuestResult(mapIndex, "Success" | "Fail") → 1 | nothing                           @ FUN_005e30d0
    map with a centre object; word compared case-sensitively ("Success" / "Fail"; anything else: nothing)
    so_AllInMap(centre, AxialListKQEndLua{0x16, 0x12 Success / 0x13 Fail} (ctor FUN_004289d0), 0)
        # its vftable slot 0 is AxialListKQEnd::ali_Work FUN_00429e00 (identical code), Z09 §25.6: per player
        # so_ply_KQSuccess / KQFail (title counters), GameLog 0x0442 NC_LOG_GAME_KQ_LEAVE, 0x5812 / 0x5813
    FieldMap::fm_ClearObject(map, 0x1b0)                          # NPCs, mobs, doors, bandits removed (Z09 §24.8)
    return 1
cQuestResult_Individual(handle, "Success" | "Fail") → 1 | nothing                  @ FUN_005ecca0
    o player (so_ObjectType 2): o.vt 0x304 so_SendProtocol(0x16, 0x12 / 0x13) → empty 0x5812 NC_KQ_COMPLETE_CMD /
        0x5813 NC_KQ_FAIL_CMD (client complete / fail window, Z09 §24.8); return 1   # like Pine sendquestresult
cReward(mapIndex, "KQ") → 1 | nothing                                              @ FUN_005df060
    map with a centre object, word "KQ" (case-sensitive; another word: return 1 without effect)
    map.fm_KQHandle == 0xFFFFFFFF: assert "cReward : No KQ info"; nothing
    so_AllInMap(centre, AxialListKQRewardLua(kqHandle) (ctor FUN_004288c0), 0)
        # slot 0 = AxialListKQReward::ali_Work FUN_00428490 (Z09 §25.6): enough kills → so_ply_KQRewardStruct (Z16),
        # else 0x5823 NC_KQ_NOREWARD_CMD {0x1104}
    return 1
cRewardItem_CharInven(handle, itemIndexName, count)                                @ FUN_005d6a10
    o player, not leaving, on a map; item ID by name with ItemInfo and ItemInfoServer rows
    if (int) count > 0: o.vt 0x8b4 so_scene_CreateItem(itemId)    # Z09 §24.2 (FUN_0050d770): one item, count ignored
    0 results                                                     # used once: Promote/Job2_Forest (count 1)
cClassChangeOpen(handle) → 1 | nothing                                             @ FUN_005ed720
    o = som_GetObject(handle); p = o.vt 0xbbc (ShinePlayer cast); p: ShinePlayer::sp_OpenClassChangeMenu(p); return 1
    # used by the AI scripts ClassChangeMaster01…03 (the class-change NPCs)
```

`cGetTutorialInfo` FUN_005e7450 and `cProgressTutorial` FUN_005e72f0 (Z09's list also gives them to Z15) are already
documented in Z09 §28.13.

```pseudo
ShinePlayer::sp_OpenClassChangeMenu(p):                                            @ FUN_0051fd10
    allowed modes: static cmc.cmc_AllowMode = 0x46 (bits 1, 2, 6)
    p's mode not allowed: p.vt 0x308 so_SendErrorCode(0x0C, 0x60, 0x3681) → 0x3060 { u16 0x3681 }   # 2-byte payload
    elif !p.vt 0x49c so_CharacterClass(): assert "…sp_NC_ITEM_CLASS_CHANGE_REQ : Try to use invalid class" (copied);
        so_SendErrorCode(0x0C, 0x5F, 0x3682) → 0x305F NC_ITEM_CLASS_CHANGE_ACK { u16 0x3682 }
    else:
        g = ccdb_GetThirdClassGroup(class)                        # CharClassDataBox (Z07)
        g ∈ {UCT_NONE, UCT_SAVIOR_ONLY}: nNewClass = 0, price 0
        else: nNewClass = ccdb_BitToClass(ccdb_UseClassTypeToBit(g) ^ ccdb_ClassToBit(class))   # the other class of the group
              own = ccdb_ClassToUseClassType(class)
              price = Σ ItemInfo[skill.InxName].BuyPrice over every learned active skill (SkillDataBox, csl_IsLearn)
                      whose UseClass is g or own, + Σ ItemInfo[passive.InxName].BuyPrice over every learned passive
                      (bit set in sp_Passive) whose skill-book item's UseClass is g or own   # u64, carry kept
        → 0x3060 NC_ITEM_OPENCLASSCHANGEMENU_CMD { u8 nNewClass, u64 nTotalPrice, u16 nError = 0x3680 }   # payload 11
    # client GameFrameWork::On_NC_ITEM_OPENCLASSCHANGEMENU_CMD FUN_0049dcd0: ClassChangeWin SetChangeClassID(nNewClass),
    #   SetMoney(price low, high), show; nError is not read
```

The menu offers the switch to the other class of the player's third-job group, priced at the skill books of the skills
learned for it *(inferred: the cost of the books the change converts; the change itself is 0x305E, Z04 §12.10)*. The
refusal for a wrong mode reuses opcode 0x3060 with only the 2-byte code, which the client reads as the 11-byte menu
(class = 0x81, price from stale buffer bytes) and opens the window anyway (original bug) Z15-B44.

### 6.6 GM commands

Already documented by Z11 (done): `&queststart [id]` (`ac_QuestStartReq` FUN_00419500) and `&questread [id]`
(`ac_QuestReadReq` FUN_00419540) build a fake 0x4414 / 0x4416 and call the handlers of §6.1 / §4.7 (Z11 §3.4; without
an id the quest is 0xFFFF and nothing happens). `&questrecieve` FUN_0041c140, `&questgiveup` FUN_0041c190 and
`&questcomplete` FUN_0041c1e0 are empty (Z11 §4.6).

---

## 7. Quest result codes 0xB41…0xB5A

Quest-local numbers without a client error-table text (the client table has only an empty 0x0B48 entry); no 2016 or
2017 PDB enum names them. Script errors 0xC00…0xC10 are §3.10; the DONE reward codes 0xBC2…0xBC5 belong to the Character
server (D04 §1.2, §5.3 here). Every number of the range was searched in the zone, Character and WM code. 0xB5B…0xBFF hold no quest codes: the 0x0Bxx
block is shared with the item-DB results (0xB01 produce, 0xB81 / 0xB82 destroy (D03), 0xBC1 quest-reward success and
0xBC2…0xBC5 its failures (D04 §1.2, §5.3, §5.5 here)); no quest or scenario function of the zone uses another number
of 0xB5B…0xBFF.

| Code | Set by | Meaning | Client |
|---|---|---|---|
| 0xB41 | Character server answers 0x4404 / 0x4406 / 0x440A / 0x4419 / 0x441B (D04 §1); zone 0x4408 (§4.7) and 0x4410 `err` (§4.7) | success | 0x4408: "Abandoned <%s> quest."; 0x4410 ignored |
| 0xB42 | Character server 0x4406 CLEAR answer | delete of the quest record failed (also when no record existed) | zone → script error 0xC00 (§3.5) |
| 0xB43 | Character server 0x4404 SET_INFO, 0x4419 READ, 0x441B DONE | storing the quest record failed | zone → 0xC0E (SET_INFO, DONE), 0x4417 READ_ACK {0xB43} (no handling, §4.7) |
| 0xB44 | — | not used in 2016 | |
| 0xB45 | 0x4408 GIVE_UP_ACK (`Recv_NC_QUEST_GIVE_UP_REQ`, §4.7) | give up: no diary record or no quest row | "Failed to give up <%s> quest." |
| 0xB46 | Character server 0x440A GIVE_UP; zone 0x4408 after a repeat give-up (SET_INFO nQSC 28 failed or no record, §4.7) | give up could not be stored | "Failed to give up …" |
| 0xB47 | 0x4410 SELECT_START_ACK (§4.7) | select-start refused (no row, the NPC does not offer it, same quest, another NPC, or the script did not open) | 0x4410 ignored |
| 0xB48 | — | not used in 2016 (the client's error table has an entry without text) | |
| 0xB49 | 0x4408 (§4.7) | give up less than 10 s after the last script answer | "Failed to give up …" |
| 0xB4A…0xB4F | — | not used | |
| 0xB50 | 0x4415 START_ACK (§6.1) | the start request opened the quest script | closes the quest window |
| 0xB51 | 0x4415 (§6.1) | no quest object (dead check, Z08-B15) | ignored |
| 0xB52 | — | not used | |
| 0xB53 | 0x4415 (§6.1) | start request while not in an active mode | ignored |
| 0xB54…0xB57 | — | not used | |
| 0xB58 | 0x4417 READ_ACK (§4.7) | quest read stored (status 20 READ_ABLE) | debug output "%d ??? Read OK" only (`On_NC_QUEST_READ_ACK` client FUN_0049c8e0) |
| 0xB59 | 0x4417 (§4.7) | read refused: no row, or computed status DONE / ING / FAILED / REWARD | ignored (same handler) |
| 0xB5A | 0x4415 (sic, Z15-B28) from the 0x4416 handler (§4.7) | read request while not in an active mode | ignored |

A refused 0x4414 (`QuestPlayer_NotCheckNPC` 0) and a refused give-up of Z08-B6 (§4.7) send no code at all.

Two quest packets carry codes outside this range. `0x4413 NC_QUEST_ERR { u16 err }` *(pdb2017 name)* is never sent by the
2016 zone, WM or Character server (no send site, no `so_SendErrorCode(0x11, 0x13, …)`); the client handler FUN_0049bda0
would show the error-code text of `err` (client FUN_00416430). `0x4420 NC_QUEST_JOBDUNGEON_LINK_FAIL_CMD { u16 nError }`
is sent only with 0x30C2 (job-change dungeon refused in the current mode, §3.6); the client FUN_004b4430 reacts to 0x30C2
only ("You cannot teleport to the saved locaion in current state.").

---

## 8. Original-server bugs

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
| Z15-B24 | `CQuest::IsQuestArea` FUN_0062fab0 (client FUN_007284d0 too) | distance = trunc(sqrt(\|x − cy\| + \|y − cy\|)): the centre's X is never read and the differences are not squared | start / end location conditions accept a wrongly placed, far too large area; latent (no 2016 quest has a location condition) | sqrt((x − cx)² + (y − cy)²) <= range |
| Z15-B25 | `CQuest::QuestPlayer_TimeProcess` FUN_00630e50 (client FUN_00729780 too) | adds `prev − now` (negative) to `End_RunningTimeSec` | the counter wraps to ≈65535 after one second, `IsRewardAbleQuest` fails forever: a time-limited quest can never be finished; latent (no 2016 quest has a time limit) | add `now − prev` |
| Z15-B26 | `CQuest::QuestPlayer_DestroyItem` FUN_00630920 | re-evaluates and stores the status of every record that lists the item, whatever its status | a REPEAT / READ_ABLE record whose start conditions fail at that moment becomes NONE, which is sticky: the quest cannot be restarted until the next login | only re-evaluate ING / REWARD records |
| Z15-B27 | `CQuest::GetQuestStatusWithNPC(st)` FUN_00630f60 | a tie-break between two quests of the same status rank replaces the quest but keeps the previous quest's status | an NPC click (§6) runs the Doing script of a quest not yet accepted, or the Start script of a FAILED quest, when ABLE / READ_ABLE and FAILED quests share an NPC | copy the status with the quest |
| Z15-B28 | 0x4416 `sp_NC_QUEST_READ_REQ` FUN_00578f90 | the "not active" refusal is sent as 0x4415 NC_QUEST_START_ACK {0xB5A} | wrong opcode; ignored by the client (acts on 0x4415 only for 0xB50) | `_ErrorSendPlayer<PROTO_NC_QUEST_READ_ACK>` |
| Z15-B29 | `_ErrorSendPlayer<PROTO_NC_QUEST_READ_ACK>` FUN_00578d60 (0x4416 refusal, 0x4419 DB error) | writes only `err`; `nQuestID` is the previous packet's bytes | stale quest id on the wire; no visible effect (client prints a debug line only) | write nQuestID |
| Z15-B30 | `Send_NC_QUEST_DB_GIVE_UP_REQ` FUN_005bae70 | sends 0x4409 only if the u32 at offset 4 of the shared send buffer is non-zero (same as Z15-B9) | a give-up of a non-repeatable quest is randomly not sent; the client never gets 0x4408 | drop the test |
| Z15-B31 | `CQuest::Recv_NC_CHAR_QUEST_DONE_CMD_ACK` FUN_0062f7c0 / `_READ_CMD_ACK` FUN_0062f890 | builds each login record on the stack, writing only ID, Status (and EndTime) | DONE / READ records carry stack garbage in StartTime, RepeatCount, progress and counters; a daily quest accepted again sends that garbage to the DB in 0x4403 | zero the record first |
| Z15-B32 | client `On_NC_QUEST_GIVE_UP_ACK` FUN_004ba720 vs zone `Recv_NC_QUEST_DB_SET_INFO_ACK` nQSC 28 | after giving up a repeatable quest the client stores 20 READ_ABLE, the zone and the DB 4 REPEAT | the client lists the quest as new instead of repeatable until the next login | the same status on both sides |
| Z15-B33 | `Recv_NC_QUEST_DB_SET_INFO_ACK` FUN_005bf280 | clears `so_SetIsQuestRewardReq` and `m_bWaitResult` for every answer, also for a repeat give-up unrelated to the script | a give-up answer during a pending 0x441A or 0x4403 lifts the reward guard of `QuestStart` and the script wait early (narrow window) | clear them only for the script's own command |
| Z15-B34 | `Recv_NC_QUEST_DB_DONE_ACK` FUN_005bfb30 (failure) | frees the lock, sends 0xC0E, clears the reward flag, but leaves `m_bWaitResult` 1 and the script open | `QuestNext` and 0x4414 stay blocked until another script is opened (as Z15-B17) | `QuestClose()` after the error |
| Z15-B35 | `Recv_NC_QUEST_DB_DONE_ACK` FUN_005bfb30 (success) | does not compare `QuestInfo.ID` / `nQSC` with the running script; clears `m_bWaitResult` and calls `QuestNext` | a Doing/End script opened while the reward was pending (only `QuestStart` is refused) is resumed past a `SAY` that is still waiting, with a stale RESULT | resume only when the answer belongs to `m_ParsingQuestID`'s `DONE` |
| Z15-B36 | `Send_NC_QUEST_DB_DONE_REQ` FUN_005bbe60 | `nCur_CT_ElementValue = GetTitleStatus(CT_Type, nCur_CT_ElementValue)`: the element argument is the still-zero target byte | the DB gets the state of element 0 instead of `CT_ElementNo` (no TITLE reward in the 2016 data) | `GetTitleStatus(CT_Type, CT_ElementNo)` |
| Z15-B37 | `QuestNext` DONE FUN_005bdef0 / `Send_NC_QUEST_DB_DONE_REQ` | every refusal of 0x441A (reward already pending, an open item lock, missing record) is reported as 0xC01 | the client shows "Inventory full. Cannot receive the reward item." with free cells | a distinct code (e.g. 0xC0C/0xC0E class) |
| Z15-B38 | `QuestPlayer_NotCheckNPC` FUN_005c03c0 | for a REWARD quest picks as SAY speaker the first `End.NPCMobList` entry with `bNPCMob == 1` and `TargetGroup == 0` | a kill-target entry could become the speaker; no 2016 quest gives a different NPC than `GetRewardNPC` | test `NPCMobAction == 0` as `GetRewardNPC` |
| Z15-B39 | `QuestPlayer_NotCheckNPC` FUN_005c03c0 | `m_nClickNPCNo` is only overwritten when the quest has a start NPC (or a reward NPC for REWARD) | 0x4414-started quests without a start NPC (5 in 2016) use the last clicked NPC as default SAY speaker | reset to 0xFFFF / a neutral speaker |
| Z15-B40 | `QuestActionMobKill` FUN_005bd000 | ThenType 3 MOB_REGEN draws a random number and does nothing; 4 CALL_PS has no case | quest actions other than DROP_ITEM / DO_SCENARIO are silently ignored (unused in 2016) | implement or reject at load |
| Z15-B41 | Lua `cQuestMobKill_AllInMap` FUN_005d6150 | the per-player repeat count is `min(players on the map, count)` (as Z09-B109) | a player alone in a dungeon gets 1 of the 5 "daily check" kills | repeat `count` times per player |
| Z15-B42 | Lua `cGetQuestHero_NPC` / `AxialQuesterFind::ali_Work` FUN_00429c80 | `aqf_QuestID` is never tested | returns the first player in range, not one with the quest (unused in 2016) | require the quest in the player's diary |
| Z15-B43 | Lua `cGetQuestHero_ItemUse` FUN_005d9140 | looks up map and item, then returns nothing | no effect, no result (unused in 2016) | finish or remove |
| Z15-B44 | `sp_OpenClassChangeMenu` FUN_0051fd10 (Lua `cClassChangeOpen`) | a wrong mode is answered with `so_SendErrorCode` on opcode 0x3060 (2-byte payload); an invalid class with 0x305F | the client reads the short 0x3060 as the 11-byte menu and opens the class-change window with class 0x81 and a stale price | send the full struct with `nError` 0x3681 (and have the client check it) |
| Z15-B45 | `ZoneRingPacketFindJobDungeon::zrpb_Request` FUN_005a8d30 (SCENARIO 8/11/12/13) | NULL arguments or a map that forbids links out (`so_ply_IsLink_OutMap_AndSendErrorMsg` 0) return without an ack | the quest script stays on SCENARIO without a wait and never resumes | answer the ack with nResult 0 / 2 |
| Z15-B46 | `IsConnectionAction` FUN_005b9b60 (the only `Action[].IfType` reader) | accepts only IfType 1 MOB_KILL | IfType 2 GATHER / 3 TOUCH_OBJECT / 4 AREAINFO actions never fire: the 18 GATHER entries of quests 20005 / 20006 (flower 5100 → item 3486) never drop | test each IfType against its event (gather complete, object touch, area) |
| Z15-B47 | `sp_IsQuestRewardReq` p+0x2AA50 (§5.4) | set by DONE_REQ, cleared only by quest DB answers; not reset by the `ShinePlayer` constructor FUN_0055bc80 or at login | a lost 0x441B blocks quests and many item uses for the session and for the next character on that pooled object | clear it in the player init and on DB reconnect / timeout |
| Z15-B48 | `pm_QuestCheck` FUN_004ccbf0 with a `ShineMover` killer (§6.2) | the mover forwards party and raid to its master but its own `so_ply_QuestCheck` is the empty base | a master alone gets no quest credit for mover kills, a master in a party or raid does (party members, master included, within 1000 of the mover) | credit the master when alone too |

## 9. Not reconstructed / uncertain

- Whether the `CQuestZone` objects and the `ShinePlayer` objects are zero-filled when the player pool is allocated
  (decides whether Z15-B2 crashes or reads garbage, and the first value of the reward flag `sp_IsQuestRewardReq`, §5.4).
- `IS_ABSTATE` always writes RESULT (§3.3); its 2016-struct target variable is unused by parser and interpreter.
- Where the 2016 client starts a client-side SCENARIO (Cmd 3 has no case in `On_NC_QUEST_SCRIPT_CMD_REQ` FUN_004ba970;
  `ScenarioMgr::RunScenario` FUN_006b00b0 is reached from FUN_0047b7c0 (a chat command) and the dialog parser
  FUN_005f80f0): not traced; and what scenario 15 (server: no packet, no wait) does on the client (`Scenario_15`).
- Whether the client closes its NPC dialog by itself after the last SAY (the server never sends END, Z15-B12).
- Whether anything fills inventory type 7 (`ci_QuestBox`, §6.3); no writer was found from the quest functions.
- Which client message box posts frame message 0x102 (the third 0x4414 sender, §6.1): not traced.
- Whether other 2016 data sets (other regions' `QuestData.shn`) use the latent paths this item marks as unused in the
  shipped data (`PROGESS`, names from `QuestParser.txt`, location / time-limit conditions, MOB_REGEN / CALL_PS actions,
  TITLE rewards): the latent bugs Z15-B1…B3, B24, B25, B36, B40 only matter then *(data)*.
- The DB side of every quest request is D04 §1; where this document states a DB result (0xB41 success, 0xB42 / 0xB43 /
  0xB46 failures) it relies on D04's reading, not on a capture; no quest traffic was checked against a capture.

## 10. Coverage boundary

The sweep listed every zone function whose PDB name contains `quest` or `scenario`, every function referencing a quest
string in `strings.tsv`, every quest / scenario opcode in `opcodes.json`, and the callers and callees of every function
cited in §1–§7, and compared them with the addresses cited in `docs/pseudocode/`. What is left:

| Found (function / packet / table / behaviour) | Covered by | Argument |
|---|---|---|
| Kingdom quest objects: `KingdomQuest::KingdomQuestContainer` (ctor FUN_00499a40, `kqc_MapUseCheck` FUN_00495710), `KQElement` (`operator=` FUN_00499140, `kqe_GetKQLimitMin` FUN_005e4d20), `KQPlayerInform` / `KQPlayerInfoList` (FUN_00495250, FUN_00495260, FUN_00496d70, FUN_00498ba0, FUN_00498c40, FUN_00498e90), `KingdomQuestEntrance` (FUN_004950f0, FUN_00495140, FUN_004960a0, FUN_004960f0), `KingdomQuestGateKeeper` ctor FUN_00495150, `ListIteratorKingdomQuestMapFind::lid_Call` FUN_00495620, `BinaryDataBox<KINGDOM_QUEST_REW>::bdb_ReadData` FUN_0049a860, their `List<>` helpers | Z16 (open; Goal: "the per-event state behind them (KQ element, players, scores, rewards …)") | KQ is a separate event system that only shares the word "quest"; it never touches `CQuestZone`, the diary or `QuestData.shn`. Its Lua / Pine reward hooks are linked from §6.5 |
| `so_ply_KQRewardStruct`, `so_ply_KQSuccess` / `KQFail` reached from `AxialListKQReward::ali_Work` FUN_00428490 (§6.5) | Z16 (open, same Goal line) | KQ reward and title counters, not quest-diary state |
| Job-dungeon ring: `ZoneListenSession::zls_NC_QUEST_JOBDUNGEON_FIND_RNG` 0x441F FUN_005bfde0, `ZoneRingPacketFindJobDungeon::zrpb_Success` FUN_005a8f40, the ring transport behind `zrpb_Request` FUN_005a8d30 | Z14 (open; plan line 14 lists "`0x441F` (job dungeon) FUN_005bfde0" and `ZoneRingPacketFindJobDungeon`) | §3.6 documents the quest side up to the request (SCENARIO 8/11/12/13, `so_ply_IsLink_OutMap_AndSendErrorMsg`, 0x4420, Z15-B45); finding / creating the instance in another zone is the zone-ring protocol |
| `RaidTask::rt_Broadcast` profiler label copied from `pm_QuestCheck` | Z14 (open; raid internals) | cosmetic: a wrong profiler string in a raid function; the raid quest path itself is §6.2 |
| Other `ZoneRingPacket*::zrpb_Request` / `zrpb_Success` (FindPlayerByNormalUser FUN_005a7430, RefreshWeddingInfo FUN_005a91c0, …) and `AxialListRescueRequest` FUN_005668f0 | Z14 (open; zone-ring storage handlers) | matched the name sweep only through "Re**quest**"; no quest logic |
| `CCharacterTitleZone::CheckNewTitle(40)` called from the DONE answer (§5.3) | Z18 (open; plan: "Z07 section: `CCharacterTitleZone::CheckNewTitle`") | title unlocking is the character-title subsystem; §5.3 documents the call and its argument |
| Pine quest nodes (`questresult`, `reward`, `questmobkill`, `returnvalue`), Lua scenarios (`LuaScriptScenario`, its `std::map` helpers FUN_00440f10 / FUN_00441300 / FUN_005c83d0), scenario book shelf (`scenarioshelf` init / dtor FUN_00698190 / FUN_0069e6d0), map scenario packets 0x6Cxx (`sp_NC_SCENARIO_AREAENTRY_ACK` / `AREALEAVE_ACK`) | Z09 (done): §25.6, §14.9, §22.5, §22; tutorial Lua §28.13 | map-script engine; §6.5 documents every Lua function that calls into the quest engine |
| Quest DB procedures behind 0x4403 / 0x4405 / 0x4409 / 0x441A (Character server) | D04 (done) §1.1, §1.2 | the zone side of each request and answer is §3.5, §4.7, §5.2, §5.3 |
| Where the WM takes the 0x441C reset instants from | Z08 (done) §3.4 (zone receiver FUN_005a6520); WM timer `CDailyQuestTimer` W05 (done) §2.3 | §5.6 starts at the zone handler; the period arithmetic on the zone is §4.4 / §4.6 |
| Quest GameLog packets 0x043C NC_LOG_GAME_QUEST_GET / 0x043D NC_LOG_GAME_QUEST_COMPLETE, 0xC80F NC_SYSLOG_CHAR_QUEST_STARTED | D05 (done) §2.3, §6 | the zone sends 0xC80F from the SET_INFO answer (§4.7); the GameLog server's handling is D05's |
| ITEMDB quest packets 0x3404 NC_ITEMDB_QUESTALL_REQ … 0x3409, 0x345D NC_ITEMDB_QUESTITEMGET_REQ, 0x345B / 0x345C QUESTREWARD | D03 (done) §7.1, §7.5 | Character-server item procedures; the zone's (dead) 0x345C path is §5.5 |
| WM side of the diary lists 0x1021 / 0x1022 / 0x10CD / 0x10D6 and the char-save chunks 0x4010 | W05 (done) §5.4 (0x4010 row: `CharDataStore` FUN_00433210) | the WM caches and forwards the blobs; the zone's merge and save are §4.2 and §5.7 |
| GM commands `&queststart`, `&questread`, `&questrecieve`, `&questgiveup`, `&questcomplete` | Z11 (done) §3.4, §4.6 | §6.6 links them; their quest calls are the functions of §2.7 / §4.7 |
| `CCharacterTitleZone::CheckNewTitle(11)` called from `CT_KillMob` FUN_005cbe70 (§6.2; Z03 §8.1 misnames it a quest-diary kill) | Z18 (open; plan: "Z07 section: `CCharacterTitleZone::CheckNewTitle`") | `CT_KillMob` itself is documented in §6.2; the unlock check is the title subsystem |
| NPC menu path that reaches `QuestPlayer_NPCClick` | Z02 (done), NPC menus | §6.1 starts at the click check Z02 calls |
| Compiler / library code with no behaviour: `QUEST_DATA` hash-map and list instantiations FUN_00635b00…FUN_00636760, `std::_Uninit_def_fill_n<MobOfQuest>` FUN_005c0060, `BinaryDataBox<QuestSpecies>` dtors FUN_00641400 / FUN_00641990, static init / atexit of `icll_Releaser_QuestReward` FUN_00696240 / FUN_0069d230 and of `gQuestData` FUN_0069f880, `cmc` atexit destructors FUN_0069e6e0 / FUN_0069e6f0 / FUN_0069f790 / FUN_006a06c0, `__unwindfunclet$…` handlers | none needed | containers, static construction / destruction and exception unwinding; the objects they build are documented (§1.1 hash map, §5.3 releaser, §6.3 `QuestSpecies`) |

No follow-up item was created: every remaining function belongs to an open item (Z14, Z16, Z18) whose plan names it,
or to a done item whose output already documents it.
