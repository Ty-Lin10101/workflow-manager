begin;

set local search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select no_plan();

select ok(
  (select count(*) = 7
   from pg_catalog.pg_class relation
   join pg_catalog.pg_namespace ns on ns.oid = relation.relnamespace
   where ns.nspname = 'public'
     and relation.relkind = 'r'
     and relation.relname in (
       'workflows',
       'workflow_members',
       'todos',
       'sync_events',
       'sync_clock',
       'sync_operations',
       'workflow_order_state'
     )),
  'all expected backend tables exist'
);

select ok(
  (select count(*) = 7
   from pg_catalog.pg_class relation
   join pg_catalog.pg_namespace ns on ns.oid = relation.relnamespace
   where ns.nspname = 'public'
     and relation.relkind = 'r'
     and relation.relname in (
       'workflows',
       'workflow_members',
       'todos',
       'sync_events',
       'sync_clock',
       'sync_operations',
       'workflow_order_state'
     )
     and relation.relrowsecurity),
  'row-level security is enabled on all backend tables'
);

select ok(
  (select count(*) = 4
   from pg_catalog.pg_policies
   where schemaname = 'public'
     and policyname in (
       'workflows_read_member',
       'workflow_members_read_member',
       'todos_read_member',
       'sync_events_read_member'
     )),
  'member-read policies exist for exposed tables'
);

select ok(
  has_column('public', 'workflows', 'owner_id')
    and has_column('public', 'workflows', 'version')
    and has_column('public', 'workflow_members', 'role')
    and has_column('public', 'todos', 'workflow_id')
    and has_column('public', 'todos', 'position')
    and has_column('public', 'todos', 'version')
    and has_column('public', 'sync_events', 'cursor')
      and has_column('public', 'sync_operations', 'operation_id')
      and has_column('public', 'workflow_order_state', 'version')
      and has_column('public', 'sync_clock', 'min_retained_cursor'),
  'schema contains ownership, membership, version, and sync cursor fields'
);

select ok(
  has_index('public', 'workflows', 'workflows_owner_updated_idx')
    and has_index('public', 'workflow_members', 'workflow_members_user_position_idx')
    and has_index('public', 'todos', 'todos_workflow_position_idx')
    and has_index('public', 'sync_events', 'sync_events_workflow_cursor_idx'),
  'key lookup and cursor indexes exist'
);

select ok(
  has_table_privilege('authenticated', 'public.workflows', 'SELECT')
    and not has_table_privilege('authenticated', 'public.workflows', 'INSERT')
    and not has_table_privilege('anon', 'public.workflows', 'SELECT'),
  'table grants limit direct access to authenticated reads'
);

select ok(
  has_function_privilege('authenticated', 'public.sync_apply_batch(jsonb)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.sync_pull(bigint,integer)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.sync_snapshot_anchor()', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.list_workflows(text,bigint,text,uuid,integer)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.list_todos(uuid,text,text,jsonb,integer)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.share_workflow(uuid,uuid,text)', 'EXECUTE')
    and has_function_privilege('service_role', 'public.prune_sync_events(bigint)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.prune_sync_events(bigint)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.apply_sync_operation(jsonb)', 'EXECUTE'),
  'RPC grants expose client entry points while reserving maintenance and internal functions'
);

insert into auth.users (id, aud, role, email)
values
  ('00000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'owner@test.invalid'),
  ('00000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'editor@test.invalid'),
  ('00000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'viewer@test.invalid'),
  ('00000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'outsider@test.invalid');

create temporary table backend_test_results (
  result_key text primary key,
  result_value jsonb not null
);
grant select, insert on backend_test_results to authenticated;

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

insert into backend_test_results (result_key, result_value)
select 'workflow_create',
  public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000001',
    'entity_type', 'workflow',
    'entity_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 0,
    'payload', jsonb_build_object('name', 'Shared workflow')
  )));

select is(
  (select result_value -> 0 ->> 'status'
   from backend_test_results where result_key = 'workflow_create'),
  'applied',
  'owner can create a workflow'
);

select is(
  (select role
   from public.workflow_members
   where workflow_id = '10000000-0000-0000-0000-000000000001'
     and user_id = '00000000-0000-0000-0000-000000000001'),
  'owner',
  'workflow creation creates owner membership'
);

insert into backend_test_results (result_key, result_value)
select 'todo_create',
  public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000002',
    'entity_type', 'todo',
    'entity_id', '20000000-0000-0000-0000-000000000001',
    'workflow_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 0,
    'payload', jsonb_build_object('description', 'First todo')
  )));

