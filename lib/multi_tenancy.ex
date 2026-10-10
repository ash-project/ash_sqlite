# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy do
  @moduledoc """
  One SQLite database per tenant: choosing the file, opening it, migrating it, and closing it again.
  """
  use Supervisor

  alias AshSqlite.MultiTenancy.Binds
  alias AshSqlite.MultiTenancy.Connection
  alias AshSqlite.MultiTenancy.Manager
  alias AshSqlite.MultiTenancy.Registry, as: TenantRegistry

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :repo)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    repo = Keyword.fetch!(opts, :repo)
    Supervisor.start_link(__MODULE__, opts, name: Module.concat(repo, MultiTenancy))
  end

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    _dir = Keyword.fetch!(opts, :dir)
    verify_migrations_path!(Keyword.get(opts, :migrations_path))

    children = [
      TenantRegistry.child_spec(repo),
      Binds.child_spec(repo),
      AshSqlite.MultiTenancy.ConnectionSupervisor.child_spec(repo),
      Manager.child_spec(opts)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The repo instance serving `tenant`, starting it if it is not resident."
  @spec connection_for(module(), String.t()) :: {:ok, pid()} | {:error, term()}
  def connection_for(repo, tenant) do
    case TenantRegistry.lookup(repo, tenant) do
      {:ok, _connection, repo_pid} when is_pid(repo_pid) ->
        {:ok, repo_pid}

      # Registered, but its `init/1` has not published a repo yet, so this caller
      # raced the activation. Asking the connection directly waits for it.
      {:ok, connection, nil} ->
        case Connection.repo_pid(connection) do
          repo_pid when is_pid(repo_pid) -> {:ok, repo_pid}
          _ -> Manager.activate(repo, tenant)
        end

      :error ->
        Manager.activate(repo, tenant)
    end
  end

  @doc "Runs `fun` with `tenant`'s database bound to the calling process."
  @spec with_tenant(module(), String.t(), (-> result)) :: result when result: var
  def with_tenant(repo, tenant, fun) when is_function(fun, 0) do
    case connection_for(repo, tenant) do
      {:ok, repo_pid} ->
        bound(repo, tenant, repo_pid, fun)

      # Raising, not returning: an unbound statement here would run against whichever
      # database the process already had, which is another tenant's data.
      {:error, reason} ->
        raise AshSqlite.MultiTenancy.UnavailableError, tenant: tenant, reason: reason
    end
  end

  defp bound(repo, tenant, repo_pid, fun) do
    case Binds.bound(repo, tenant) do
      :ok ->
        previous = repo.put_dynamic_repo(repo_pid)

        try do
          fun.()
        after
          repo.put_dynamic_repo(previous)
          Binds.released(repo, tenant)
        end

      # Being closed, so wait for it to land and bind whatever replaces it.
      :closing ->
        Process.sleep(1)
        with_tenant(repo, tenant, fun)
    end
  end

  @doc "Closes a tenant's database, leaving the file on disk."
  defdelegate close(repo, tenant, opts \\ []), to: Manager

  @doc "Closes a tenant's database and deletes it, WAL sidecars included."
  defdelegate delete(repo, tenant), to: Manager

  @doc "Moves a tenant's database to another tenant's name, sidecars included."
  defdelegate rename(repo, from, to), to: Manager

  @doc "Tenants holding an open connection right now."
  @spec resident(module()) :: [String.t()]
  defdelegate resident(repo), to: TenantRegistry

  @doc "Every tenant with a database on disk, plus any that are resident."
  defdelegate all_tenants(repo), to: Manager

  @doc "Tenants that failed to activate, with the reason."
  defdelegate quarantined(repo), to: Manager

  @doc "Clears a tenant's quarantine, so the next request tries again."
  defdelegate release(repo, tenant), to: Manager

  @doc "Stops this node taking on new tenants."
  defdelegate seal(repo), to: Manager

  @doc "Lets this node accept tenants again."
  defdelegate unseal(repo), to: Manager

  @doc "Activates and migrates each tenant in turn, reporting what happened."
  defdelegate migrate_all(repo, tenants \\ :all, opts \\ []), to: Manager

  @doc "Where a tenant's database is, whether or not it exists yet."
  defdelegate path_for(repo, tenant), to: Manager

  @doc "The fleet configuration."
  defdelegate config(repo), to: Manager

  # Checked at boot rather than at activation: a typo would otherwise surface in
  # production as `no such table`, at whatever hour the first tenant woke up.
  defp verify_migrations_path!(nil), do: :ok

  defp verify_migrations_path!(path) do
    if File.dir?(path) do
      :ok
    else
      raise ArgumentError, """
      :migrations_path #{inspect(path)} is not a directory.

      Tenant databases are migrated from it, and `Ecto.Migrator` treats a missing \
      directory as one containing no migrations -- so every tenant would open an \
      empty database and fail on its first query instead of here.
      """
    end
  end
end
