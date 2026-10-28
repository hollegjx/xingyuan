-- Run only against the approved dev project, after applying the migration.
-- No pgTAP/Docker required. All fixtures roll back, including on failure.
begin;

select set_config('habit_test.user_a', gen_random_uuid()::text, true);
select set_config('habit_test.user_b', gen_random_uuid()::text, true);
select set_config('habit_test.record_a', gen_random_uuid()::text, true);
select set_config('habit_test.record_b', gen_random_uuid()::text, true);

insert into auth.users (id, aud, role)
  values
    (current_setting('habit_test.user_a')::uuid, 'authenticated', 'authenticated'),
    (current_setting('habit_test.user_b')::uuid, 'authenticated', 'authenticated');

do $$
begin
  if not (
    select relrowsecurity and relforcerowsecurity
    from pg_class where oid = 'public.g3_probe_records'::regclass
  ) then
    raise exception 'G3_RLS_NOT_ENABLED';
  end if;
  if has_table_privilege('anon', 'public.g3_probe_records', 'SELECT')
    or has_table_privilege('authenticated', 'public.g3_probe_records', 'INSERT')
    or has_table_privilege('authenticated', 'public.g3_probe_records', 'UPDATE')
    or has_table_privilege('authenticated', 'public.g3_probe_records', 'DELETE')
    or has_table_privilege('authenticated', 'public.g3_probe_records', 'TRUNCATE')
    or has_function_privilege('anon', 'public.g3_probe_write(uuid,integer)', 'EXECUTE')
    or has_function_privilege('anon', 'public.g3_probe_delete(uuid)', 'EXECUTE') then
    raise exception 'G3_EXCESS_GRANTS';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', json_build_object(
  'sub', current_setting('habit_test.user_a'), 'role', 'authenticated'
)::text, true);
set local role authenticated;

do $$
declare
  record_id uuid := current_setting('habit_test.record_a')::uuid;
  result jsonb;
begin
  result := public.g3_probe_write(record_id, 1);
  if result->>'owner_id' != current_setting('habit_test.user_a')
    or (result->>'value')::integer != 1 then
    raise exception 'G3_A_WRITE';
  end if;
  perform public.g3_probe_write(record_id, 2);
  if (select value from public.g3_probe_records where id = record_id)
    is distinct from 2 then
    raise exception 'G3_A_READ_UPDATE';
  end if;
  begin
    insert into public.g3_probe_records values (
      gen_random_uuid(), current_setting('habit_test.user_b')::uuid, 3
    );
    raise exception 'G3_FORGED_OWNER_ACCEPTED';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.g3_probe_records set owner_id = current_setting('habit_test.user_b')::uuid
      where id = record_id;
    raise exception 'G3_DIRECT_UPDATE_ACCEPTED';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.g3_probe_records where id = record_id;
    raise exception 'G3_DIRECT_DELETE_ACCEPTED';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.g3_probe_write(record_id, -1);
    raise exception 'G3_INVALID_VALUE_ACCEPTED';
  exception when invalid_parameter_value then null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', json_build_object(
  'sub', current_setting('habit_test.user_b'), 'role', 'authenticated'
)::text, true);
set local role authenticated;

do $$
declare
  record_a uuid := current_setting('habit_test.record_a')::uuid;
  record_b uuid := current_setting('habit_test.record_b')::uuid;
begin
  if exists (select from public.g3_probe_records where id = record_a) then
    raise exception 'G3_B_READ_A';
  end if;
  begin
    perform public.g3_probe_write(record_a, 3);
    raise exception 'G3_B_WRITE_A';
  exception when insufficient_privilege then null;
  end;
  if public.g3_probe_delete(record_a) then
    raise exception 'G3_B_DELETE_A';
  end if;
  perform public.g3_probe_write(record_b, 4);
  if (select owner_id from public.g3_probe_records where id = record_b)
    is distinct from current_setting('habit_test.user_b')::uuid then
    raise exception 'G3_B_OWN_RECORD';
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claims', '{}', true);
set local role anon;

do $$
begin
  begin
    perform * from public.g3_probe_records;
    raise exception 'G3_ANON_READ';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.g3_probe_write(current_setting('habit_test.record_a')::uuid, 5);
    raise exception 'G3_ANON_WRITE';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.g3_probe_delete(current_setting('habit_test.record_a')::uuid);
    raise exception 'G3_ANON_DELETE';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
-- A missing JWT subject must fail even when a role has function execution.
set local role authenticated;
do $$
begin
  begin
    perform public.g3_probe_write(current_setting('habit_test.record_a')::uuid, 6);
    raise exception 'G3_MISSING_SUBJECT_WRITE';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.g3_probe_delete(current_setting('habit_test.record_a')::uuid);
    raise exception 'G3_MISSING_SUBJECT_DELETE';
  exception when insufficient_privilege then null;
  end;
end;
$$;

reset role;
select set_config('request.jwt.claims', json_build_object(
  'sub', current_setting('habit_test.user_a'), 'role', 'authenticated'
)::text, true);
set local role authenticated;
do $$
declare
  record_id uuid := current_setting('habit_test.record_a')::uuid;
begin
  if (select value from public.g3_probe_records where id = record_id)
    is distinct from 2 then
    raise exception 'G3_A_RECORD_CHANGED';
  end if;
  if not public.g3_probe_delete(record_id)
    or exists (select from public.g3_probe_records where id = record_id) then
    raise exception 'G3_A_DELETE';
  end if;
end;
$$;
reset role;
rollback;
select 'G3_SQL_ROLE_PROBE_PASS' as result;
