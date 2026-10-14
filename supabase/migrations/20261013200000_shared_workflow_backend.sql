create table public.workflows (
  id uuid primary key,
  name text not null check (char_length(btrim(name)) between 1 and 200),
  owner_id uuid not null references auth.users (id),
  version bigint not null default 1 check (version > 0),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz
);

create table public.workflow_members (
  workflow_id uuid not null references public.workflows (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('owner', 'editor', 'viewer')),
  position bigint not null default 0,
  version bigint not null default 1 check (version > 0),
  added_by uuid not null references auth.users (id),
  created_at timestamptz not null default clock_timestamp(),
  primary key (workflow_id, user_id)
);

create table public.todos (
  id uuid primary key,
  workflow_id uuid not null references public.workflows (id) on delete cascade,
  description text not null check (char_length(btrim(description)) between 1 and 2000),
  due_at timestamptz,
  duration_minutes integer check (duration_minutes is null or duration_minutes > 0),
  notes text,
  completed boolean not null default false,
  position bigint not null default 0,
  version bigint not null default 1 check (version > 0),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  deleted_at timestamptz
);

create index workflows_owner_updated_idx
  on public.workflows (owner_id, updated_at desc);
create index workflows_name_idx
  on public.workflows (lower(name), id)
  where deleted_at is null;
create index workflow_members_user_position_idx
  on public.workflow_members (user_id, position, workflow_id);
create unique index workflow_members_single_owner_idx
  on public.workflow_members (workflow_id)
  where role = 'owner';
create index todos_workflow_position_idx
  on public.todos (workflow_id, position, id)
  where deleted_at is null;
create index todos_workflow_due_idx
  on public.todos (workflow_id, due_at, id)
  where deleted_at is null;
create index todos_workflow_duration_idx
  on public.todos (workflow_id, duration_minutes, id)
  where deleted_at is null;
create index todos_workflow_completed_idx
  on public.todos (workflow_id, completed, position, id)
  where deleted_at is null;

-- This transactional counter keeps change cursors in commit order. A plain
-- sequence can be allocated by one transaction and committed after a later
-- sequence, which can make a cursor-based client miss the earlier change.
create table public.sync_clock (
  singleton boolean primary key default true check (singleton),
  last_cursor bigint not null default 0 check (last_cursor >= 0),
  min_retained_cursor bigint not null default 0
    check (min_retained_cursor >= 0 and min_retained_cursor <= last_cursor)
);

insert into public.sync_clock (singleton, last_cursor) values (true, 0);

create table public.sync_events (
  cursor bigint primary key,
  workflow_id uuid,
  entity_type text not null check (entity_type in ('workflow', 'todo', 'workflow_order', 'membership')),
  entity_id uuid not null,
  version bigint not null,
  action text not null check (action in ('upsert', 'delete')),
  payload jsonb not null,
  changed_by uuid not null references auth.users (id),
  created_at timestamptz not null default clock_timestamp()
);

create index sync_events_workflow_cursor_idx
  on public.sync_events (workflow_id, cursor);
create index sync_events_actor_cursor_idx
  on public.sync_events (changed_by, cursor)
  where entity_type = 'workflow_order';

create table public.sync_operations (
  operation_id uuid primary key,
  user_id uuid not null references auth.users (id),
  request jsonb not null,
  result jsonb,
  created_at timestamptz not null default clock_timestamp()
);

create table public.workflow_order_state (
  user_id uuid primary key references auth.users (id) on delete cascade,
  version bigint not null default 0 check (version >= 0),
  updated_at timestamptz not null default clock_timestamp()
);

alter table public.workflows enable row level security;
alter table public.workflow_members enable row level security;
alter table public.todos enable row level security;
alter table public.sync_events enable row level security;
alter table public.sync_clock enable row level security;
alter table public.sync_operations enable row level security;
alter table public.workflow_order_state enable row level security;

create function public.is_workflow_member(p_workflow_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.workflow_members member
    where member.workflow_id = p_workflow_id
      and member.user_id = auth.uid()
  );
$$;

revoke all on function public.is_workflow_member(uuid) from public, anon;
grant execute on function public.is_workflow_member(uuid) to authenticated;

create policy workflows_read_member
  on public.workflows for select to authenticated
  using (deleted_at is null and public.is_workflow_member(id));

create policy workflow_members_read_member
  on public.workflow_members for select to authenticated
  using (
    public.is_workflow_member(workflow_id)
    and exists (
      select 1
      from public.workflows workflow
      where workflow.id = workflow_id
        and workflow.deleted_at is null
    )
  );

