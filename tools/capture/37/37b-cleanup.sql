-- Scenario 37b clean-up: undo 37b-prep.sql and what the run changed. Account "admin" logged out.
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);
IF OBJECT_ID('dbo.X37_save') IS NULL BEGIN PRINT 'no dbo.X37_save: nothing to restore'; RETURN; END

-- another character holding an old name (e.g. created during the run) would block the restore
IF EXISTS (SELECT 1 FROM tCharacter c JOIN dbo.X37_save s ON c.sID = s.sID AND c.nCharNo <> s.nCharNo)
BEGIN RAISERROR('an old name is held by another character: rename or delete that one first', 16, 1); RETURN; END

BEGIN TRAN;
UPDATE c SET sID = s.sID FROM tCharacter c JOIN dbo.X37_save s ON s.nCharNo = c.nCharNo WHERE c.sID <> s.sID;
PRINT CONCAT('names restored: ', @@ROWCOUNT);
DELETE r FROM tCharacterChangeID r
 WHERE r.nRowNo > (SELECT MAX(maxRowNo) FROM dbo.X37_save) AND r.nCharNo IN (SELECT nCharNo FROM dbo.X37_save);
PRINT CONCAT('rename rows removed: ', @@ROWCOUNT);
DECLARE @u int = (SELECT TOP 1 nUserNo FROM dbo.X37_save);
DROP TABLE dbo.X37_save;
COMMIT;

SELECT nCharNo, nSlotNo, sID, bDeleted FROM tCharacter WHERE nUserNo = @u ORDER BY bDeleted, nSlotNo;
SELECT name AS open_x02_or_x37_object FROM sys.objects WHERE name LIKE 'X02[_]%' OR name LIKE 'X37[_]%';
