-- Scenario 21 step 12, run "21b": S16 (capture-scenarios.md §8.17). The character can stay online.
-- Run right before the purchase; 21-s16-off.sql right after it.
-- While the trigger exists EVERY new item of the character fails: do nothing but the one purchase.
-- The character comes from 21-server.ps1 -Char <name> (sqlcmd variable Char). In SSMS: SQLCMD mode, first line ":setvar Char <name>".
USE World00_Character;
DECLARE @char nvarchar(32) = N'$(Char)';
DECLARE @c int = (SELECT nCharNo FROM tCharacter WHERE sID = @char AND bDeleted = 0);
SELECT sID, nCharNo, nMoney, nFame FROM tCharacter WHERE nCharNo = @c;     -- who and before (lags while online)
DECLARE @sql nvarchar(max) = N'CREATE TRIGGER dbo.X02_tItemOptions_fail ON dbo.tItemOptions AFTER INSERT AS
IF EXISTS (SELECT 1 FROM inserted o JOIN dbo.tItem i ON i.nItemKey = o.nItemKey WHERE i.nOwner = ' + CAST(@c AS nvarchar(12)) + N')
BEGIN
    ROLLBACK TRANSACTION;
    RAISERROR(''X02 forced failure (S16)'', 16, 1);
END';
IF @c IS NULL RAISERROR('character $(Char) not found', 16, 1) ELSE EXEC (@sql);
