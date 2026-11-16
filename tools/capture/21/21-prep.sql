-- Scenario 21 preparation (capture-scenarios.md §8.2 S1, made idempotent) + account B check.
-- Run with account "admin" at the login screen (no character in the game).
-- On the server: .\21-server.ps1 prep -Char <name>
-- The character comes from 21-server.ps1 -Char <name> (sqlcmd variable Char). In SSMS: SQLCMD mode, first line ":setvar Char <name>".
-- The account database is assumed to be named "Account" (Account.dbo.… below): change it if yours differs.
SET NOCOUNT ON;
USE World00_Character;
DECLARE @char nvarchar(32) = N'$(Char)';          -- the GM character that plays the scenario (21-server.ps1 -Char)
DECLARE @c int = (SELECT nCharNo FROM tCharacter WHERE sID = @char AND bDeleted = 0);
IF @c IS NULL BEGIN RAISERROR('character $(Char) not found', 16, 1); RETURN; END
SELECT 'character' AS scenario_21, sID, nCharNo, nUserNo FROM tCharacter WHERE nCharNo = @c;   -- who this run is for

-- S1: admin level 100
IF (SELECT nAdminLevel FROM tCharacter WHERE nCharNo = @c) = 100
    PRINT 'S1: admin level already 100';
ELSE IF OBJECT_ID('dbo.X02_save_1') IS NOT NULL
    RAISERROR('dbo.X02_save_1 exists but the level is not 100: check it before going on', 16, 1);
ELSE BEGIN
    SELECT nCharNo, sID, nAdminLevel INTO dbo.X02_save_1 FROM tCharacter WHERE nCharNo = @c;
    UPDATE tCharacter SET nAdminLevel = 100 WHERE nCharNo = @c;
    PRINT 'S1: admin level set to 100 (old value in dbo.X02_save_1)';
END
SELECT nCharNo, nUserNo, sID, nLevel, nMoney, nAdminLevel, sLoginZone FROM tCharacter WHERE nCharNo = @c;

-- leftovers of earlier setups (scenario 37 used S10 / S11)
SELECT name AS open_save_table FROM sys.tables WHERE name LIKE 'X02[_]save[_]%';

-- account B must be able to log in for step 3 (scenario 37 blocked it)
SELECT u.sUserID, u.bIsBlock, u.bIsDelete, u.nAuthID, a.sAuthName, a.bIsLoginAble
  FROM Account.dbo.tUser u LEFT JOIN Account.dbo.tUserAuth a ON a.nAuthID = u.nAuthID
 WHERE u.sUserID IN (N'admin', N'testaccountB');
SELECT b.* FROM Account.dbo.tUserBlock b JOIN Account.dbo.tUser u ON u.nUserNo = b.nUserNo
 WHERE u.sUserID = N'testaccountB' AND b.bStatus <> 0;
