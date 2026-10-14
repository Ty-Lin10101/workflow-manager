# Shared workflow backend

This directory contains the Supabase/PostgreSQL backend. The backend keeps SQL
queries, authorization, membership changes, and conflict checks on the server;
desktop clients keep a local SQLite cache and durable outbox for offline work.

## Local setup and deployment

1. Install the Supabase CLI and Docker Desktop.
2. Start the local Supabase stack:

   ```sh
   supabase start
   ```

3. Apply migrations and run the database tests:

   ```sh
   supabase db reset
   supabase test db
   ```

For a hosted project, create a Supabase project, link it with `supabase link`,
then apply migrations with `supabase db push`. Authentication is provided by
Supabase Auth. Do not commit project secrets or a service-role key; desktop
clients must use only the project URL and publishable/anon key, plus the signed
in user's access token.

## Data and authorization

- `workflows` and `todos` are normalized PostgreSQL tables with stable UUIDs,
  soft-delete tombstones, and monotonically increasing entity versions.
- `workflow_members` maps users to workflows as `owner`, `editor`, or `viewer`.
  Sharing is controlled by the owner. Workflow order is a per-user preference,
  not shared state. Share and revoke changes update that user's order version;
  a revoked user receives a scoped removal event without continued read access
  to the workflow's task or history data.
- Row-level security permits authenticated members to read active workflows
  and tasks. All writes go through security-definer RPCs that validate the
  caller, role, payload, and expected version. A viewer cannot write; only an
  owner may delete a workflow or manage membership.
- Indexes and `list_workflows` / `list_todos` RPCs provide bounded keyset
  pagination. Todo filters are `all`, `active`, or `completed`; sort modes are
  `manual`, `due`, `duration`, and `completed`. Cursors are based on the exact
  sort fields plus the task UUID, so equal values and null due dates/durations
  do not skip rows. Workflow pages include the caller's membership `position`
  for manual-order cursors.

## Offline synchronization contract

An outbox operation has a stable `operation_id` (UUID), an `entity_type`,
`entity_id`, `action`, `expected_version`, and JSON `payload`. New workflows
and tasks use `expected_version: 0`; edits and deletes use the last server
version observed by the client. Todo operations also include `workflow_id`.
Workflow ordering is represented by `entity_type: "workflow_order"`,
`entity_id` equal to the signed-in user ID, and a `workflow_ids` array in the
payload. Its `expected_version` is the per-user workflow-order version returned
by `sync_snapshot_anchor()` or the last applied order/membership result.

Send up to 100 pending operations in one atomic call to
`sync_apply_batch({ p_operations: [...] })`. The server remembers each
operation ID and its complete request, so retrying the exact request returns
the original result without applying the write twice. Reusing an ID for a
different request is rejected. Results have `status: "applied"` or
`status: "conflict"`; a conflict includes the current server version/value.
Do not silently overwrite a conflict: refresh the local row and create a new
operation after resolving the user's edit.

Use the following bootstrap and pull loop:

Before replacing a local cache when linking an existing installation to an
account, submit its pending outbox first. Preserve the outbox until every
operation has an applied or explicitly resolved conflict result.

1. Call `sync_snapshot_anchor()` and save its returned cursor.
   Save `workflow_order_version` from the same response.
2. Page through `list_workflows()` and `list_todos()` to replace the local
   membership-visible snapshot. Reconcile memberships on every online
   bootstrap so a removed member's cached workflows are no longer presented.
3. Call `sync_pull({ p_cursor, p_limit })`, apply events in cursor order, and
   persist `next_cursor` only after the corresponding page has been committed
   locally. Continue while `has_more` is true.
4. Push the durable outbox with `sync_apply_batch`, then pull again. Continue
   retrying network failures with the same operation IDs.

The transactional global cursor orders committed sync changes and makes the
pull protocol simple, at the cost of serializing write-cursor allocation. It
is suitable for a small-to-medium shared app; unusually high write throughput
would justify sharding cursor streams by workflow.

`prune_sync_events(p_through_cursor)` is restricted to the Supabase service
role and is intended for a trusted maintenance job. It advances the retained
cursor as it removes old events. A client whose cursor is behind retention
receives `snapshot_required: true`; it must take a new snapshot before pulling
again. Never ship the service-role key in a desktop app.

## SQL/API entry points

- `list_workflows(...)`: membership-scoped, manually or alphabetically sorted
  workflow pages.
- `list_todos(...)`: membership-scoped task query with keyset cursor, filter,
  and sort.
- `share_workflow(...)` / `revoke_workflow_member(...)`: owner-only membership
  management. Shares publish membership events to the new member's sync feed.
- `sync_apply_batch(...)`: atomic, idempotent outbox application with
  optimistic concurrency. Supports workflow, todo, and personal workflow
  ordering changes.
- `sync_snapshot_anchor()` / `sync_pull(...)`: consistent starting cursor and
  bounded event feed.
- `prune_sync_events(...)`: service-role-only event retention maintenance.

The database schema is in `migrations/20261013200000_shared_workflow_backend.sql`.
