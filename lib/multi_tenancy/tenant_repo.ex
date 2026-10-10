# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.TenantRepo do
  @moduledoc """
  Implements `AshSqlite.TenantRepo` in terms of `AshSqlite.MultiTenancy`. The default for `strategy :context`.
  """

  @behaviour AshSqlite.TenantRepo

  @impl true
  def repo(tenant, %{resource: resource}, _opts) do
    repo = AshSqlite.DataLayer.Info.repo(resource, :mutate)

    case AshSqlite.MultiTenancy.connection_for(repo, tenant) do
      {:ok, repo_pid} ->
        repo_pid

      {:error, reason} ->
        raise AshSqlite.MultiTenancy.UnavailableError, tenant: tenant, reason: reason
    end
  end

  # Implemented so the tenant is held open for the statement, which `repo/3` alone
  # cannot do.
  @impl true
  def with_repo(tenant, %{resource: resource}, _opts, fun) do
    repo = AshSqlite.DataLayer.Info.repo(resource, :mutate)
    AshSqlite.MultiTenancy.with_tenant(repo, tenant, fun)
  end
end
