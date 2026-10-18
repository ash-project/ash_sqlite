# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy do
  @moduledoc """
  A `c:AshSqlite.Repo.tenant_repo/2` implementation that gives each tenant its own database file.

  Configure the repo with `config :my_app, MyApp.Repo, tenants: [dir: "...", migrations_path: "...", max_children: ...]`
  and implement the callback with `def tenant_repo(tenant, context), do: AshSqlite.MultiTenancy.tenant_repo(__MODULE__, tenant, context)`.
  A tenant's file is opened and migrated on first use.
  """

  alias AshSqlite.MultiTenancy.{Supervisor, Tenant}

  @doc "The repo instance serving `tenant`, opening its database if it is not open."
  @spec tenant_repo(module(), term(), map()) :: pid()
  def tenant_repo(repo, tenant, _context) do
    registry = Supervisor.registry(repo)

    if is_nil(Process.whereis(registry)) do
      raise ArgumentError, """
      #{inspect(repo)} has no tenant supervisor running, so tenant #{inspect(tenant)} \
      has no database to open. Configure the `tenants:` key and start the repo:

          config :my_app, #{inspect(repo)}, tenants: [dir: "priv/tenants"]
      """
    end

    pid =
      case Registry.lookup(registry, tenant) do
        [{pid, _}] -> pid
        [] -> start_tenant(repo, tenant)
      end

    Tenant.instance(pid, tenant)
  end

  defp start_tenant(repo, tenant) do
    case DynamicSupervisor.start_child(Supervisor.tenants(repo), {Tenant, {repo, tenant}}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      {:error, reason} -> raise "could not start tenant #{inspect(tenant)}: #{inspect(reason)}"
    end
  end
end
