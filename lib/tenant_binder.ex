# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TenantBinder do
  @moduledoc """
  Chooses the connection a tenanted statement runs on.

  SQLite has no schemas, so `strategy :context` cannot be a query prefix: the SQL is
  identical for every tenant and isolation comes from which file the connection is
  attached to. Defaults to `AshSqlite.MultiTenancy.Binder`; name your own to replace it.
  """

  @typedoc """
  What the statement being bound is.

    * `:resource` — the resource the statement is for.
    * `:usage` — `:read` for queries and aggregates, `:write` for creates, updates,
      destroys, upserts and their bulk and atomic forms, and `:transaction` for the
      callback that opens one. A `:transaction` may go on to contain either.
  """
  @type opts :: [resource: Ash.Resource.t(), usage: :read | :write | :transaction]

  @doc "Runs `fun` with a connection selected for `tenant`, and returns its result."
  @callback bind(tenant :: term(), opts :: opts(), fun :: (-> result)) :: result
            when result: var
end
