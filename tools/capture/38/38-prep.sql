-- Scenario 38 preparation (capture-scenarios.md §8.2 S1, made idempotent) + account check.
-- Run with account "admin" at the login screen (no character in the game).
-- On the server: .\38-server.ps1 prep -Char <name>   (sqlcmd variable Char; in SSMS: SQLCMD mode, ":setvar Char <name>")
-- The account database is assumed to be named "Account" (Account.dbo.… below): change it if yours differs.
SET NOCOUNT ON;
USE World00_Character;
DECLARE @char nvarchar(32) = N'$(Char)';
DECLARE @c int = (SELECT nCharNo FROM tCharacter WHERE sID = @char AND bDeleted = 0);
IF @c IS NULL BEGIN RAISERROR('character $(Char) not found', 16, 1); RETURN; END
SELECT 'character' AS scenario_38, c.sID, c.nCharNo, c.nUserNo, u.sUserID
  FROM tCharacter c LEFT JOIN Account.dbo.tUser u ON u.nUserNo = c.nUserNo WHERE c.nCharNo = @c;

-- S1: admin level 100 (&getmoney needs 100)
IF (SELECT nAdminLevel FROM tCharacter WHERE nCharNo = @c) = 100
    PRINT 'S1: admin level already 100';
ELSE IF OBJECT_ID('dbo.X02_save_1') IS NOT NULL
    RAISERROR('dbo.X02_save_1 exists but the level is not 100: check it before going on', 16, 1);
ELSE BEGIN
    SELECT nCharNo, sID, nAdminLevel INTO dbo.X02_save_1 FROM tCharacter WHERE nCharNo = @c;
    UPDATE tCharacter SET nAdminLevel = 100 WHERE nCharNo = @c;
    PRINT 'S1: admin level set to 100 (old value in dbo.X02_save_1)';
END

-- account "admin" must be able to log in (scenario 37 changed blocks / auth groups)
SELECT u.sUserID, u.bIsBlock, u.bIsDelete, u.nAuthID, a.sAuthName, a.bIsLoginAble
  FROM Account.dbo.tUser u LEFT JOIN Account.dbo.tUserAuth a ON a.nAuthID = u.nAuthID
 WHERE u.sUserID = N'admin';

-- leftovers of earlier setups (should be empty or known)
SELECT name AS open_x02_object FROM sys.objects WHERE name LIKE 'X02[_]%';
