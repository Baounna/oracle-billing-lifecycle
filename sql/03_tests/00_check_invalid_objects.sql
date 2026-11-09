-- Fails (exit code <> 0) if any TELCO_OWNER object is invalid.
select object_type, object_name, status from user_objects where status <> 'VALID';
declare
  n number;
begin
  select count(*) into n from user_objects where status <> 'VALID';
  if n > 0 then
    raise_application_error(-20000, n || ' invalid object(s)');
  end if;
  dbms_output.put_line('All objects valid');
end;
/
