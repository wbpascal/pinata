-- Scenario 24: what the DB holds for the two characters (24-server.ps1 snapshot / prep / cleanup).
-- Stat points are written per point (p_Char_StatPoint_Inc / _Dec, Z07 §2), empower points per skill (tSkill nSkillPower*).
SET NOCOUNT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);
SELECT N'$(Label)' AS snapshot, CONVERT(varchar(12), GETDATE(), 114) AS db_time;
SELECT c.nCharNo, c.sID, c.bDeleted, c.nLevel, s.nClass, c.nAdminLevel, c.nMoney,
       c.nStrength AS STR, c.nConstitute AS [END], c.nDexterity AS DEX, c.nIntelligence AS [INT], c.nMentalPower AS SPR,
       c.nStrength + c.nConstitute + c.nDexterity + c.nIntelligence + c.nMentalPower AS spent,
       c.nHP, c.nSP, c.sLoginZone, c.nLoginZoneX, c.nLoginZoneY
  FROM tCharacter c JOIN tCharacterShape s ON s.nCharNo = c.nCharNo
 WHERE c.sID IN (N'$(CharA)', N'$(CharB)') AND c.bDeleted = 0;
-- nSkillExp / nSkillWriteTime / nSkillCoolTime: the 0x4009 skill save (p_Skill_Set: mastery, save time in s since 1970,
-- cooldown seconds left; D02 §6, Z23 §7), added by X07 for scenario 51 step 4.
SELECT c.sID, k.nSkillNo, k.nSkillLevel, k.nSkillPowerDemage, k.nSkillPowerSP, k.nSkillPowerKeepTime, k.nSkillPowerCoolTime,
       k.nSkillExp, k.nSkillWriteTime, k.nSkillCoolTime
  FROM tSkill k JOIN tCharacter c ON c.nCharNo = k.nCharNo
 WHERE c.sID IN (N'$(CharA)', N'$(CharB)') AND c.bDeleted = 0
 ORDER BY c.sID, k.nSkillNo;
