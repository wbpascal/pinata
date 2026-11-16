-- Scenario 37b: the account's characters and rename rows as the DB holds them.
SET NOCOUNT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);
DECLARE @u int = (SELECT TOP 1 nUserNo FROM dbo.X37_save);
IF @u IS NULL SET @u = (SELECT nUserNo FROM tCharacter WHERE sID = N'$(RightChar)' AND bDeleted = 0);
SELECT N'$(Label)' AS snapshot, CONVERT(varchar(12), GETDATE(), 114) AS db_time;
SELECT nCharNo, nSlotNo, sID, bDeleted, nLevel, sLoginZone FROM tCharacter WHERE nUserNo = @u ORDER BY bDeleted, nSlotNo;
SELECT r.* FROM tCharacterChangeID r WHERE r.nUserNo = @u ORDER BY r.nRowNo;
IF OBJECT_ID('dbo.X37_save') IS NOT NULL SELECT * FROM dbo.X37_save;