create policy todos_read_member
  on public.todos for select to authenticated
  using (
    deleted_at is null
    and public.is_workflow_member(workflow_id)
    and exists (
      select 1
      from public.workflows workflow
      where workflow.id = workflow_id
        and workflow.deleted_at is null
    )
  );

create policy sync_events_read_member
  on public.sync_events for select to authenticated
  using (
    (entity_type = 'workflow_order' and changed_by = auth.uid())
    or (
      entity_type <> 'workflow_order'
      and public.is_workflow_member(workflow_id)
    )
  );

revoke all on public.workflows, public.workflow_members, public.todos,
  public.sync_events, public.sync_clock, public.sync_operations,
  public.workflow_order_state
  from anon, authenticated;

grant select on public.workflows, public.workflow_members, public.todos,
  public.sync_events to authenticated;

create function public.list_workflows(
  p_sort text default 'manual',
  p_after_position bigint default null,
  p_after_name text default null,
  p_after_id uuid default null,
  p_limit integer default 100
)
returns setof public.workflows
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if p_sort is null or p_sort not in ('manual', 'alphabetical') then
    raise exception 'sort must be manual or alphabetical';
  end if;
  if p_sort = 'manual'
    and ((p_after_position is null) <> (p_after_id is null)) then
    raise exception 'Manual workflow cursors need both position and id';
  end if;
  if p_sort = 'alphabetical'
    and ((p_after_name is null) <> (p_after_id is null)) then
    raise exception 'Alphabetical workflow cursors need both name and id';
  end if;

  if p_sort = 'manual' then
    return query
    select workflow.*
    from public.workflows workflow
    join public.workflow_members member on member.workflow_id = workflow.id
    where member.user_id = auth.uid()
      and workflow.deleted_at is null
      and (
        p_after_position is null
        or (member.position, workflow.id) > (p_after_position, p_after_id)
      )
    order by member.position, workflow.id
    limit greatest(1, least(coalesce(p_limit, 100), 1000));
  else
    return query
    select workflow.*
    from public.workflows workflow
    join public.workflow_members member on member.workflow_id = workflow.id
    where member.user_id = auth.uid()
      and workflow.deleted_at is null
      and (
        p_after_name is null
        or (lower(workflow.name), workflow.id) > (lower(p_after_name), p_after_id)
      )
    order by lower(workflow.name), workflow.id
    limit greatest(1, least(coalesce(p_limit, 100), 1000));
  end if;
end;
$$;

