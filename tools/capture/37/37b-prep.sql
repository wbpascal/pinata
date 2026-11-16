-- Scenario 37, second run (37b): the char-select paths s37 left open (capture-validation §4.2 "never seen on the WM").
-- Run by 37b-server.ps1 prep with account "admin" logged out (the WM reads the avatar list at the world login).
--   $(DashChar)  character that gets a '-' in its name  -> the client forces the plain rename 0x140F (mode 2)
--   $(DashName)  that name (must contain '-')
--   $(RightChar) character that gets a tCharacterChangeID row (bFlag 0, bInit 0) -> rename right 0xB409 (mode 3)
-- Undo: 37b-cleanup.sql (restores both names from dbo.X37_save, removes the rows inserted here and by the run).
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET LOCK_TIMEOUT 10000;
USE $(CharDb);

IF OBJECT_ID('dbo.X37_save') IS NOT NULL
BEGIN RAISERROR('dbo.X37_save exists: prep already ran. Go on with the run, or run cleanup first.', 16, 1); RETURN; END

DECLARE @dash int  = (SELECT nCharNo FROM tCharacter WHERE sID = N'$(DashChar)'  AND bDeleted = 0);
DECLARE @right int = (SELECT nCharNo FROM tCharacter WHERE sID = N'$(RightChar)' AND bDeleted = 0);
IF @dash IS NULL  BEGIN RAISERROR('character $(DashChar) not found (give -DashChar <a spare character of admin>)', 16, 1); RETURN; END
IF @right IS NULL BEGIN RAISERROR('character $(RightChar) not found (give -RightChar <a character of admin>)', 16, 1); RETURN; END
IF (SELECT nUserNo FROM tCharacter WHERE nCharNo = @dash) <> (SELECT nUserNo FROM tCharacter WHERE nCharNo = @right)
BEGIN RAISERROR('$(DashChar) and $(RightChar) are on different accounts', 16, 1); RETURN; END
IF EXISTS (SELECT 1 FROM tCharacter WHERE sID IN (N'$(DashName)', N'X37Ren', N'X37Id'))
BEGIN RAISERROR('one of the names $(DashName) / X37Ren / X37Id is already taken: pick others', 16, 1); RETURN; END
IF EXISTS (SELECT 1 FROM tCharacterChangeID WHERE bFlag = 0 AND nCharNo = @dash)
BEGIN RAISERROR('$(DashChar) already has an open rename right (tCharacterChangeID bFlag 0): the client would take mode 3, not the plain rename', 16, 1); RETURN; END

CREATE TABLE dbo.X37_save (what varchar(8) NOT NULL, nCharNo int NOT NULL, nUserNo int NOT NULL, sID nvarchar(40) NOT NULL,
                           maxRowNo int NOT NULL, saved datetime NOT NULL DEFAULT GETDATE());
INSERT dbo.X37_save (what, nCharNo, nUserNo, sID, maxRowNo)
SELECT 'dash', nCharNo, nUserNo, sID, (SELECT ISNULL(MAX(nRowNo), 0) FROM tCharacterChangeID) FROM tCharacter WHERE nCharNo = @dash
UNION ALL
SELECT 'right', nCharNo, nUserNo, sID, (SELECT ISNULL(MAX(nRowNo), 0) FROM tCharacterChangeID) FROM tCharacter WHERE nCharNo = @right;

BEGIN TRAN;
UPDATE tCharacter SET sID = N'$(DashName)' WHERE nCharNo = @dash;
INSERT INTO tCharacterChangeID (nUserNo, nCharNo, bInit)            -- the columns usp_Character_setChangeIDItemUsed fills
SELECT nUserNo, nCharNo, 0 FROM tCharacter WHERE nCharNo = @right;   -- bInit 0: no friend / guild / marriage reset
-- tutorial done (nState 2, as 24-prep.sql) for the '-' character: in state 0 its start in step b2 meets P02-B33 first
-- ("The Map is under maintenance" from the tutorial skip, capture-validation §22.2). Left at 2 by the cleanup.
IF OBJECT_ID('dbo.usp_Tutorial_setCharInfo') IS NOT NULL
BEGIN
    DECLARE @r int;
    DECLARE @nd int = (SELECT nUserNo FROM tCharacter WHERE nCharNo = @dash);
    EXEC usp_Tutorial_setCharInfo @nd, @dash, 2, 0, @r OUTPUT;
END
ELSE PRINT 'no usp_Tutorial_setCharInfo in this DB: start $(DashChar) once and answer the tutorial question with "skip" before the run';
COMMIT;
PRINT 'prep done: $(DashChar) -> $(DashName); rename right for $(RightChar) (old values in dbo.X37_save)';

-- What the installed procedures do (decides the prediction of steps 2 and 3)
SELECT 'p_Char_Rename' AS proc_name,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.p_Char_Rename')) LIKE '%tCharacterChangeID%'
            THEN '2018 Fixes copy: renames only with an open tCharacterChangeID row, else reports ok and renames nothing'
            ELSE 'original: plain UPDATE, nRet = @@ERROR' END AS variant;
SELECT 'unique index on tCharacter.sID' AS check_name, i.name AS index_name, i.is_unique
  FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
  JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
 WHERE i.object_id = OBJECT_ID('dbo.tCharacter') AND c.name = 'sID';
-- leftovers of earlier setups (should be empty or known)
SELECT name AS open_x02_or_x37_object FROM sys.objects WHERE name LIKE 'X02[_]%' OR name LIKE 'X37[_]%';
