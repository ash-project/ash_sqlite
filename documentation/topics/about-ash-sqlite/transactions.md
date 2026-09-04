<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Transactions

Ash can wrap a write action in a database transaction, so everything the action
does either lands together or not at all. **Prefer having them on.** They are what
makes a multi-step action safe, and several Ash features rely on them:

- **A failed action leaves nothing behind.** Without a transaction, a create whose
  `after_action` hook fails has already committed its insert, and there is nothing
  to undo it. With one, the failure rolls the insert back.
- **`manage_relationship` writes land together.** An action that writes a record
  and its related records either writes all of them or none.
- **Notifications wait for the commit.** Ash holds notifications raised inside a
  transaction until it commits, so a subscriber never sees a change that was later
  rolled back.

## Enabling transactions

Transactions are configured on the **repo**, not on each resource, as in
`AshPostgres` — where `prefer_transaction?/0` is likewise a repo callback:

```elixir
defmodule MyApp.Repo do
  use AshSqlite.Repo, otp_app: :my_app

  def write_transactions?, do: true
end
```

`mix igniter.install ash_sqlite` writes this for you, so a newly generated app
already has transactions on. Existing apps opt in by adding the
`c:AshSqlite.Repo.write_transactions?/0` callback; `AshSqlite.Repo` will default it
to `false`, so upgrading the dependency changes nothing on its own.

Every resource whose `sqlite` block names this repo may then have its write
actions wrapped. It belongs on the repo because everything that makes a
transaction safe is repo configuration — the pool size, the busy timeout, whether
the connection is read only. There is no per-resource knob that changes any of
those.

To keep a particular action out of a transaction, set `transaction? false` on the
action. Ash derives `transaction? true` on create, update and destroy actions when
the data layer supports transactions, so on a repo that has not opted in
`Ash.Resource.Info.action(MyApp.Post, :create).transaction?` reads `false`.

## SQLite's single writer

SQLite allows one write lock at a time, and a write attempted while another
transaction holds that lock fails rather than queueing. This is why transactions
are opt in here and not in `ash_postgres`.

In practice two settings make it a non-issue:

- **`busy_timeout`** — how long SQLite retries the write lock before giving up.
  `ecto_sqlite3` defaults it to `2000`, and the installer sets it explicitly
  alongside `:timeout`:

  ```elixir
  # config/config.exs
  config :my_app, MyApp.Repo,
    timeout: 15_000,
    busy_timeout: 16_000
  ```

  **Keep `busy_timeout` above `:timeout`.** A write waits `min(busy_timeout,
  :timeout)` for the lock, so whichever is smaller decides when it gives up. With
  `busy_timeout` on top, the caller's `:timeout` is the only deadline that matters
  and a contended write behaves as it would on Postgres: it waits, and succeeds if
  the lock frees in time. Put it underneath and the write abandons a lock it was
  still willing to wait for.

  ```
  longest competing lock hold  ≲  :timeout  <  busy_timeout
  ```

  Raise `busy_timeout` too if you raise `:timeout`, for the same reason.

- **`default_transaction_mode`** — not needed for Ash's transactions. AshSqlite
  issues `BEGIN IMMEDIATE` itself whatever this is set to. Set it only if you want
  the same for `Repo.transaction/2` calls you make directly.

> ### Why IMMEDIATE {: .info}
>
> A deferred transaction takes no lock until its first write, so a read-then-write
> has to *upgrade* to the write lock partway through. SQLite cannot make an upgrade
> wait: the snapshot the transaction already read from may be stale by the time the
> lock frees, so it fails immediately no matter how long `busy_timeout` is.
> `BEGIN IMMEDIATE` takes the lock up front, and has nothing to upgrade.

Note that a single node with `pool_size: 1` cannot contend with itself — one
connection means two of your processes never hold the write lock at once, and
contention surfaces as a checkout timeout rather than `SQLITE_BUSY`. What
`busy_timeout` covers is writers the pool cannot see: a second node, another OS
process, or a `litestream` against the same file.

## Pool size

> ### Keep pool_size: 1 for writes {: .warning}
>
> SQLite does not support parallel writes, so a write pool larger than 1 will only
> cause contention. Set `pool_size: 1` on any repo that performs writes.

Read concurrency comes from a second, read-only repo rather than from a larger
write pool.

## Separate read and write repos

For applications that need read concurrency, configure a read-only repo alongside
the write repo. The write repo takes a single connection; the read repo opens
several.

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  database: "path/to/my_app.db",
  pool_size: 1

config :my_app, MyApp.Repo.ReadOnly,
  database: "path/to/my_app.db",
  pool_size: 10,
  read_only: true
```

```elixir
# lib/my_app/repo.ex
defmodule MyApp.Repo do
  use AshSqlite.Repo, otp_app: :my_app

  def write_transactions?, do: true
end

defmodule MyApp.Repo.ReadOnly do
  use AshSqlite.Repo, otp_app: :my_app
end
```

Start both in your supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyApp.Repo.ReadOnly,
  ...
]
```

Then route reads and writes with the `repo` DSL option. It takes a capture of a
named function in another module, which receives the resource and either `:read`
or `:mutate` and returns a repo:

```elixir
defmodule MyApp.Routing do
  def repo(_resource, :mutate), do: MyApp.Repo
  def repo(_resource, :read), do: MyApp.Repo.ReadOnly
end
```

```elixir
sqlite do
  repo &MyApp.Routing.repo/2
  table "posts"
end
```

`write_transactions?` is read from the `:mutate` repo, so the read-only repo never
needs to declare it.

An inline `fn` is refused. Spark compiles it into a function on the resource
itself, and the repo is asked whether it takes transactions while that module is
still compiling, so there is nothing to call yet.