-- Keyset pagination uses the same column ordering as the matching indexes.
create function public.list_todos(
  p_workflow_id uuid,
  p_sort text default 'manual',
  p_filter text default 'all',
  p_cursor jsonb default null,
  p_limit integer default 100
)
returns setof public.todos
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 1000));
  v_cursor_id uuid;
  v_position bigint;
  v_due_at timestamptz;
  v_duration integer;
  v_completed boolean;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if p_workflow_id is null then
    raise exception 'workflow_id is required';
  end if;
  if p_sort is null or p_sort not in ('manual', 'due', 'duration', 'completed') then
    raise exception 'sort must be manual, due, duration, or completed';
  end if;
  if p_filter is null or p_filter not in ('all', 'active', 'completed') then
    raise exception 'filter must be all, active, or completed';
  end if;

  if p_cursor is not null then
    if jsonb_typeof(p_cursor) <> 'object' then
      raise exception 'cursor must be a JSON object';
    end if;
    v_cursor_id := (p_cursor ->> 'id')::uuid;
    if v_cursor_id is null then
      raise exception 'cursor.id is required';
    end if;

    if p_sort in ('manual', 'completed') then
      v_position := (p_cursor ->> 'position')::bigint;
      if v_position is null then
        raise exception 'cursor.position is required';
      end if;
    end if;
    if p_sort = 'due' then
      if not (p_cursor ? 'due_at') then
        raise exception 'cursor.due_at is required';
      end if;
      v_due_at := nullif(p_cursor ->> 'due_at', '')::timestamptz;
    elsif p_sort = 'duration' then
      if not (p_cursor ? 'duration_minutes') then
        raise exception 'cursor.duration_minutes is required';
      end if;
      v_duration := nullif(p_cursor ->> 'duration_minutes', '')::integer;
    elsif p_sort = 'completed' then
      v_completed := (p_cursor ->> 'completed')::boolean;
      if v_completed is null then
        raise exception 'cursor.completed is required';
      end if;
    end if;
  end if;

  if p_sort = 'manual' then
    return query
    select task.*
    from public.todos task
    where task.workflow_id = p_workflow_id
      and task.deleted_at is null
      and (
        p_filter = 'all'
        or (p_filter = 'active' and not task.completed)
        or (p_filter = 'completed' and task.completed)
      )
      and (
        p_cursor is null
        or (task.position, task.id) > (v_position, v_cursor_id)
      )
    order by task.position, task.id
    limit v_limit;
  elsif p_sort = 'due' then
    return query
    select task.*
    from public.todos task
    where task.workflow_id = p_workflow_id
      and task.deleted_at is null
      and (
        p_filter = 'all'
        or (p_filter = 'active' and not task.completed)
        or (p_filter = 'completed' and task.completed)
      )
      and (
        p_cursor is null
        or (
          (v_due_at is null and task.due_at is null and task.id > v_cursor_id)
          or (
            v_due_at is not null
            and (
              task.due_at > v_due_at
              or task.due_at is null
              or (task.due_at = v_due_at and task.id > v_cursor_id)
            )
          )
        )
      )
    order by task.due_at asc nulls last, task.id
    limit v_limit;
  elsif p_sort = 'duration' then
    return query
    select task.*
    from public.todos task
    where task.workflow_id = p_workflow_id
      and task.deleted_at is null
      and (
        p_filter = 'all'
        or (p_filter = 'active' and not task.completed)
        or (p_filter = 'completed' and task.completed)
      )
      and (
        p_cursor is null
        or (
          (v_duration is null and task.duration_minutes is null and task.id > v_cursor_id)
          or (
            v_duration is not null
            and (
              task.duration_minutes > v_duration
              or task.duration_minutes is null
              or (task.duration_minutes = v_duration and task.id > v_cursor_id)
            )
          )
        )
      )
    order by task.duration_minutes asc nulls last, task.id
    limit v_limit;
  else
    return query
    select task.*
    from public.todos task
    where task.workflow_id = p_workflow_id
      and task.deleted_at is null
      and (
        p_filter = 'all'
        or (p_filter = 'active' and not task.completed)
        or (p_filter = 'completed' and task.completed)
      )
      and (
        p_cursor is null
        or (task.completed, task.position, task.id)
          > (v_completed, v_position, v_cursor_id)
      )
    order by task.completed, task.position, task.id
    limit v_limit;
  end if;
end;
$$;

