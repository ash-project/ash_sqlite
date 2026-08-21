# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TenantBinder do
  @moduledoc """
  Chooses the connection a tenanted statement runs on.

  SQLite has no schemas, so `strategy :context` multitenancy cannot be a query
  prefix the way it is in AshPostgres. The generated SQL is identical for every
  tenant and isolation comes entirely from *which database file the connection is
  attached to*. Something has to make that choice, and until now nothing in this
  data layer did: the choice was left to whatever had called
  `c:Ecto.Repo.put_dynamic_repo/1` on the calling process beforehand.

  That works, but it puts the burden in the wrong place. The caller has to bind at
  every entry point and get it right every time, including in the places that have
  no obvious entry point — a `Task`, a load fan-out, a background job. Worse, the
  paths that *cannot* be wrapped from outside are exactly the ones that matter
  most: `Ash.count/2` never enters `Ash.Actions.Read`, and an atomic update never
  materialises a changeset the caller can hook.

  A binder moves the decision to the only place that knows a connection is being
  chosen. Configure one on the resource:

      sqlite do
        repo MyApp.Repo
        tenant_binder MyApp.TenantBinder
      end

  and every statement this data layer issues for a tenanted resource is wrapped in
  `c:bind/3` with that statement's tenant. Reads, aggregates, creates, atomic
  updates, atomic destroys, and bulk operations all go through it, because they all
  go through this data layer.

  ## What the statement is

  The callback also receives the resource and a `:usage` of `:read`, `:write`, or
  `:transaction`. Only the data layer can say which: by the time a binder is looking
  at a statement, the distinction between reading and writing has been compiled away
  into SQL it does not parse.

  It matters because a database-per-tenant layout invites read paths that a
  single-database one does not. A binder may want to answer reads from a cached
  projection published after the last commit, serve them from a replica of the
  tenant's file on another node, or route writes to whichever node currently owns it
  and reads to the nearest one. None of that can be written against a callback that
  cannot tell a `SELECT` from an `UPDATE`.

  Binders that do not care can ignore the argument entirely.

  ## Contract

  `bind/3` receives the tenant, options describing the statement, and a zero-arity
  function, and must return whatever the function returns. Whatever it does to
  select a connection, it must undo:
  these callbacks run on processes it does not own — a Phoenix request process, a
  `Task`, a job worker — and a binding left behind is a statement misdirected
  later.

  It must fail loudly rather than falling through. Returning without having bound
  anything means the statement runs on the default connection, which for a
  database-per-tenant layout is another tenant's data. Raise instead.

  A resource with no `tenant_binder`, or a statement with no tenant, behaves as it
  always has: the connection is whatever the process already has bound.
  """

  @typedoc """
  What the statement being bound is.

    * `:resource` — the resource the statement is for.
    * `:usage` — `:read` for queries and aggregates, `:write` for creates, updates,
      destroys, upserts and their bulk and atomic forms, and `:transaction` for the
      callback that opens one. A `:transaction` may go on to contain either.
  """
  @type opts :: [resource: Ash.Resource.t(), usage: :read | :write | :transaction]

  @doc """
  Runs `fun` with a connection selected for `tenant`, and returns its result.

  Must restore whatever connection the process had before returning, on the error
  path as much as the success path.
  """
  @callback bind(tenant :: term(), opts :: opts(), fun :: (-> result)) :: result
            when result: var
end
