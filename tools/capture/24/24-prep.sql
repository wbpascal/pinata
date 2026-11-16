-- Scenario 24 preparation (capture-scenarios.md §3 "24"). Run by 24-server.ps1 prep, both accounts logged out
-- (client at the login screen or closed). Turns two characters freshly created in the client into
--   $(CharA) (account "admin")        Gladiator (class 4), level 100, GM 100, 127 of 130 stat points spent -> 3 free
--   $(CharB) (account "testaccountB") HighCleric (class 7), level 20,  GM 100
-- puts both next to Skill Master Ruby (RouN 6307,7147), marks their tutorial done (no tutorial question at login),
-- gives A 100 000 money and writes the setup skills straight into tSkill (no &learnskill on the wire):
--   A: 7300 BurnPain01 "Heat of Fury [01]" (toggle, step 5), 452 Dash01 "Dash [01]" (ground target, step 4)
--   B: 1620 Revival01 "Revive [01]" (step 8), 1800 DivineShield01 "Invincible [01]" (950 ms cast, step 4)
-- Values from the 2016 data: ChrCommon.txt StatTable (Gla total at level 100 = 130; nextexp: level 100 starts at
-- 4256887017, level 20 at 33843), ClassName.shn (4 Gladiator, 7 HighCleric). Only these two test characters are
-- changed, so there is no save table: the clean-up deletes them (24-cleanup.sql). Safe to run twice.
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);
DECLARE @a int = (SELECT nCharNo FROM tCharacter WHERE sID = N'$(CharA)' AND bDeleted = 0);
DECLARE @b int = (SELECT nCharNo FROM tCharacter WHERE sID = N'$(CharB)' AND bDeleted = 0);
IF @a IS NULL OR @b IS NULL
BEGIN RAISERROR('$(CharA) or $(CharB) not found: create them in the client first (A: Fighter on admin, B: Cleric on testaccountB)', 16, 1); RETURN; END
DECLARE @ca tinyint = (SELECT nClass FROM tCharacterShape WHERE nCharNo = @a);
DECLARE @cb tinyint = (SELECT nClass FROM tCharacterShape WHERE nCharNo = @b);
IF @ca NOT BETWEEN 1 AND 5 OR @cb NOT BETWEEN 6 AND 10
BEGIN RAISERROR('$(CharA) must be a Fighter (class 1-5) and $(CharB) a Cleric (class 6-10): delete and create again', 16, 1); RETURN; END

-- the two characters must sit on the two named accounts (skipped when the account DB has another name)
IF DB_ID(N'$(AccountDb)') IS NOT NULL
BEGIN
    DECLARE @ua nvarchar(40), @ub nvarchar(40);
    DECLARE @ua_no int = (SELECT nUserNo FROM tCharacter WHERE nCharNo = @a);
    DECLARE @ub_no int = (SELECT nUserNo FROM tCharacter WHERE nCharNo = @b);
    EXEC sp_executesql N'SELECT @x = sUserID FROM [$(AccountDb)].dbo.tUser WHERE nUserNo = @n',
         N'@n int, @x nvarchar(40) OUTPUT', @n = @ua_no, @x = @ua OUTPUT;
    EXEC sp_executesql N'SELECT @x = sUserID FROM [$(AccountDb)].dbo.tUser WHERE nUserNo = @n',
         N'@n int, @x nvarchar(40) OUTPUT', @n = @ub_no, @x = @ub OUTPUT;
    IF ISNULL(@ua, N'') <> N'admin' OR ISNULL(@ub, N'') <> N'testaccountB'
    BEGIN RAISERROR('$(CharA) must be on account admin, $(CharB) on testaccountB', 16, 1); RETURN; END
END
ELSE PRINT 'account DB $(AccountDb) not found: account check skipped (-AccountDb <name>)';

BEGIN TRAN;
UPDATE tCharacter
   SET nAdminLevel = 100, nLevel = 100, nExp = 4256887017,
       nStrength = 60, nConstitute = 67, nDexterity = 0, nIntelligence = 0, nMentalPower = 0,
       nMoney = CASE WHEN nMoney < 100000 THEN 100000 ELSE nMoney END,
       sLoginZone = 'RouN', nLoginZoneX = 6450, nLoginZoneY = 7150
 WHERE nCharNo = @a;
UPDATE tCharacterShape SET nClass = 4 WHERE nCharNo = @a;
UPDATE tCharacter
   SET nAdminLevel = 100, nLevel = 20, nExp = 33843,
       sLoginZone = 'RouN', nLoginZoneX = 6550, nLoginZoneY = 7150
 WHERE nCharNo = @b;
UPDATE tCharacterShape SET nClass = 7 WHERE nCharNo = @b;

-- skills as the Character server writes them at character creation (p_Skill_Set, all values 0; D02 §3)
DECLARE @r int;
EXEC p_Skill_Set @a, 7300, 0, 0, 0, 0, 0, 0, 0, 0, @r OUTPUT;
EXEC p_Skill_Set @a,  452, 0, 0, 0, 0, 0, 0, 0, 0, @r OUTPUT;
EXEC p_Skill_Set @b, 1620, 0, 0, 0, 0, 0, 0, 0, 0, @r OUTPUT;
EXEC p_Skill_Set @b, 1800, 0, 0, 0, 0, 0, 0, 0, 0, @r OUTPUT;

-- tutorial done (nState 2, as the "skip" path of 0x1112 writes it): the WM does not ask at the first login
IF OBJECT_ID('dbo.usp_Tutorial_setCharInfo') IS NOT NULL
BEGIN
    DECLARE @na int = (SELECT nUserNo FROM tCharacter WHERE nCharNo = @a);
    DECLARE @nb int = (SELECT nUserNo FROM tCharacter WHERE nCharNo = @b);
    EXEC usp_Tutorial_setCharInfo @na, @a, 2, 0, @r OUTPUT;
    EXEC usp_Tutorial_setCharInfo @nb, @b, 2, 0, @r OUTPUT;
END
ELSE PRINT 'no usp_Tutorial_setCharInfo in this DB: answer the tutorial question at the first login with "skip"';
COMMIT;
PRINT 'prep done: $(CharA) Gladiator 100 GM, $(CharB) HighCleric 20 GM, both at Skill Master Ruby';

SELECT c.nCharNo, c.nUserNo, c.sID, c.nLevel, c.nExp, s.nClass, c.nAdminLevel,
       c.nStrength + c.nConstitute + c.nDexterity + c.nIntelligence + c.nMentalPower AS spent,
       c.nMoney, c.sLoginZone, c.nLoginZoneX, c.nLoginZoneY
  FROM tCharacter c JOIN tCharacterShape s ON s.nCharNo = c.nCharNo
 WHERE c.nCharNo IN (@a, @b);
SELECT nCharNo, nSkillNo FROM tSkill WHERE nCharNo IN (@a, @b) AND nSkillNo IN (7300, 452, 1620, 1800) ORDER BY nCharNo, nSkillNo;

-- leftovers of earlier setups (should be empty or known)
SELECT name AS open_x02_object FROM sys.objects WHERE name LIKE 'X02[_]%' OR name LIKE 'X37[_]%';