create function public.apply_sync_operation(p_operation jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_operation_id uuid;
  v_entity_type text;
  v_entity_id uuid;
  v_workflow_id uuid;
  v_workflow_ids uuid[];
  v_action text;
  v_expected_version bigint;
  v_payload jsonb;
  v_role text;
  v_existing_result jsonb;
  v_existing_request jsonb;
  v_result jsonb;
  v_operation_owner uuid;
  v_rows integer;
  v_cursor bigint;
  v_workflow public.workflows%rowtype;
  v_todo public.todos%rowtype;
  v_name text;
  v_description text;
  v_duration integer;
  v_position bigint;
  v_due_at timestamptz;
  v_completed boolean;
  v_order_version bigint;
  v_current_order jsonb;
begin
  if v_user_id is null then
    raise exception 'Authentication is required';
  end if;

  if p_operation is null or jsonb_typeof(p_operation) <> 'object' then
    raise exception 'Each sync operation must be a JSON object';
  end if;

  v_operation_id := (p_operation ->> 'operation_id')::uuid;
  v_entity_type := p_operation ->> 'entity_type';
  v_entity_id := (p_operation ->> 'entity_id')::uuid;
  v_action := p_operation ->> 'action';
  v_expected_version := nullif(p_operation ->> 'expected_version', '')::bigint;
  v_payload := coalesce(p_operation -> 'payload', '{}'::jsonb);

  if v_operation_id is null or v_entity_id is null then
    raise exception 'operation_id and entity_id are required';
  end if;
  if v_entity_type is null
    or v_entity_type not in ('workflow', 'todo', 'workflow_order') then
    raise exception 'entity_type must be workflow, todo, or workflow_order';
  end if;
  if v_action is null or v_action not in ('upsert', 'delete') then
    raise exception 'action must be upsert or delete';
  end if;
  if jsonb_typeof(v_payload) <> 'object' then
    raise exception 'payload must be a JSON object';
  end if;

  select operation.request, operation.result
  into v_existing_request, v_existing_result
  from public.sync_operations operation
  where operation.operation_id = v_operation_id
    and operation.user_id = v_user_id;

  if found then
    if v_existing_request <> p_operation then
      raise exception 'operation_id was already used for a different operation';
    end if;
    if v_existing_result is null then
      raise exception 'This operation is already being processed';
    end if;
    return v_existing_result;
  end if;

  insert into public.sync_operations (operation_id, user_id, request)
  values (v_operation_id, v_user_id, p_operation)
  on conflict (operation_id) do nothing;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    select operation.user_id, operation.request, operation.result
    into v_operation_owner, v_existing_request, v_existing_result
    from public.sync_operations operation
    where operation.operation_id = v_operation_id;

    if v_operation_owner <> v_user_id then
      raise exception 'operation_id is already used by another user';
    end if;
    if v_existing_request <> p_operation then
      raise exception 'operation_id was already used for a different operation';
    end if;
    if v_existing_result is null then
      raise exception 'This operation is already being processed';
    end if;
    return v_existing_result;
  end if;

  if v_entity_type = 'workflow_order' then
    if v_action <> 'upsert' then
      raise exception 'workflow_order only supports upsert operations';
    end if;
    if jsonb_typeof(v_payload -> 'workflow_ids') is distinct from 'array' then
      raise exception 'workflow_order payload must include a workflow_ids array';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(v_payload -> 'workflow_ids') as requested(workflow_id)
      where requested.workflow_id = 'null'::jsonb
    ) then
      raise exception 'workflow_ids cannot contain null values';
    end if;
    if v_entity_id <> v_user_id then
      raise exception 'workflow_order entity_id must match the current user';
    end if;

    select coalesce(array_agg(item.workflow_id order by item.ordinality), array[]::uuid[])
    into v_workflow_ids
    from jsonb_array_elements_text(v_payload -> 'workflow_ids')
      with ordinality as item(workflow_id, ordinality);

    insert into public.workflow_order_state (user_id)
    values (v_user_id)
    on conflict (user_id) do nothing;

    select state.version
    into v_order_version
    from public.workflow_order_state state
    where state.user_id = v_user_id
    for update;

    select coalesce(
      jsonb_agg(member.workflow_id order by member.position, member.workflow_id),
      '[]'::jsonb
    )
    into v_current_order
    from public.workflow_members member
    join public.workflows workflow on workflow.id = member.workflow_id
    where member.user_id = v_user_id
      and workflow.deleted_at is null;

    if v_expected_version is null or v_expected_version <> v_order_version then
      v_result := jsonb_build_object(
        'status', 'conflict',
        'entity_type', v_entity_type,
        'entity_id', v_entity_id,
        'version', v_order_version,
        'current', v_current_order
      );
    else
      perform public.set_workflow_order(v_workflow_ids);

      update public.workflow_order_state
      set version = version + 1,
          updated_at = clock_timestamp()
      where user_id = v_user_id
      returning version into v_order_version;

      update public.sync_clock
      set last_cursor = last_cursor + 1
      where singleton
      returning last_cursor into v_cursor;

      insert into public.sync_events (
        cursor, workflow_id, entity_type, entity_id, version, action, payload, changed_by
      )
      values (
        v_cursor, null, 'workflow_order', v_user_id, v_order_version, 'upsert',
        jsonb_build_object('workflow_ids', to_jsonb(v_workflow_ids)), v_user_id
      );

      v_result := jsonb_build_object(
        'status', 'applied',
        'entity_type', v_entity_type,
        'entity_id', v_entity_id,
        'version', v_order_version,
        'cursor', v_cursor,
        'current', jsonb_build_object('workflow_ids', to_jsonb(v_workflow_ids))
      );
    end if;

    update public.sync_operations
    set result = v_result
    where operation_id = v_operation_id
      and user_id = v_user_id;

    return v_result;
  end if;

  if v_entity_type = 'workflow' then
    v_workflow_id := v_entity_id;
  else
    v_workflow_id := (p_operation ->> 'workflow_id')::uuid;
    if v_workflow_id is null then
      raise exception 'workflow_id is required for todo operations';
    end if;
  end if;

  select member.role
  into v_role
  from public.workflow_members member
  where member.workflow_id = v_workflow_id
    and member.user_id = v_user_id;

  if v_entity_type = 'workflow' then
    select *
    into v_workflow
    from public.workflows
    where id = v_entity_id
    for update;

    if not found then
      if v_action = 'delete' then
        raise exception 'Cannot delete a workflow that does not exist';
      end if;
      if v_expected_version is distinct from 0 then
        v_result := jsonb_build_object(
          'status', 'conflict',
          'entity_type', v_entity_type,
          'entity_id', v_entity_id,
          'current', null
        );
      else
        v_name := btrim(v_payload ->> 'name');
        if v_name is null or char_length(v_name) not between 1 and 200 then
          raise exception 'Workflow name must be between 1 and 200 characters';
        end if;

        insert into public.workflows (id, name, owner_id)
        values (v_entity_id, v_name, v_user_id)
        returning * into v_workflow;

        select coalesce(max(member.position) + 1, 0)
        into v_position
        from public.workflow_members member
        where member.user_id = v_user_id;

        insert into public.workflow_members (workflow_id, user_id, role, position, added_by)
        values (v_entity_id, v_user_id, 'owner', v_position, v_user_id);

        update public.sync_clock
        set last_cursor = last_cursor + 1
        where singleton
        returning last_cursor into v_cursor;

        insert into public.sync_events (
          cursor, workflow_id, entity_type, entity_id, version, action, payload, changed_by
        )
        values (
          v_cursor, v_entity_id, 'workflow', v_entity_id, v_workflow.version,
          'upsert', to_jsonb(v_workflow), v_user_id
        );

        v_result := jsonb_build_object(
          'status', 'applied',
          'entity_type', v_entity_type,
          'entity_id', v_entity_id,
          'version', v_workflow.version,
          'cursor', v_cursor,
          'current', to_jsonb(v_workflow)
        );
      end if;
    elsif coalesce(v_role not in ('owner', 'editor'), true) then
      raise exception 'The current user cannot edit this workflow';
    elsif v_workflow.deleted_at is not null then
      raise exception 'The workflow has been deleted';
    elsif v_expected_version is null or v_expected_version <> v_workflow.version then
      v_result := jsonb_build_object(
        'status', 'conflict',
        'entity_type', v_entity_type,
        'entity_id', v_entity_id,
        'current', to_jsonb(v_workflow)
      );
    elsif v_action = 'delete' and v_role <> 'owner' then
      raise exception 'Only a workflow owner can delete the workflow';
    else
      if v_action = 'delete' then
        update public.workflows
        set deleted_at = clock_timestamp(),
            updated_at = clock_timestamp(),
            version = version + 1
        where id = v_entity_id
        returning * into v_workflow;
      else
        v_name := btrim(v_payload ->> 'name');
        if v_name is null or char_length(v_name) not between 1 and 200 then
          raise exception 'Workflow name must be between 1 and 200 characters';
        end if;
        update public.workflows
        set name = v_name,
            updated_at = clock_timestamp(),
            version = version + 1
        where id = v_entity_id
        returning * into v_workflow;
      end if;

      update public.sync_clock
      set last_cursor = last_cursor + 1
      where singleton
      returning last_cursor into v_cursor;

      insert into public.sync_events (
        cursor, workflow_id, entity_type, entity_id, version, action, payload, changed_by
      )
      values (
        v_cursor, v_entity_id, 'workflow', v_entity_id, v_workflow.version,
        v_action, to_jsonb(v_workflow), v_user_id
      );

      v_result := jsonb_build_object(
        'status', 'applied',
        'entity_type', v_entity_type,
        'entity_id', v_entity_id,
        'version', v_workflow.version,
        'cursor', v_cursor,
        'current', to_jsonb(v_workflow)
      );
    end if;
  else
    if coalesce(v_role not in ('owner', 'editor'), true) then
      raise exception 'The current user cannot edit this workflow';
    end if;
    if exists (
      select 1
      from public.workflows workflow
      where workflow.id = v_workflow_id
        and workflow.deleted_at is not null
    ) then
      raise exception 'The workflow has been deleted';
    end if;

    select *
    into v_todo
    from public.todos
    where id = v_entity_id
    for update;

    if not found then
      if v_action = 'delete' then
        v_result := jsonb_build_object(
          'status', 'conflict',
          'entity_type', v_entity_type,
          'entity_id', v_entity_id,
          'current', null
        );
      elsif v_expected_version is distinct from 0 then
        v_result := jsonb_build_object(
          'status', 'conflict',
          'entity_type', v_entity_type,
          'entity_id', v_entity_id,
          'current', null
        );
      else
        v_description := btrim(v_payload ->> 'description');
        if v_description is null or char_length(v_description) not between 1 and 2000 then
          raise exception 'Todo description must be between 1 and 2000 characters';
        end if;
        v_duration := nullif(v_payload ->> 'duration_minutes', '')::integer;
        v_position := coalesce(nullif(v_payload ->> 'position', '')::bigint, 0);
        v_due_at := nullif(v_payload ->> 'due_at', '')::timestamptz;
        v_completed := coalesce((v_payload ->> 'completed')::boolean, false);

        insert into public.todos (
          id, workflow_id, description, due_at, duration_minutes, notes,
          completed, position
        )
        values (
          v_entity_id, v_workflow_id, v_description, v_due_at, v_duration,
          nullif(v_payload ->> 'notes', ''), v_completed, v_position
        )
        returning * into v_todo;

        update public.sync_clock
        set last_cursor = last_cursor + 1
        where singleton
        returning last_cursor into v_cursor;

        insert into public.sync_events (
          cursor, workflow_id, entity_type, entity_id, version, action, payload, changed_by
        )
        values (
          v_cursor, v_workflow_id, 'todo', v_entity_id, v_todo.version,
          'upsert', to_jsonb(v_todo), v_user_id
        );

        v_result := jsonb_build_object(
          'status', 'applied',
          'entity_type', v_entity_type,
          'entity_id', v_entity_id,
          'version', v_todo.version,
          'cursor', v_cursor,
          'current', to_jsonb(v_todo)
        );
      end if;
    elsif v_todo.workflow_id <> v_workflow_id then
      raise exception 'A todo cannot be moved between workflows by sync';
    elsif v_todo.deleted_at is not null then
      v_result := jsonb_build_object(
        'status', 'conflict',
        'entity_type', v_entity_type,
        'entity_id', v_entity_id,
        'current', to_jsonb(v_todo)
      );
    elsif v_expected_version is null or v_expected_version <> v_todo.version then
      v_result := jsonb_build_object(
        'status', 'conflict',
        'entity_type', v_entity_type,
        'entity_id', v_entity_id,
        'current', to_jsonb(v_todo)
      );
    else
      if v_action = 'delete' then
        update public.todos
        set deleted_at = clock_timestamp(),
            updated_at = clock_timestamp(),
            version = version + 1
        where id = v_entity_id
        returning * into v_todo;
      else
        v_description := btrim(v_payload ->> 'description');
        if v_description is null or char_length(v_description) not between 1 and 2000 then
          raise exception 'Todo description must be between 1 and 2000 characters';
        end if;
        v_duration := nullif(v_payload ->> 'duration_minutes', '')::integer;
        v_position := coalesce(nullif(v_payload ->> 'position', '')::bigint, 0);
        v_due_at := nullif(v_payload ->> 'due_at', '')::timestamptz;
        v_completed := coalesce((v_payload ->> 'completed')::boolean, false);

        update public.todos
        set description = v_description,
            due_at = v_due_at,
            duration_minutes = v_duration,
            notes = nullif(v_payload ->> 'notes', ''),
            completed = v_completed,
            position = v_position,
            updated_at = clock_timestamp(),
            version = version + 1
        where id = v_entity_id
        returning * into v_todo;
      end if;

      update public.sync_clock
      set last_cursor = last_cursor + 1
      where singleton
      returning last_cursor into v_cursor;

      insert into public.sync_events (
        cursor, workflow_id, entity_type, entity_id, version, action, payload, changed_by
      )
      values (
        v_cursor, v_workflow_id, 'todo', v_entity_id, v_todo.version,
        v_action, to_jsonb(v_todo), v_user_id
      );

      v_result := jsonb_build_object(
        'status', 'applied',
        'entity_type', v_entity_type,
        'entity_id', v_entity_id,
        'version', v_todo.version,
        'cursor', v_cursor,
        'current', to_jsonb(v_todo)
      );
    end if;
  end if;

  update public.sync_operations
  set result = v_result
  where operation_id = v_operation_id
    and user_id = v_user_id;

  return v_result;
