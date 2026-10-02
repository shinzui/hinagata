-- Run only inside the owned catalog bootstrap transaction after validating v1.
-- The caller substitutes one quoted, validated SQL identifier for %SCHEMA%.
ALTER TABLE %SCHEMA%.generations ADD COLUMN last_error text;
ALTER TABLE %SCHEMA%.allocations ADD COLUMN last_error text;
ALTER TABLE %SCHEMA%.meta DROP CONSTRAINT meta_format_version_check;
UPDATE %SCHEMA%.meta SET format_version = 2 WHERE singleton AND format_version = 1;
ALTER TABLE %SCHEMA%.meta ADD CONSTRAINT meta_format_version_check CHECK (format_version = 2);
