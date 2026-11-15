-- Scenario 21 step 12, run "21b": removes the S16 trigger again (right after the purchase).
USE World00_Character;
IF OBJECT_ID('dbo.X02_tItemOptions_fail') IS NOT NULL DROP TRIGGER dbo.X02_tItemOptions_fail;
PRINT 'S16 trigger removed';
