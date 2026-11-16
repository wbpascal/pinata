-- Scenario 46: what the DB holds for the character and its account storage (46-server.ps1 snapshot / prep / cleanup).
-- Items are written by the Character server as each request runs, so a snapshot taken while online is right for
-- tItem / tItemOptions; money and position of an online character lag behind (take the last one at the login screen).
-- Checks: D03 check 3 (the deposited stack: nStorageType 6, nOwner = nUserNo), the boots bought back in step 3 under
-- a NEW nItemKey only (0x34B9), the merged stacks of step 1 (lot option rows).
SET NOCOUNT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);
SELECT N'$(Label)' AS snapshot, CONVERT(varchar(12), GETDATE(), 114) AS db_time;
DECLARE @c int, @u int;
SELECT @c = nCharNo, @u = nUserNo FROM tCharacter WHERE sID = N'$(Char)' AND bDeleted = 0;
IF @c IS NULL BEGIN PRINT 'character $(Char) not found (deleted already?)'; RETURN; END

SELECT nCharNo, nUserNo, sID, nLevel, nAdminLevel, nMoney, sLoginZone, nLoginZoneX, nLoginZoneY
  FROM tCharacter WHERE nCharNo = @c;
SELECT nUserNo, nUserMoney AS storage_money FROM tUserMoney WHERE nUserNo = @u;

-- inventory (9), equipped (8), everything else of the character, and the account storage (6, owner = user number)
SELECT i.nStorageType, i.nStorage, i.nItemKey, i.nItemID, i.nOwner, i.nFlags,
       (SELECT TOP 1 o.nOptionData FROM tItemOptions o
         WHERE o.nItemKey = i.nItemKey AND o.nOptionType IN (1, 2, 3) ORDER BY o.nOptionType) AS lot
  FROM tItem i
 WHERE i.nOwner = @c OR (i.nOwner = @u AND i.nStorageType = 6)
 ORDER BY i.nStorageType, i.nStorage;
