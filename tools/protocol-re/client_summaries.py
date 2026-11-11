"""Hand-written summaries of client packet handlers (work item C01), read from Fiesta.bin decomp.
Key: "0xOPCODE" (all scenes) or "0xOPCODE@<scene>" (one scene). Offsets are payload offsets (after the opcode).
Used by client_handlers.py; everything without an entry gets an "(auto)" summary.
"""
_SEED = "{u16 seed} -> Net.SetSeed (vtable +0xc) for the client->server XOR cipher; then "
_IGN = "accepted and ignored (dispatcher returns size)"
_DUPLOGIN = "{u16 reason}: if reason == 0x683 (same account logged in elsewhere) set the first field of global object DAT_00b1b420 to 1"
_OPT = ("character option blob {u8 present, blob}: if present and the blob's 6-byte header equals the client's "
        "built-in default header, copy it into the option store and mark loaded; else mark 'not stored'")

SUMMARY = {
    # ---- Net (handled before every scene) @ FUN_006d2fa0
    "0x0804": "heartbeat: if heartbeats are enabled (net+0x10048) send 0x0805 (no payload) and reset the timer; "
              "handled by the Net object before the scene dispatcher",
    "0x080e": 'server clock from the WM (W01) {u8 hour, u8 minute, u8 second} -> clock base seconds = (h*60+m)*60+s plus local tick (FUN_00682580 on the DAT_00b1b420 object); handled before the scene dispatcher',
    "0x0819": "swallowed by the Net object (no action, never reaches a scene)",
    # ---- login scene (AccountFrameWork @ FUN_0046f4d0), see docs/pseudocode/login-server.md §8
    "0x0807@AccountFrameWork": _SEED + "send 0x0C65 {char[64] client version '20151116141627'} @ FUN_0046eb30",
    "0x0c05@AccountFrameWork": _IGN,
    "0x0c09@AccountFrameWork": "login failed {u16 code}: message ErrMsgTable::GetErrMsg(code) (client-error-codes.json); "
                               "close the login connection",
    "0x0c0a@AccountFrameWork": "world list: store worlds, show world selection @ FUN_0046edd0",
    "0x0c1c@AccountFrameWork": "world list (refresh): store worlds, show world selection @ FUN_0046eae0",
    "0x0c0c@AccountFrameWork": "world select result {u8 status, char[16] ip, u16 port, validate key (see login-server.md §8)}: status 0..5 "
                               "show closed/maintenance/empty/reserved/unknown/full text; 6..10 remember validate "
                               "key and connect to ip:port (World manager)",
    "0x0c17": _DUPLOGIN,
    "0x0c66@AccountFrameWork": "version mismatch: message 'You client version is different from the Server version...'",
    "0x0c67@AccountFrameWork": "version ok: open login UI and send 0x0C04 (anti-hack key) @ FUN_0046f470",
    "0x2011": _IGN,
    # ---- world-manager login (LoginWorldNetFrameWork @ FUN_00471a50)
    "0x0807@LoginWorldNetFrameWork": _SEED + "send 0x0C0F {0x140 bytes: account block (FUN_00471b30), "
                                     "last 64 bytes = validate key from 0x0C0C} @ FUN_00471980",
    "0x0c14@LoginWorldNetFrameWork": "WM login ok {u16 wmHandle -> g_WmHandle (DAT_00b300a4), u8 n, data[n] @+3 -> "
                                     "account object (FUN_006613b0; character list, inferred)}; switch scene "
                                     "(character select, inferred) @ FUN_00471720",
    "0x0c15@LoginWorldNetFrameWork": "WM login refused {u16 error} (WM sends 0x44 bad key / 0x46 DB error, W01): the "
                                     "client does not read the code, it leaves the scene (FUN_008c58b0 + FUN_008c5650)",
    # ---- character select (CharSelectFrameWork @ FUN_00476f50)
    "0x0c34@CharSelectFrameWork": "return-to-world-select token {u16 result, char token[32]} (W01: WM relays Login's 0x0C36 after the client's 0x0C33): result 0x1E58 -> keep the token in a UI object (+0x64..+0x80) for the reconnect to Login (0x0C37) and mark it ready; always refresh char select (FUN_00411790)",
    "0x1002@CharSelectFrameWork": "character login FAILED {u16 code}: message box by code: 0x141 'Failed to connect "
                                  "to the world server', 0x142/0x143 'Failed to connect to the map server', 0x144 "
                                  "'There is no character in the slot', 0x582..0x595 'There is an error in the "
                                  "<Character/Appearance/Option/Status/Skill/Quest/...> Information', other 'The Map is under maintenance' (W01: 0x145, 0x31EB). NB: carries the error, so 'NC_CHAR_LOGIN_ACK (REQ+1)' is "
                                  "doubtful (inferred: the success reply is 0x1003)",
    "0x1003@CharSelectFrameWork": "character login OK {char[16] zoneIp, u16 zonePort}: store (DAT_00b30080..90) and "
                                  "switch to the zone-login scene (FUN_008c56b0, FUN_00478b10)",
    "0x1110@CharSelectFrameWork": "tutorial question (WM sends it on 0x1001 when tutorialState == 0 and step == 0, W01): ask 'Would you like to start the tutorial?'; the answer goes back as 0x1111 {u8 skip}; no payload read",
    "0x111d@CharSelectFrameWork": "start the tutorial helpers (W01: WM sends it when the tutorial runs, login map becomes 'RouT00'): create DAT_00a7ec54 and set DAT_00a80950.flag = 1; no payload",
    "0x140a@CharSelectFrameWork": "character delete FAILED {u16 code}: 199 (0xC7) -> 'You may not delete guild leader.', "
                                  "else 'Unable to delete a Guild Master character.' (the WM itself sends 0xC6, W01); clear selection",
    "0x140c@CharSelectFrameWork": "character deleted {u8 slot}: remove slot from the account's list, release its "
                                  "model, clear selection; if no characters remain show the empty state",
    "0x1410@CharSelectFrameWork": "character rename result {u8 slot, char[20] name @+1, u16 code @+0x15}: 0xD0 -> "
                                  "store the new name for the slot and refresh; 0xD1 -> 'The name cannot be used.'",
    "0x580b": _OPT + " (0x37-byte option block)",
    "0x700b": _OPT + " (0x37-byte option block)",
    "0x7003": "shortcut data {u8 present, blob[0x400]}: reset the shortcut bar (DAT_00a874f8); if present load blob, "
              "else use defaults (and if the character count < 6 flag 'first login')",
    "0x7005": _OPT + " (0x17-byte block)",
    "0x7007": _IGN,
    "0x7009": _IGN,
    "0x700d": _OPT + " (0x102-byte block)",
    "0x700f": _OPT + " (0xF4-byte block; ignored once 0x7033 was received)",
    "0x7032": "shortcut list {u16 n, n x 7-byte entries @+2}: reset the shortcut bar and add each entry (FUN_006153c0)",
    "0x7033": "option list (newer format) -> FUN_0069cef0(payload); sets 'new format loaded' flag so 0x700F is ignored",
    "0x7034": "option list -> FUN_0069c8c0(payload); marks two option blocks loaded",
    "0x7c07": "{u16 code, u16 value}: code 0xDB0 -> remember value and set flag (DAT_00a7d698/95). Name in catalog "
              "is a weak log literal",
    "0x9010": "{u8 v}: if v < 0x15 store v in DAT_00a65fac",
    "0xb40c@CharSelectFrameWork": "rename-by-item result {u16 code, u8 slot, char[20] name @+3}: 0x20C0 -> store "
                                  "name, 'Character name successfully changed.'; 0x20C7 'Guild Master not allowed...'; "
                                  "0x20D1 'The name is already taken by another user.'; other -> error text + %d",
    # ---- character create (CharCreateFrameWork @ FUN_0040b530)
    "0x1404@CharCreateFrameWork": "character create FAILED {u16 code}: 0x82 'Failed to create the character.', 0x83 "
                                  "'wrong class', 0x84 'name already taken', 0x85 'error in the Max Slot Number', "
                                  "0x181 'The name is already in use.'",
    "0x1406@CharCreateFrameWork": "character created {u8 ?, avatar @+1 (0x82 bytes)}: append to the account's list "
                                  "(max 6) and return to character select",
    # ---- beauty shop (CHairShopFrameWork @ FUN_00629890)
    "0x0c14@CHairShopFrameWork": "WM login ok (same layout as in LoginWorldNet): store handle + character data, close "
                                 "the old link and return to character select",
    "0x1079@CHairShopFrameWork": "beauty shop apply result {u16 code}: 0x1280 'Decoration you chose has properly been "
                                 "applied.' and decrement the used item count; 0x1281/0x1282 DB error; 0x1283 'You "
                                 "need a Beauty Shop ... item'; 0x1284 unknown error; 0x1286 gender-change notice",
    "0x107d@CHairShopFrameWork": "beauty shop item counts {u16 code, u16[12] @+2}: if code == 0x1280 store the 12 counts",
    # ---- zone login (ZoneLoginNetFrameWork @ FUN_00477ce0) and map change (LinkFrameWork @ FUN_00626490)
    "0x0807@ZoneLoginNetFrameWork": _SEED + "send 0x1801 NC_MAP_LOGIN_REQ {u16 wmHandle, char[20] charName, "
                                    "49 x 32-byte SHN checksums} (0x636 bytes) @ FUN_004779d0",
    "0x0807@LinkFrameWork": _SEED + "send the map login (FUN_006262c0) and close the WM link object DAT_00a6ce3c "
                            "(inferred) @ FUN_00626440",
    "0x0810@LinkFrameWork": "{u8, u16 @+1}: store the u16 in DAT_00a8315c",
    "0x1010@LinkFrameWork": _IGN, "0x1011@LinkFrameWork": _IGN, "0x102a@LinkFrameWork": _IGN,
    "0x1038": 'character base data; zone sender `ShinePlayer_so_charbasedata` (Z01 name). Client: struct -> character object (FUN_006631f0, flag bit0 @+0x65, u8 @+0x19); in zone login also copy name @+4 (20 bytes) to DAT_00b1b3d0',
    "0x1039": 'character shape data; zone sender `ShinePlayer_so_charsharpdata` (Z01 name). Client: {u8 classByte (class = (b>>2)&0x1f), ...} -> character object (FUN_006614c0); zone login writes UserInfo.txt (account, char id, name, class)',
    "0x103a": 'quests in progress; zone sender `ShinePlayer_so_StoreQuestDoing` (Z01 name). Client: {u8 reset @+4, u8 n @+5, n x 32-byte records @+6} -> quest object FUN_006acdb0() (FUN_00727fd0)',
    "0x103b": 'completed quests; zone sender `ShinePlayer_so_StoreQuestDone` (Z01 name). Client: {u16 n @+8, n x 10-byte records @+0xc} -> quest object (FUN_007280b0)',
    "0x103c": "list {u16 n @+4, n x 36-byte records @+6} -> character object (FUN_00661d60)",
    "0x103d": 'active skills; zone sender `ShinePlayer_so_charskilldata` (Z01 name). Client: {u8, u8 flags, u16 @+2, u16 n @+8, records @+0x11} (FUN_006a0690)',
    "0x103e": 'passive skills; zone sender `ShinePlayer_so_charpassivedata` (Z01 name). Client: {u16 n, u16 id[n]} (max 3001) (FUN_0069f430)',
    "0x1047": "item manager load (FUN_00666eb0 on DAT_00a8d120), then refresh the shortcut bar",
    "0x1048": _IGN,
    "0x1049": "main character data (FUN_0065e440, u16 count @+4, max 0x200)",
    "0x104a": 'charged (premium) buffs; zone sender `ShinePlayer_so_CharChargedBuffData` (Z01 name). Client: {u16 n, n x 14-byte records @+2} (FUN_006d2540 per record)',
    "0x10ce": 'quest read-state list; zone sender `ShinePlayer_so_StoreQuestRead` (0044b640, Z01 name). Client: {u16 n @+4, u16[n] @+6} -> quest object (FUN_007281b0)',
    "0x10d7": 'quest read-state records; zone sender `ShinePlayer_so_StoreQuestRead` (0044b770, Z01 name). Client: {u16 n @+4, n x 32-byte records @+6} -> quest object (FUN_00728280)',
    "0x10de": "{u32 a, u32 b, u32 c, u32 d} -> account object (two pairs, FUN_00662320/FUN_00662340)",
    "0x441e": 'quest reset times; zone sender `CQuestZone_Send_NC_QUEST_RESET_TIME_ZONE_CMD` (Z01 name; the string names the zone-side message, not necessarily this opcode). Client: {u32[4]} -> quest object +0xa4..+0xb0',
    "0x1802@ZoneLoginNetFrameWork": "map login OK: store map/position (FUN_006614f0); send 0x7004, 0x700C, 0x7C06 (no "
                                    "payload) on the WM link; scene state = 0xF (enter game)",
    "0x1802@LinkFrameWork": "map login OK after a map change: store map/position, rebuild the world (FUN_00625d00) "
                            "and enter the game scene",
    "0x1804@ZoneLoginNetFrameWork": "map login FAILED {u16 code, u8 idx}: 0x147 -> mark SHN checksum #idx bad, 'The "
                                    "client has been illegally manipulated. Please reinstall the client'; leave scene",
    "0x1804@LinkFrameWork": "map change FAILED {u16 code, u8 idx}: 0x147 -> mark SHN #idx bad, 'Failed to move to "
                            "another map.'; reset and leave scene",
    # ---- game scene: a few checked by hand
    "0x2445@GameFrameWork": "skill-bash cast aborted (no payload read) @ FUN_0049a540",
}
