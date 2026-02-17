-- create_users.sql - Idempotent creation of test database users in FREEPDB1
--
-- Creates two users:
--   TESTUSER                  - password-authenticated test account
--   oracleuser@CORP.INTERNAL  - Kerberos-authenticated (IDENTIFIED EXTERNALLY)

ALTER SESSION SET CONTAINER = FREEPDB1;

-- Password-authenticated test user
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM all_users WHERE username = 'TESTUSER';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER testuser IDENTIFIED BY testpassword';
    EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO testuser';
    DBMS_OUTPUT.PUT_LINE('Created testuser');
  END IF;
END;
/

-- Kerberos-authenticated user (maps to the AD principal oracleuser@CORP.INTERNAL)
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM all_users WHERE username = 'oracleuser@CORP.INTERNAL';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER "oracleuser@CORP.INTERNAL" IDENTIFIED EXTERNALLY AS ''oracleuser@CORP.INTERNAL''';
    EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO "oracleuser@CORP.INTERNAL"';
    DBMS_OUTPUT.PUT_LINE('Created oracleuser@CORP.INTERNAL');
  END IF;
END;
/

SELECT username FROM all_users WHERE username IN ('TESTUSER', 'ORACLEUSER@CORP.INTERNAL');
EXIT;