select is(
  (select result_value -> 0 ->> 'status'
   from backend_test_results where result_key = 'todo_create'),
  'applied',
  'owner can create a todo'
);

select is(
  (select version::integer
   from public.todos
   where id = '20000000-0000-0000-0000-000000000001'),
  1,
  'new todos start at version one'
);

select is(
  (select count(*)::integer
   from public.list_workflows('manual', null, null, null, 10)),
  1,
  'workflow keyset pagination returns the caller’s workflow'
);

select is(
  (select count(*)::integer
   from public.list_todos(
     '10000000-0000-0000-0000-000000000001',
     'manual',
     'all',
     null,
     10
   )),
  1,
  'todo keyset pagination returns active workflow todos'
);

select is(
  public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000002',
    'entity_type', 'todo',
    'entity_id', '20000000-0000-0000-0000-000000000001',
    'workflow_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 0,
    'payload', jsonb_build_object('description', 'First todo')
  ))),
  (select result_value from backend_test_results where result_key = 'todo_create'),
  'replaying an operation returns its original result'
);

select throws_ok(
  $$select public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000002',
    'entity_type', 'todo',
    'entity_id', '20000000-0000-0000-0000-000000000001',
    'workflow_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 0,
    'payload', jsonb_build_object('description', 'Reused ID with changed request')
  )))$$,
  'P0001',
  'operation_id was already used for a different operation',
  'an operation ID cannot be reused with changed contents'
);

select is(
  (select count(*)::integer
   from public.sync_events
   where entity_id = '20000000-0000-0000-0000-000000000001'),
  1,
  'replaying an operation does not emit a duplicate event'
);

select public.share_workflow(
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'editor'
);
select public.share_workflow(
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000003',
  'viewer'
);

select is(
  (select string_agg(role, ',' order by role)
   from public.workflow_members
   where workflow_id = '10000000-0000-0000-0000-000000000001'),
  'editor,owner,viewer',
  'sharing assigns supported editor and viewer roles'
);

select throws_ok(
  $$select public.share_workflow(
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000004',
    'admin'
  )$$,
  'P0001',
  'Shared members can only be editors or viewers',
  'sharing rejects unsupported roles'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);

insert into backend_test_results (result_key, result_value)
select 'editor_todo_create',
  public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000003',
    'entity_type', 'todo',
    'entity_id', '20000000-0000-0000-0000-000000000002',
    'workflow_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 0,
    'payload', jsonb_build_object('description', 'Editor todo')
  )));

select is(
  (select result_value -> 0 ->> 'status'
   from backend_test_results where result_key = 'editor_todo_create'),
  'applied',
  'editors can create todos'
);

select throws_ok(
  $$select public.share_workflow(
    '10000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000004',
    'viewer'
  )$$,
  'P0001',
  'Only the workflow owner can manage sharing',
  'editors cannot manage membership'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);

select throws_ok(
  $$select public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000004',
    'entity_type', 'todo',
    'entity_id', '20000000-0000-0000-0000-000000000003',
    'workflow_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 0,
    'payload', jsonb_build_object('description', 'Viewer write')
  )))$$,
  'P0001',
  'The current user cannot edit this workflow',
  'viewers cannot mutate workflow data'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

