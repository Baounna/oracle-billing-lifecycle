-- =============================================================================
-- 01_tablespaces.sql
-- Purpose : Create one tablespace per storage tier and cap the growth of the
--           shared UNDO/TEMP files so the lab can never fill the host disk.
-- Run as  : SYSDBA inside ORCLPDB1 (scripts/01_setup_db.sh)
-- Params  : &datafile_dir
--
--   TELCO_HOT   current (hot) billing data, uncompressed, read/write
--   TELCO_IDX   indexes of the hot data
--   TELCO_ARCH  warm + archived data, basic-compressed, read-only partitions
-- =============================================================================

declare
  procedure create_ts(p_name varchar2, p_file varchar2, p_size varchar2, p_max varchar2) is
    l_count number;
  begin
    select count(*) into l_count from dba_tablespaces where tablespace_name = p_name;
    if l_count = 0 then
      execute immediate 'create tablespace ' || p_name ||
        ' datafile ''&datafile_dir/' || p_file || ''' size ' || p_size ||
        ' autoextend on next 256M maxsize ' || p_max ||
        ' extent management local segment space management auto';
      dbms_output.put_line('Created tablespace ' || p_name || ' (max ' || p_max || ')');
    else
      dbms_output.put_line('Tablespace ' || p_name || ' already exists - skipped');
    end if;
  end;
begin
  create_ts('TELCO_HOT',  'telco_hot01.dbf',  '512M', '7G');
  create_ts('TELCO_IDX',  'telco_idx01.dbf',  '256M', '4G');
  create_ts('TELCO_ARCH', 'telco_arch01.dbf', '256M', '4G');
end;
/

-- UNDO and TEMP default to autoextend up to 32 GB: cap them.
alter database datafile '&datafile_dir/undotbs01.dbf' autoextend on next 128M maxsize 4G;
-- Grow TEMP to 512M only if smaller (shrinking a used tempfile fails with ORA-03297).
begin
  for t in (select file_name from dba_temp_files
            where file_name = '&datafile_dir/temp01.dbf' and bytes < 512 * 1048576) loop
    execute immediate 'alter database tempfile ''' || t.file_name || ''' resize 512M';
  end loop;
end;
/
alter database tempfile '&datafile_dir/temp01.dbf' autoextend on next 128M maxsize 3G;

select tablespace_name, round(sum(bytes)/1048576) size_mb, round(sum(maxbytes)/1048576) max_mb
from   dba_data_files
group  by tablespace_name
order  by 1;
