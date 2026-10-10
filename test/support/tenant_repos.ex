# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.TenantRepos do
  @moduledoc """
  Maps tenants to repo instances registered by the test.
  """

  @doc "Registers the repo instance serving `tenant`."
  def register(tenant, pid), do: Process.put({__MODULE__, :repo, tenant}, pid)

  @doc "Every `{tenant, type}` a repo has been asked for, oldest first."
  def calls, do: Enum.reverse(Process.get({__MODULE__, :calls}, []))

  @doc "Forgets what has been recorded, leaving registrations in place."
  def reset_calls, do: Process.delete({__MODULE__, :calls})

  @doc "The repo instance registered for `tenant`."
  def repo(tenant, %{type: type}) do
    Process.put({__MODULE__, :calls}, [{tenant, type} | Process.get({__MODULE__, :calls}, [])])

    Process.get({__MODULE__, :repo, tenant}) ||
      raise ArgumentError, "no repo registered for tenant #{inspect(tenant)}"
  end
end
