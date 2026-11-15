-- Scenario 24 clean-up check. Delete X24A and X24B in the client first (character select -> delete), then run:
--   sqlcmd -S . -E -i 24-cleanup.sql
-- Expected: both rows with bDeleted = 1 (or no row), and no GM character left from this scenario.
SET NOCOUNT ON;
USE World00_Character;
SELECT nCharNo, sID, nLevel, nAdminLevel, bDeleted, dDeletedDate FROM tCharacter WHERE sID IN (N'X24A', N'X24B');

-- If you keep the characters for later scenarios instead, at least take the GM level away:
-- UPDATE tCharacter SET nAdminLevel = 0 WHERE sID IN (N'X24A', N'X24B') AND bDeleted = 0;
