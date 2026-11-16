-- Item / money snapshot of the GM character (D03 checks; capture-scenarios.md §1 "Notes file").
-- Run before the capture and after logging out at the end; the outputs go next to the capture.
-- On the server: .\21-server.ps1 snapshot-before / snapshot-after -Char <name> (writes .\out\...-snapshot-<tag>.txt)
-- The character comes from 21-server.ps1 -Char <name> (sqlcmd variable Char). In SSMS: SQLCMD mode, first line ":setvar Char <name>".
-- (values of an online character lag behind the game: take the "after" snapshot at the login screen)
SET NOCOUNT ON;
USE World00_Character;
DECLARE @char nvarchar(32) = N'$(Char)';
DECLARE @c int, @u int;
SELECT @c = nCharNo, @u = nUserNo FROM tCharacter WHERE sID = @char AND bDeleted = 0;
IF @c IS NULL BEGIN RAISERROR('character $(Char) not found', 16, 1); RETURN; END
SELECT 'character' AS scenario_21, sID, nCharNo, nUserNo FROM tCharacter WHERE nCharNo = @c;   -- who this run is for

SELECT GETDATE() AS taken_at, nCharNo, nUserNo, sID, nLevel, nMoney, nAdminLevel FROM tCharacter WHERE nCharNo = @c;

-- inventory (9), equipment (8) and everything else of the character, plus account storage (6, owner = user number)
SELECT i.nStorageType, i.nStorage, i.nItemKey, i.nItemID, i.nOwner, i.nFlags
  FROM tItem i
 WHERE i.nOwner = @c OR (i.nOwner = @u AND i.nStorageType = 6)
 ORDER BY i.nStorageType, i.nStorage;

SELECT o.nItemKey, o.nOptionType, o.nOptionData
  FROM tItemOptions o JOIN tItem i ON i.nItemKey = o.nItemKey
 WHERE i.nOwner = @c OR (i.nOwner = @u AND i.nStorageType = 6)
 ORDER BY o.nItemKey, o.nOptionType;
