# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.ConnectionSupervisor do
  @moduledoc """
  Supervises the connection processes of one repo's tenants.
  """

  @doc false
  def child_spec(repo) do
    %{id: {__MODULE__, repo}, start: {__MODULE__, :start_link, [repo]}, type: :supervisor}
  end

  @doc false
  def start_link(repo) do
    DynamicSupervisor.start_link(strategy: :one_for_one, name: name(repo))
  end

  @doc "The supervisor serving `repo`."
  @spec name(module()) :: module()
  def name(repo), do: Module.concat(repo, TenantConnectionSupervisor)

  @doc "Starts a connection, or reports the one already serving that tenant."
  @spec start_connection(module(), keyword()) ::
          {:ok, pid()} | {:error, {:already_started, pid()}} | {:error, term()}
  def start_connection(repo, opts) do
    DynamicSupervisor.start_child(name(repo), {AshSqlite.MultiTenancy.Connection, opts})
  end

  @doc "Stops a connection, letting it close its database cleanly."
  @spec stop_connection(module(), pid()) :: :ok | {:error, :not_found}
  def stop_connection(repo, connection) do
    DynamicSupervisor.terminate_child(name(repo), connection)
  end
end
