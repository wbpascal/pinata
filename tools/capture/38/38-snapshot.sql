-- Scenario 38: money and saved position of the character as the DB holds them (38-server.ps1 snapshot / kill-zone /
-- getmoney-kill). Money is written only as deltas (p_Char_MoneyAdd, confidence.md E41); the position only by a save.
SET NOCOUNT ON;
USE World00_Character;
SELECT N'$(Label)' AS snapshot, CONVERT(varchar(12), GETDATE(), 114) AS db_time,
       sID, nMoney, nLevel, nExp, nAdminLevel, sLoginZone, nLoginZoneX, nLoginZoneY
  FROM tCharacter WHERE sID = N'$(Char)' AND bDeleted = 0;
