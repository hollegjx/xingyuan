-- Synthetic G3 gate only. No production goals, reminders or private text.
create table public.g3_probe_records (
  id uuid primary key,
  owner_id uuid not null references auth.users (id) on delete cascade,
  value integer not null check (value between 0 and 1000000)
);

alter table public.g3_probe_records enable row level security;
alter table public.g3_probe_records force row level security;

revoke all on table public.g3_probe_records from public, anon, authenticated;
grant select on table public.g3_probe_records to authenticated;

create policy g3_probe_read_own on public.g3_probe_records
  for select to authenticated
  using ((select auth.uid()) = owner_id);

create function public.g3_probe_write(p_id uuid, p_value integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller uuid := auth.uid();
  saved public.g3_probe_records;
begin
  if caller is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;
  if p_id is null or p_value is null or p_value < 0 or p_value > 1000000 then
    raise exception using errcode = '22023', message = 'Invalid probe input';
  end if;

  insert into public.g3_probe_records as target (id, owner_id, value)
    values (p_id, caller, p_value)
    on conflict (id) do update set value = excluded.value
      where target.owner_id = caller
    returning * into saved;
  if not found then
    raise exception using errcode = '42501', message = 'Operation not permitted';
  end if;
  return jsonb_build_object(
    'id', saved.id, 'owner_id', saved.owner_id, 'value', saved.value
  );
end;
$$;

create function public.g3_probe_delete(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller uuid := auth.uid();
begin
  if caller is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;
  -- An absent and an inaccessible ID are indistinguishable to the caller.
  delete from public.g3_probe_records where id = p_id and owner_id = caller;
  return found;
end;
$$;

revoke all on function public.g3_probe_write(uuid, integer)
  from public, anon, authenticated;
revoke all on function public.g3_probe_delete(uuid)
  from public, anon, authenticated;
grant execute on function public.g3_probe_write(uuid, integer) to authenticated;
grant execute on function public.g3_probe_delete(uuid) to authenticated;