insert into backend_test_results (result_key, result_value)
select 'todo_update',
  public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000005',
    'entity_type', 'todo',
    'entity_id', '20000000-0000-0000-0000-000000000001',
    'workflow_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 1,
    'payload', jsonb_build_object('description', 'Updated todo')
  )));

select is(
  (select result_value -> 0 ->> 'status'
   from backend_test_results where result_key = 'todo_update'),
  'applied',
  'matching versions allow an optimistic update'
);

insert into backend_test_results (result_key, result_value)
select 'cursor_before_stale_update',
  to_jsonb(last_cursor)
from public.sync_clock
where singleton;

insert into backend_test_results (result_key, result_value)
select 'todo_stale_update',
  public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000006',
    'entity_type', 'todo',
    'entity_id', '20000000-0000-0000-0000-000000000001',
    'workflow_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 1,
    'payload', jsonb_build_object('description', 'Stale update')
  )));

select is(
  (select result_value -> 0 ->> 'status'
   from backend_test_results where result_key = 'todo_stale_update'),
  'conflict',
  'stale versions return a conflict'
);

select is(
  (select (result_value -> 0 -> 'current' ->> 'version')::integer
   from backend_test_results where result_key = 'todo_stale_update'),
  2,
  'a conflict returns the current version'
);

