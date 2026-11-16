-- Scenario 46 clean-up, run by 46-server.ps1 cleanup with account "admin" logged out.
--   1. account storage of "admin": removes the items made during the run (key above dbo.X46_save.nMaxItemKey: the
--      stack deposited in step 2) and puts the storage money back to its value before prep;
--   2. deletes $(Char) the way the Character server does (p_Char_Delete: bDeleted 1, name "<name>~<date>#<n>",
--      rows stay); its inventory goes with it;
--   3. drops dbo.X46_save.
-- Nothing else needs undoing: prep changed only this character. The game log rows (GameLog DB) are kept.
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);
IF OBJECT_ID('dbo.X46_save') IS NULL
BEGIN RAISERROR('dbo.X46_save not found: prep was not run, or the clean-up ran already', 16, 1); RETURN; END
DECLARE @u int, @money bigint, @had bit, @maxkey bigint;
SELECT @u = nUserNo, @money = nUserMoney, @had = bHadRow, @maxkey = nMaxItemKey FROM dbo.X46_save;

BEGIN TRAN;
-- 1. account storage
SELECT i.nStorage, i.nItemKey, i.nItemID AS removed_from_account_storage
  FROM tItem i WHERE i.nOwner = @u AND i.nStorageType = 6 AND i.nItemKey > @maxkey;
DELETE o FROM tItemOptions o JOIN tItem i ON i.nItemKey = o.nItemKey
 WHERE i.nOwner = @u AND i.nStorageType = 6 AND i.nItemKey > @maxkey;
DELETE FROM tItem WHERE nOwner = @u AND nStorageType = 6 AND nItemKey > @maxkey;
IF @had = 1 UPDATE tUserMoney SET nUserMoney = @money WHERE nUserNo = @u;
ELSE DELETE FROM tUserMoney WHERE nUserNo = @u;
COMMIT;
PRINT CONCAT('account storage money back to ', ISNULL(CONVERT(varchar(30), @money), '(no row)'));

-- 2. the test character
DECLARE @n int, @s nvarchar(40), @r int;
SELECT @n = nCharNo, @s = sID FROM tCharacter WHERE sID = N'$(Char)' AND bDeleted = 0;
IF @n IS NOT NULL
BEGIN
    SET @r = 4;
    EXEC p_Char_Delete @n, @r OUTPUT;
    PRINT CONCAT(@s, ' (', @n, '): p_Char_Delete returned ', @r, ' (0 = deleted)');
END
ELSE PRINT '$(Char) not found (deleted already?)';

-- 3. the save table
DROP TABLE dbo.X46_save;

SELECT nCharNo, sID, bDeleted, dDeletedDate FROM tCharacter WHERE sID LIKE N'$(Char)~%' OR sID = N'$(Char)';
SELECT nUserNo, nUserMoney AS storage_money FROM tUserMoney WHERE nUserNo = @u;
SELECT name AS open_x_object FROM sys.objects WHERE name LIKE 'X02[_]%' OR name LIKE 'X37[_]%' OR name LIKE 'X46[_]%';
