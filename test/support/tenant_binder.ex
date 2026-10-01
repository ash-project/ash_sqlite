# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.Test.TenantBinder do
  @moduledoc """
  A binder that maps tenants to repo instances registered by the test.
  """
  @behaviour AshSqlite.TenantBinder

  @doc "Registers the repo instance serving `tenant`."
  def register(tenant, pid), do: Process.put({__MODULE__, :repo, tenant}, pid)

  @doc "The repo instance registered for `tenant`, or nil."
  def repo_for(tenant), do: Process.get({__MODULE__, :repo, tenant})

  @doc "Every `{tenant, usage}` this binder has been asked for, oldest first."
  def calls, do: Enum.reverse(Process.get({__MODULE__, :calls}, []))

  @doc "Forgets what has been recorded, leaving registrations in place."
  def reset_calls, do: Process.delete({__MODULE__, :calls})

  @impl true
  def bind(tenant, opts, fun) do
    Process.put({__MODULE__, :calls}, [
      {tenant, opts[:usage]} | Process.get({__MODULE__, :calls}, [])
    ])

    pid =
      Process.get({__MODULE__, :repo, tenant}) ||
        raise ArgumentError, "no repo registered for tenant #{inspect(tenant)}"

    previous = AshSqlite.TenantRepo.get_dynamic_repo()
    AshSqlite.TenantRepo.put_dynamic_repo(pid)

    try do
      fun.()
    after
      AshSqlite.TenantRepo.put_dynamic_repo(previous)
    end
  end
end