select is(
  (select last_cursor::bigint from public.sync_clock where singleton),
  (select (result_value #>> '{}')::bigint
   from backend_test_results where result_key = 'cursor_before_stale_update'),
  'a stale update does not advance the event cursor'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

select ok(
  jsonb_array_length(public.sync_pull(0, 2) -> 'events') <= 2,
  'cursor pages do not exceed the requested limit'
);

select is(
  (public.sync_pull(0, 2) ->> 'has_more')::boolean,
  true,
  'cursor pages report when more events are available'
);

select is(
  (public.sync_pull(0, 2) ->> 'next_cursor')::bigint,
  ((public.sync_pull(0, 2) -> 'events' -> 1 ->> 'cursor')::bigint),
  'a partial page cursor points to its last returned event'
);

select is(
  (public.sync_snapshot_anchor() ->> 'cursor')::bigint,
  (select last_cursor from public.sync_clock where singleton),
  'snapshot anchor returns the current high-water mark'
);

select is(
  (public.sync_snapshot_anchor() ->> 'min_retained_cursor')::bigint,
  0::bigint,
  'snapshot anchor reports the initial retention floor'
);

select is(
  jsonb_array_length(public.sync_pull(0, 0) -> 'events'),
  1,
  'non-positive page limits are bounded to one event'
);

insert into backend_test_results (result_key, result_value)
select 'cursor_before_cap_test',
  to_jsonb(last_cursor)
from public.sync_clock
where singleton;

do $$
declare
  v_start_cursor bigint;
begin
  select last_cursor into v_start_cursor
  from public.sync_clock
  where singleton;

  insert into public.sync_events (
    cursor, workflow_id, entity_type, entity_id, version, action, payload, changed_by
  )
  select
    v_start_cursor + event_number,
    '10000000-0000-0000-0000-000000000001',
    'workflow',
    '10000000-0000-0000-0000-000000000001',
    1,
    'upsert',
    '{}'::jsonb,
    '00000000-0000-0000-0000-000000000001'
  from generate_series(1, 1001) event_number;

  update public.sync_clock
  set last_cursor = v_start_cursor + 1001
  where singleton;
end;
$$;

select is(
  jsonb_array_length(
    public.sync_pull(
      (select (result_value #>> '{}')::bigint
       from backend_test_results where result_key = 'cursor_before_cap_test'),
      5000
    ) -> 'events'
  ),
  1000,
  'oversized cursor requests are capped at one thousand events'
);

select is(
  (public.sync_pull(
    (select (result_value #>> '{}')::bigint
     from backend_test_results where result_key = 'cursor_before_cap_test'),
    5000
  ) ->> 'has_more')::boolean,
  true,
  'capped cursor pages report that more events remain'
);

select is(
  (public.sync_pull(
    (select (result_value #>> '{}')::bigint
     from backend_test_results where result_key = 'cursor_before_cap_test'),
    5000
  ) ->> 'next_cursor')::bigint,
  (select (result_value #>> '{}')::bigint + 1000
   from backend_test_results where result_key = 'cursor_before_cap_test'),
  'the capped page cursor advances only through returned events'
);

select is(
  jsonb_array_length(
    public.sync_pull(
      (select (result_value #>> '{}')::bigint + 1000
       from backend_test_results where result_key = 'cursor_before_cap_test'),
      5000
    ) -> 'events'
  ),
  1,
  'the next cursor page returns the remaining event'
);

select is(
  (public.sync_pull(
    (select (result_value #>> '{}')::bigint + 1000
     from backend_test_results where result_key = 'cursor_before_cap_test'),
    5000
  ) ->> 'has_more')::boolean,
  false,
  'the final cursor page reports no further events'
);

set local role authenticated;
set local search_path = public, extensions;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);

select is(
  (select count(*)::integer from public.workflows),
  1,
  'workflow members can read their workflows under RLS'
);

select is(
  (select count(*)::integer
   from public.workflow_members
   where workflow_id = '10000000-0000-0000-0000-000000000001'),
  3,
  'members can read workflow membership under RLS'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);
set local role authenticated;
set local search_path = public, extensions;

select is(
  (select count(*)::integer from public.workflows),
  0,
  'non-members cannot read workflows under RLS'
);

reset role;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000004', true);

select is(
  (public.sync_pull(0, 10) ->> 'has_more')::boolean,
  false,
  'cursor pulls exclude events for workflows without membership'
);

select is(
  jsonb_array_length(public.sync_pull(0, 10) -> 'events'),
  0,
  'non-members receive no workflow events'
);

select throws_ok(
  $$select public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000007',
    'entity_type', 'workflow',
    'entity_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 1,
    'payload', jsonb_build_object('name', 'Unauthorized workflow update')
  )))$$,
  'P0001',
  'The current user cannot edit this workflow',
  'non-members cannot mutate workflows'
);

select throws_ok(
  $$select public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000008',
    'entity_type', 'todo',
    'entity_id', '20000000-0000-0000-0000-000000000001',
    'workflow_id', '10000000-0000-0000-0000-000000000001',
    'action', 'upsert',
    'expected_version', 2,
    'payload', jsonb_build_object('description', 'Unauthorized todo update')
  )))$$,
  'P0001',
  'The current user cannot edit this workflow',
  'non-members cannot mutate todos'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$select public.prune_sync_events(0)$$,
  'P0001',
  'Only the service role can prune sync history',
  'authenticated users cannot prune sync history'
);

insert into backend_test_results (result_key, result_value)
select 'cursor_before_member_revoke',
  to_jsonb(last_cursor)
from public.sync_clock
where singleton;

insert into backend_test_results (result_key, result_value)
select 'member_order_version_before_revoke',
  to_jsonb(version)
from public.workflow_order_state
where user_id = '00000000-0000-0000-0000-000000000003';

select public.revoke_workflow_member(
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000003'
);

select is(
  (select count(*)::integer
   from public.workflow_members
   where workflow_id = '10000000-0000-0000-0000-000000000001'
     and user_id = '00000000-0000-0000-0000-000000000003'),
  0,
  'owner revocation removes the selected member'
);

select is(
  (select version
   from public.workflow_order_state
   where user_id = '00000000-0000-0000-0000-000000000003'),
  (select (result_value #>> '{}')::bigint + 1
   from backend_test_results
   where result_key = 'member_order_version_before_revoke'),
  'owner revocation advances the removed member order version'
);

select is(
  (select count(*)::integer
   from public.sync_events
   where cursor > (
       select (result_value #>> '{}')::bigint
       from backend_test_results
       where result_key = 'cursor_before_member_revoke'
     )
     and workflow_id = '10000000-0000-0000-0000-000000000001'
     and entity_type = 'membership_revoked'
     and entity_id = '00000000-0000-0000-0000-000000000003'
     and action = 'delete'
     and payload ->> 'user_id' = '00000000-0000-0000-0000-000000000003'),
  1,
  'owner revocation publishes a scoped membership-revoked event'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', true);

select is(
  (select count(*)::integer
   from jsonb_array_elements(
     public.sync_pull(
       (select (result_value #>> '{}')::bigint
        from backend_test_results
        where result_key = 'cursor_before_member_revoke'),
       10
     ) -> 'events'
   ) event
   where event.value ->> 'entity_type' = 'membership_revoked'
     and event.value ->> 'entity_id' = '00000000-0000-0000-0000-000000000003'
     and event.value ->> 'action' = 'delete'),
  1,
  'revoked members can pull their scoped removal event'
);

select is(
  (public.sync_snapshot_anchor() ->> 'workflow_order_version')::bigint,
  (select version
   from public.workflow_order_state
   where user_id = '00000000-0000-0000-0000-000000000003'),
  'the revoked member snapshot anchor exposes the updated order version'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"service_role"}',
  true
);
select set_config('request.jwt.claim.role', 'service_role', true);

insert into backend_test_results (result_key, result_value)
select 'pruned_event_count',
  to_jsonb(public.prune_sync_events(last_cursor))
from public.sync_clock
where singleton;

select is(
  (select (result_value #>> '{}')::bigint
   from backend_test_results
   where result_key = 'pruned_event_count'),
  (select last_cursor
   from public.sync_clock
   where singleton),
  'service role can prune events through the current cursor'
);

select is(
  (public.sync_pull(0, 10) ->> 'snapshot_required')::boolean,
  true,
  'clients behind retention are told to rebuild their snapshot'
);

select is(
  (public.sync_snapshot_anchor() ->> 'min_retained_cursor')::bigint,
  (select last_cursor
   from public.sync_clock
   where singleton),
  'snapshot anchor advances to the pruned cursor'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into backend_test_results (result_key, result_value)
select 'cursor_before_workflow_delete',
  to_jsonb(last_cursor)
from public.sync_clock
where singleton;

insert into backend_test_results (result_key, result_value)
select 'workflow_delete',
  public.sync_apply_batch(jsonb_build_array(jsonb_build_object(
    'operation_id', '30000000-0000-0000-0000-000000000009',
    'entity_type', 'workflow',
    'entity_id', '10000000-0000-0000-0000-000000000001',
    'action', 'delete',
    'expected_version', 1,
    'payload', '{}'::jsonb
  )));

select is(
  (select result_value -> 0 ->> 'status'
   from backend_test_results
   where result_key = 'workflow_delete'),
  'applied',
  'owner can soft-delete a workflow'
);

set local role authenticated;
set local search_path = public, extensions;

select is(
  (select count(*)::integer
   from public.workflows
   where id = '10000000-0000-0000-0000-000000000001'),
  0,
  'RLS hides deleted workflows from member snapshots'
);

select is(
  (select count(*)::integer
   from jsonb_array_elements(
     public.sync_pull(
       (select (result_value #>> '{}')::bigint
        from backend_test_results
        where result_key = 'cursor_before_workflow_delete'),
       10
     ) -> 'events'
   ) event
   where event.value ->> 'entity_type' = 'workflow'
     and event.value ->> 'action' = 'delete'
     and event.value ->> 'workflow_id' = '10000000-0000-0000-0000-000000000001'),
  1,
  'members can receive a workflow-delete event after deletion'
);

reset role;

select * from finish();
rollback;
