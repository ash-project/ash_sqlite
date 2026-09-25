# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.CustomAggregate do
  @moduledoc """
  A custom aggregate implementation for Ecto queries against SQLite.
  """

  @doc """
  The dynamic expression to create the aggregate.

  The binding refers to the resource being aggregated. Use `as(^binding)` to
  reference it.

  For example:

      Ecto.Query.dynamic(
        [],
        fragment("group_concat(?, ?)", field(as(^binding), ^opts[:field]), ^opts[:delimiter])
      )
  """
  @callback dynamic(opts :: Keyword.t(), binding :: integer) :: Ecto.Query.dynamic_expr()

  defmacro __using__(_) do
    quote do
      @behaviour AshSqlite.CustomAggregate
    end
  end
end
