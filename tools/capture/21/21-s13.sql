-- Scenario 21 step 12, run "21c": S13 (capture-scenarios.md §8.14), our variant:
-- instead of looking for an item that already has an end time, it takes a Leather Boots made with
-- &makeitem LeatherBoots (boot class 8: the save writes its deletetime row 820, D03 §1.3, normally 0)
-- and sets row 820 to 2020-01-01 00:00 (8468). If no 820 row is listed, that is a finding: stop and note it.
-- Account "admin" at the login screen (log out after the &makeitem so the zone saves the item).
USE World00_Character;
DECLARE @char nvarchar(32) = N'Test2';
DECLARE @c int = (SELECT nCharNo FROM tCharacter WHERE sID = @char AND bDeleted = 0);
DECLARE @boots int = 0;                      -- LeatherBoots
DECLARE @key bigint = (SELECT TOP 1 i.nItemKey FROM tItem i JOIN tItemOptions o ON o.nItemKey = i.nItemKey
                        WHERE i.nOwner = @c AND i.nStorageType = 9 AND i.nItemID = @boots AND o.nOptionType = 820
                        ORDER BY i.nItemKey DESC);
SELECT i.nItemKey, i.nStorageType, i.nStorage, i.nItemID, o.nOptionType, o.nOptionData
  FROM tItem i JOIN tItemOptions o ON o.nItemKey = i.nItemKey WHERE i.nItemKey = @key;
IF @key IS NULL RAISERROR('no Leather Boots with an 820 row in the inventory', 16, 1)
ELSE BEGIN
    SELECT * INTO dbo.X02_save_13a FROM tItem WHERE nItemKey = @key;
    SELECT * INTO dbo.X02_save_13b FROM tItemOptions WHERE nItemKey = @key;
    UPDATE tItemOptions SET nOptionData = 8468 WHERE nItemKey = @key AND nOptionType = 820;
    PRINT 'S13: end time set; log in now and wait two minutes';
END
-- no restore: the test deletes the item. After the test, in a separate run:
-- DROP TABLE dbo.X02_save_13a; DROP TABLE dbo.X02_save_13b;
