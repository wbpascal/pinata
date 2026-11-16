-- Scenario 46 preparation (capture-scenarios.md §3 "46"). Run by 46-server.ps1 prep, account "admin" logged out
-- (client at the login screen or closed). Turns a character freshly created in the client on account "admin" into
--   $(Char): level 20 (below NormalEar117's BuyDemandLv 117), GM 100 (S1), 1 000 cen, tutorial done,
--   standing next to Storage Keeper Raina (RouN 5231,7416; World/NPC.txt).
-- Also saves what the run changes outside this character into dbo.X46_save, which 46-cleanup.sql restores:
--   the account's storage money (tUserMoney: step 2 deposits all cen, step 7 deposits / withdraws again) and the
--   highest item key now in tItem (the stack deposited in step 2 stays in the ACCOUNT storage after the character
--   is deleted; the clean-up removes the account-storage items made after this point).
-- Safe to run twice (the save table is kept from the first run).
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);
DECLARE @c int = (SELECT nCharNo FROM tCharacter WHERE sID = N'$(Char)' AND bDeleted = 0);
IF @c IS NULL
BEGIN RAISERROR('$(Char) not found: create it in the client first (any class, on account admin)', 16, 1); RETURN; END
DECLARE @u int = (SELECT nUserNo FROM tCharacter WHERE nCharNo = @c);

-- the character must sit on account "admin" (skipped when the account DB has another name)
IF DB_ID(N'$(AccountDb)') IS NOT NULL
BEGIN
    DECLARE @ua nvarchar(40);
    EXEC sp_executesql N'SELECT @x = sUserID FROM [$(AccountDb)].dbo.tUser WHERE nUserNo = @n',
         N'@n int, @x nvarchar(40) OUTPUT', @n = @u, @x = @ua OUTPUT;
    IF ISNULL(@ua, N'') <> N'admin'
    BEGIN RAISERROR('$(Char) must be on account admin', 16, 1); RETURN; END
END
ELSE PRINT 'account DB $(AccountDb) not found: account check skipped (-AccountDb <name>)';

BEGIN TRAN;
IF OBJECT_ID('dbo.X46_save') IS NULL
BEGIN
    SELECT @u AS nUserNo,
           (SELECT nUserMoney FROM tUserMoney WHERE nUserNo = @u) AS nUserMoney,
           CASE WHEN EXISTS (SELECT 1 FROM tUserMoney WHERE nUserNo = @u) THEN 1 ELSE 0 END AS bHadRow,
           (SELECT ISNULL(MAX(nItemKey), 0) FROM tItem) AS nMaxItemKey,
           GETDATE() AS dSaved
      INTO dbo.X46_save;
    PRINT 'saved account storage money and the highest item key in dbo.X46_save';
END
ELSE PRINT 'dbo.X46_save exists (kept from the first prep run)';

UPDATE tCharacter
   SET nAdminLevel = 100, nLevel = 20, nExp = 33843, nMoney = 1000,
       sLoginZone = 'RouN', nLoginZoneX = 5300, nLoginZoneY = 7450
 WHERE nCharNo = @c;

-- tutorial done (nState 2, as the "skip" path of 0x1112 writes it): the WM does not ask at the first login
DECLARE @r int;
IF OBJECT_ID('dbo.usp_Tutorial_setCharInfo') IS NOT NULL
    EXEC usp_Tutorial_setCharInfo @u, @c, 2, 0, @r OUTPUT;
ELSE PRINT 'no usp_Tutorial_setCharInfo in this DB: answer the tutorial question at the first login with "skip"';
COMMIT;
PRINT 'prep done: $(Char) level 20, GM 100, 1000 cen, next to Storage Keeper Raina';

SELECT c.nCharNo, c.nUserNo, c.sID, c.nLevel, c.nAdminLevel, c.nMoney, c.sLoginZone, c.nLoginZoneX, c.nLoginZoneY
  FROM tCharacter c WHERE c.nCharNo = @c;
SELECT * FROM dbo.X46_save;

-- leftovers of earlier setups (should be empty or known)
SELECT name AS open_x_object FROM sys.objects WHERE name LIKE 'X02[_]%' OR name LIKE 'X37[_]%' OR name LIKE 'X46[_]%';
