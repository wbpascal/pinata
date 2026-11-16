-- Scenario 24 clean-up: deletes the two test characters the way the Character server does (p_Char_Delete: bDeleted 1,
-- name becomes "<name>~<date>#<n>", rows stay). Run by 24-server.ps1 cleanup, both accounts logged out.
-- Nothing else needs undoing: prep changed only these two characters. A fresh character has no friends, guild or
-- marriage, so the other deletes of 0x1408 (D02, character delete) have nothing to do.
SET NOCOUNT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);
DECLARE @n int, @s nvarchar(40), @r int;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT nCharNo, sID FROM tCharacter WHERE sID IN (N'$(CharA)', N'$(CharB)') AND bDeleted = 0;
OPEN c;
FETCH NEXT FROM c INTO @n, @s;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @r = 4;
    EXEC p_Char_Delete @n, @r OUTPUT;
    PRINT CONCAT(@s, ' (', @n, '): p_Char_Delete returned ', @r, ' (0 = deleted)');
    FETCH NEXT FROM c INTO @n, @s;
END
CLOSE c; DEALLOCATE c;

SELECT nCharNo, sID, nLevel, nAdminLevel, bDeleted, dDeletedDate
  FROM tCharacter WHERE sID LIKE N'$(CharA)~%' OR sID LIKE N'$(CharB)~%' OR sID IN (N'$(CharA)', N'$(CharB)');
SELECT name AS open_x02_object FROM sys.objects WHERE name LIKE 'X02[_]%' OR name LIKE 'X37[_]%';