end;
$$;

create function public.sync_apply_batch(p_operations jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_operation jsonb;
  v_results jsonb := '[]'::jsonb;
  v_count integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if p_operations is null or jsonb_typeof(p_operations) <> 'array' then
    raise exception 'operations must be a JSON array';
  end if;

  v_count := jsonb_array_length(p_operations);
  if v_count > 100 then
    raise exception 'A sync batch cannot contain more than 100 operations';
  end if;

  for v_operation in select value from jsonb_array_elements(p_operations)
  loop
    v_results := v_results || jsonb_build_array(
      public.apply_sync_operation(v_operation)
    );
  end loop;

  return v_results;
end;
$$;

create function public.sync_pull(p_cursor bigint default 0, p_limit integer default 500)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_page jsonb;
  v_events jsonb;
  v_limit integer := greatest(1, least(coalesce(p_limit, 500), 1000));
  v_next_cursor bigint;
  v_high_watermark bigint;
  v_min_retained_cursor bigint;
  v_has_more boolean;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if p_cursor is null or p_cursor < 0 then
    raise exception 'cursor must be a non-negative integer';
  end if;
  select clock.last_cursor, clock.min_retained_cursor
  into v_high_watermark, v_min_retained_cursor
  from public.sync_clock clock
  where clock.singleton;
  if p_cursor > v_high_watermark then
    raise exception 'cursor is ahead of the server';
  end if;
  if p_cursor < v_min_retained_cursor then
    return jsonb_build_object(
      'events', '[]'::jsonb,
      'next_cursor', v_high_watermark,
      'has_more', false,
      'snapshot_required', true
    );
  end if;

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'cursor', page.cursor,
          'workflow_id', page.workflow_id,
          'entity_type', page.entity_type,
          'entity_id', page.entity_id,
          'version', page.version,
          'action', page.action,
          'payload', page.payload,
          'changed_by', page.changed_by,
          'created_at', page.created_at
        ) order by page.cursor
      ) filter (where page.cursor is not null),
      '[]'::jsonb
    ),
    clock.last_cursor
  into v_page, v_high_watermark
  from public.sync_clock clock
  left join lateral (
    select event.*
    from public.sync_events event
    where event.cursor > p_cursor
      and (
        public.is_workflow_member(event.workflow_id)
        or (
          event.entity_type = 'workflow_order'
          and event.changed_by = auth.uid()
        )
      )
    order by event.cursor
    limit v_limit + 1
  ) page on true
  group by clock.last_cursor;

  v_has_more := jsonb_array_length(v_page) > v_limit;
  if v_has_more then
    v_next_cursor := (v_page -> (v_limit - 1) ->> 'cursor')::bigint;
    select coalesce(jsonb_agg(item.value order by item.ordinality), '[]'::jsonb)
    into v_events
    from jsonb_array_elements(v_page) with ordinality as item(value, ordinality)
    where item.ordinality <= v_limit;
  else
    v_events := v_page;
    v_next_cursor := greatest(p_cursor, v_high_watermark);
  end if;

  return jsonb_build_object(
    'events', v_events,
    'next_cursor', v_next_cursor,
    'has_more', v_has_more,
    'snapshot_required', false
  );
