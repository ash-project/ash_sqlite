# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TenantRepo do
  @moduledoc """
  Chooses the repo instance a tenanted statement runs on.

  Under `strategy :context` each tenant has its own database file. The SQL is the
  same for every tenant, and the tenant is applied by choosing the repo instance.
  Set with the `tenant_repo` option, as a function or as a module implementing
  this behaviour.
  """

  @typedoc """
  What the statement is.

    * `:resource` — the resource the statement is for.
    * `:type` — `:read` for queries and aggregates, `:mutate` for writes and for
      the callback that opens a transaction. The same value the `repo` option is
      called with.
  """
  @type context :: %{resource: Ash.Resource.t(), type: :read | :mutate}

  @doc "The repo instance, a pid or a registered name, that `tenant`'s statement runs on."
  @callback repo(tenant :: term(), context :: context(), opts :: Keyword.t()) :: pid() | atom()

  @doc """
  Runs `fun` with the repo instance for `tenant` bound, and returns its result.

  Optional. Without it, the instance from `c:repo/3` is bound with
  `put_dynamic_repo/1` around `fun` and the previous binding is restored after.
  Implement it to do work that has to bracket the statement.
  """
  @callback with_repo(
              tenant :: term(),
              context :: context(),
              opts :: Keyword.t(),
              fun :: (-> result)
            ) :: result
            when result: var

  @optional_callbacks with_repo: 4
end
