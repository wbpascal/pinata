-- Scenario 24 preparation (capture-scenarios.md §3 "24"): turns two freshly created level-1 characters into
--   X24A (account "admin")        Gladiator (class 4), level 100, GM 100, 127 of 130 stat points spent -> 3 free
--   X24B (account "testaccountB") HighCleric (class 7), level 20,  GM 100
-- and puts both next to Skill Master Ruby (RouN 6307,7147).
-- Both accounts at the login screen (no character in the game). Run on the server:
--   sqlcmd -S . -E -i 24-prep.sql
-- Values from the 2016 data: ChrCommon.txt StatTable (Gla total at level 100 = 130; nextexp: level 100 starts at
-- 4256887017, level 20 at 33843), ClassName.shn (4 Gladiator, 7 HighCleric). Only these two test characters are
-- changed, so there is no save table: the clean-up is deleting them (24-cleanup.sql).
SET NOCOUNT ON;
USE World00_Character;
DECLARE @a int = (SELECT nCharNo FROM tCharacter WHERE sID = N'X24A' AND bDeleted = 0);
DECLARE @b int = (SELECT nCharNo FROM tCharacter WHERE sID = N'X24B' AND bDeleted = 0);
IF @a IS NULL OR @b IS NULL BEGIN RAISERROR('X24A or X24B not found: create them in the client first', 16, 1); RETURN; END

BEGIN TRY
    BEGIN TRAN;
    UPDATE tCharacter
       SET nAdminLevel = 100, nLevel = 100, nExp = 4256887017,
           nStrength = 60, nConstitute = 67, nDexterity = 0, nIntelligence = 0, nMentalPower = 0,
           sLoginZone = 'RouN', nLoginZoneX = 6450, nLoginZoneY = 7150
     WHERE nCharNo = @a;
    UPDATE tCharacterShape SET nClass = 4 WHERE nCharNo = @a;
    UPDATE tCharacter
       SET nAdminLevel = 100, nLevel = 20, nExp = 33843,
           sLoginZone = 'RouN', nLoginZoneX = 6550, nLoginZoneY = 7150
     WHERE nCharNo = @b;
    UPDATE tCharacterShape SET nClass = 7 WHERE nCharNo = @b;
    COMMIT;
    PRINT 'X24A / X24B set up';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT 'nothing changed: ' + ERROR_MESSAGE();
    PRINT 'if the message names nExp (column too small) or a login column: report it, then use the fallback in the notes file';
END CATCH

SELECT c.nCharNo, c.nUserNo, c.sID, c.nLevel, c.nExp, s.nClass, c.nAdminLevel,
       c.nStrength, c.nConstitute, c.nDexterity, c.nIntelligence, c.nMentalPower,
       c.nStrength + c.nConstitute + c.nDexterity + c.nIntelligence + c.nMentalPower AS spent,
       c.nMoney, c.sLoginZone, c.nLoginZoneX, c.nLoginZoneY
  FROM tCharacter c JOIN tCharacterShape s ON s.nCharNo = c.nCharNo
 WHERE c.nCharNo IN (@a, @b);

-- leftovers of earlier setups (should be empty or known)
SELECT name AS open_save_table FROM sys.tables WHERE name LIKE 'X02[_]save[_]%';