end;
$$;

-- Run only from a trusted maintenance job. Clients with older cursors are
-- instructed to rebuild their local snapshot before continuing to sync.
create function public.prune_sync_events(p_through_cursor bigint)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_last_cursor bigint;
  v_min_retained_cursor bigint;
  v_deleted integer;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Only the service role can prune sync history';
  end if;
  if p_through_cursor is null or p_through_cursor < 0 then
    raise exception 'through_cursor must be non-negative';
  end if;

  select clock.last_cursor, clock.min_retained_cursor
  into v_last_cursor, v_min_retained_cursor
  from public.sync_clock clock
  where clock.singleton
  for update;

  if p_through_cursor > v_last_cursor then
    raise exception 'through_cursor is ahead of the server';
  end if;
  if p_through_cursor < v_min_retained_cursor then
    raise exception 'through_cursor cannot move retention backwards';
  end if;

  delete from public.sync_events
  where cursor <= p_through_cursor;
  get diagnostics v_deleted = row_count;

  update public.sync_clock
  set min_retained_cursor = p_through_cursor
  where singleton;

  return v_deleted;
end;
$$;

create function public.share_workflow(
  p_workflow_id uuid,
  p_user_id uuid,
  p_role text default 'editor'
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cursor bigint;
  v_member_version bigint;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if p_role is null or p_role not in ('editor', 'viewer') then
    raise exception 'Shared members can only be editors or viewers';
  end if;
  if p_user_id is null then
    raise exception 'user_id is required';
  end if;
  if not exists (
    select 1
    from public.workflows workflow
    where workflow.id = p_workflow_id
      and workflow.owner_id = auth.uid()
      and workflow.deleted_at is null
  ) then
    raise exception 'Only the workflow owner can manage sharing';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'The owner cannot change their own role';
  end if;

  insert into public.workflow_members (workflow_id, user_id, role, position, added_by)
  select
    p_workflow_id,
    p_user_id,
    p_role,
    coalesce(max(member.position) + 1, 0),
    auth.uid()
  from public.workflow_members member
  where member.user_id = p_user_id
  on conflict (workflow_id, user_id)
  do update set role = excluded.role,
                version = workflow_members.version + 1,
                added_by = excluded.added_by
  returning version into v_member_version;

  update public.sync_clock
  set last_cursor = last_cursor + 1
  where singleton
  returning last_cursor into v_cursor;

  insert into public.sync_events (
    cursor, workflow_id, entity_type, entity_id, version, action, payload, changed_by
  )
  values (
    v_cursor, p_workflow_id, 'membership', p_workflow_id, v_member_version, 'upsert',
    jsonb_build_object(
      'workflow_id', p_workflow_id,
      'user_id', p_user_id,
      'role', p_role,
      'version', v_member_version
    ),
    auth.uid()
  );
end;
$$;

create function public.revoke_workflow_member(p_workflow_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if not exists (
    select 1
    from public.workflows workflow
    where workflow.id = p_workflow_id
      and workflow.owner_id = auth.uid()
  ) then
    raise exception 'Only the workflow owner can manage sharing';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'The owner cannot remove themselves';
  end if;
  if p_user_id is null then
    raise exception 'user_id is required';
  end if;

  delete from public.workflow_members
  where workflow_id = p_workflow_id
    and user_id = p_user_id
    and role <> 'owner';
end;
$$;

create function public.set_workflow_order(p_workflow_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required';
  end if;
  if p_workflow_ids is null then
    raise exception 'workflow_ids is required';
  end if;
  if cardinality(p_workflow_ids) <> (
    select count(distinct requested.workflow_id)
    from unnest(p_workflow_ids) as requested(workflow_id)
  ) then
    raise exception 'workflow_ids cannot contain nulls or duplicates';
  end if;
  if exists (
    select 1
    from unnest(p_workflow_ids) as requested(workflow_id)
    where not exists (
      select 1
      from public.workflow_members member
      join public.workflows workflow on workflow.id = member.workflow_id
      where member.workflow_id = requested.workflow_id
        and member.user_id = auth.uid()
        and workflow.deleted_at is null
    )
  ) then
    raise exception 'Every workflow must be active and belong to the current user';
  end if;
  if cardinality(p_workflow_ids) <> (
    select count(*)
    from public.workflow_members member
    join public.workflows workflow on workflow.id = member.workflow_id
    where member.user_id = auth.uid()
      and workflow.deleted_at is null
  ) then
    raise exception 'workflow_ids must include every active workflow';
  end if;

  update public.workflow_members member
  set position = requested.ordinality - 1
  from unnest(p_workflow_ids) with ordinality as requested(workflow_id, ordinality)
  where member.workflow_id = requested.workflow_id
    and member.user_id = auth.uid();
end;
$$;

revoke all on function public.apply_sync_operation(jsonb) from public, anon, authenticated;
revoke all on function public.sync_apply_batch(jsonb) from public, anon;
revoke all on function public.sync_pull(bigint, integer) from public, anon;
revoke all on function public.list_workflows(text, bigint, text, uuid, integer) from public, anon;
revoke all on function public.list_todos(uuid, text, text, jsonb, integer) from public, anon;
revoke all on function public.prune_sync_events(bigint) from public, anon, authenticated;
revoke all on function public.share_workflow(uuid, uuid, text) from public, anon;
revoke all on function public.revoke_workflow_member(uuid, uuid) from public, anon;
revoke all on function public.set_workflow_order(uuid[]) from public, anon;

grant execute on function public.sync_apply_batch(jsonb) to authenticated;
grant execute on function public.sync_pull(bigint, integer) to authenticated;
grant execute on function public.list_workflows(text, bigint, text, uuid, integer) to authenticated;
grant execute on function public.list_todos(uuid, text, text, jsonb, integer) to authenticated;
grant execute on function public.prune_sync_events(bigint) to service_role;
grant execute on function public.share_workflow(uuid, uuid, text) to authenticated;
grant execute on function public.revoke_workflow_member(uuid, uuid) to authenticated;
