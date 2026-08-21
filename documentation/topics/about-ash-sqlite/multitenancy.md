<!--
SPDX-FileCopyrightText: 2020 Zach Daniel

SPDX-License-Identifier: MIT
-->

# Multitenancy

AshSqlite supports `strategy :context` multitenancy, which for SQLite means **one
database file per tenant**.

This is not the same shape as AshPostgres. There, `:context` sets a schema prefix
on the query and one connection serves every tenant. SQLite has no schemas, so
there is no prefix to set: the generated SQL is identical for every tenant, and
isolation comes entirely from **which database file the connection is attached
to**.

`AshSqlite.DataLayer.set_tenant/3` is therefore a no-op on the query. Declaring the
strategy does two useful things anyway — it makes Ash accept the resource, and it
makes Ash enforce its own "a tenant is required unless `global?`" rule.

> ### Declaring the strategy does not isolate anything {: .warning}
>
> If every tenant resolves to the same database, every tenant shares a table and
> nothing here will say so. Choosing the connection is a separate job, described
> below, and it is the part that actually separates tenants.

## Tenant binders

A **tenant binder** is the module that chooses the connection a tenanted statement
runs on:

```elixir
sqlite do
  table "posts"
  repo MyApp.Repo
  tenant_binder MyApp.TenantBinder
end
```

```elixir
defmodule MyApp.TenantBinder do
  @behaviour AshSqlite.TenantBinder

  @impl true
  def bind(tenant, _opts, fun) do
    previous = MyApp.Repo.get_dynamic_repo()
    MyApp.Repo.put_dynamic_repo(MyApp.Tenants.repo_for!(tenant))

    try do
      fun.()
    after
      MyApp.Repo.put_dynamic_repo(previous)
    end
  end
end
```

Every statement the data layer issues for a tenanted resource is wrapped in
`c:AshSqlite.TenantBinder.bind/3` with that statement's tenant — reads, aggregates,
creates, atomic updates, atomic destroys and bulk operations alike.

### Why this is a data layer concern rather than the caller's

Binding `c:Ecto.Repo.put_dynamic_repo/1` before calling Ash does work, and it is
what applications did before this existed. The trouble is that it puts the burden
at every entry point, and some entry points cannot carry it:

- `Ash.count/2` never enters `Ash.Actions.Read`, so no preparation or
  `around_transaction` hook runs for it.
- Ash calls `c:Ash.Resource.Change.atomic/3` instead of `change/3` whenever it can
  build one statement, so a hook-installing change forces `require_atomic? false`.
- The binding is ambient, so it does not survive `Task.async`, an `Ash.load`
  fan-out, or a background job.

The data layer is the only seam that sees every path.

### The contract

`bind/3` receives the tenant, options describing the statement, and a zero-arity
function, and must return whatever that function returns.

**Whatever it does to select a connection, it must undo.** These callbacks run on
processes the binder does not own, and a binding left behind is a later statement
misdirected — into another tenant's database.

**It must fail loudly rather than falling through.** Returning without having bound
anything means the statement runs on the default connection.

The `opts` carry `:resource` and a `:usage` of `:read`, `:write` or `:transaction`.
Only the data layer can say which, since by the time a binder sees a statement the
difference has been compiled into SQL it does not parse. A binder might use it to
serve reads from a replica or a cached projection and send writes to the owner.
Binders that do not care can ignore it.

## Transactions

Transactions and per-tenant databases interact in two ways worth knowing.

`c:Ash.DataLayer.transaction/4` is called *above* the data layer, so unlike every
other callback there is no changeset for it to read the tenant off — and the
transaction reason Ash builds does not name one. Resources with a binder therefore
get `AshSqlite.Changes.CarryTenant` added automatically, which copies the tenant
into `context[:data_layer]` where Ash does forward it. Nothing is required of you.

**A transaction cannot span two tenants.** They are separate files on separate
connections, and SQLite cannot commit atomically across databases in WAL mode even
with `ATTACH`. A statement for another tenant inside an open transaction is refused
rather than committing independently and surviving a rollback of everything around
it.

## Migrations

There is no single database to migrate, so `mix ash_sqlite.generate_migrations`
cannot help here in the way it does for one shared database. Applications with a
database per tenant generally version each file themselves — `PRAGMA user_version`
is the usual mechanism — and migrate on activation or at deploy time.
