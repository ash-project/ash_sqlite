# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.BracketingTenantRepo do
  @moduledoc """
  A tenant repo that binds the instance itself, and records entering and leaving.
  """
  @behaviour AshSqlite.TenantRepo

  @doc "Every `:entered` and `:left`, oldest first."
  def events, do: Enum.reverse(Process.get({__MODULE__, :events}, []))

  @doc "Forgets what has been recorded."
  def reset_events, do: Process.delete({__MODULE__, :events})

  @impl true
  def repo(tenant, context, _opts), do: AshSqlite.Test.TenantRepos.repo(tenant, context)

  @impl true
  def with_repo(tenant, context, opts, fun) do
    record(:entered)
    previous = AshSqlite.TenantTestRepo.put_dynamic_repo(repo(tenant, context, opts))

    try do
      fun.()
    after
      AshSqlite.TenantTestRepo.put_dynamic_repo(previous)
      record(:left)
    end
  end

  defp record(event) do
    Process.put({__MODULE__, :events}, [event | Process.get({__MODULE__, :events}, [])])
  end
end
