# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Connection do
  @moduledoc """
  One tenant's database, owned by one process for as long as the tenant is resident.
  """
  use GenServer, restart: :temporary

  require Logger

  alias AshSqlite.MultiTenancy.Registry, as: TenantRegistry

  defstruct [:tenant, :repo, :repo_pid, :path, :schema_version, :opened_at]

  @doc "Starts a connection for a tenant."
  def start_link(opts) do
    repo = Keyword.fetch!(opts, :repo)
    tenant = Keyword.fetch!(opts, :tenant)

    GenServer.start_link(__MODULE__, opts, name: TenantRegistry.via(repo, tenant))
  end

  @doc "The repo instance pid for this tenant."
  def repo_pid(connection), do: GenServer.call(connection, :repo_pid)

  @doc "What this connection is serving, for the fleet view."
  def info(connection), do: GenServer.call(connection, :info)

  @doc "Stops the repo instance while leaving this process alive."
  def stop_repo(connection), do: GenServer.call(connection, :stop_repo)

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    tenant = Keyword.fetch!(opts, :tenant)
    path = Keyword.fetch!(opts, :path)
    key = Keyword.get(opts, :key)

    # The registry value is a repo pid, so this process must not outlive its repo.
    Process.flag(:trap_exit, true)
    File.mkdir_p!(Path.dirname(path))

    migrations_path = Keyword.get(opts, :migrations_path)

    with :ok <- verify_key(key, Keyword.get(opts, :encrypted?, false)),
         :ok <- verify_migrations_path(migrations_path),
         {:ok, repo_pid} <- start_repo(repo, path, key, Keyword.get(opts, :repo_opts, [])),
         {:ok, version} <- migrate(repo, repo_pid, tenant, migrations_path) do
      :ok = TenantRegistry.publish(repo, tenant, repo_pid)

      {:ok,
       %__MODULE__{
         tenant: tenant,
         repo: repo,
         repo_pid: repo_pid,
         path: path,
         schema_version: version,
         opened_at: System.monotonic_time(:millisecond)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:repo_pid, _from, state), do: {:reply, state.repo_pid, state}

  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:tenant, :path, :schema_version, :opened_at]), state}
  end

  def handle_call(:stop_repo, _from, state) do
    stop_repo_instance(state.repo_pid)

    # Cleared so that a second call, and `terminate/2`, are no-ops rather than a
    # stop against a pid that is already gone.
    {:reply, :ok, %{state | repo_pid: nil}}
  end

  @impl true
  def handle_info({:EXIT, repo_pid, reason}, %{repo_pid: repo_pid} = state) do
    {:stop, {:repo_exited, reason}, %{state | repo_pid: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_repo_instance(state.repo_pid)

  defp start_repo(repo, path, key, extra) do
    opts =
      extra
      # backoff_type: :stop — a wrong key or a corrupt file is not transient, and
      # retrying turns a clear failure into a hang.
      |> Keyword.merge(name: nil, database: path, backoff_type: :stop)
      # One writer per file is all SQLite offers; at one, contention waits in the
      # pool rather than reaching SQLite's write lock, which fails instead of waiting.
      |> Keyword.put(:pool_size, 1)
      |> maybe_put_key(key)

    case repo.start_link(opts) do
      {:ok, repo_pid} -> {:ok, repo_pid}
      {:error, {:already_started, repo_pid}} -> {:ok, repo_pid}
      {:error, reason} -> {:error, {:cannot_open_database, reason}}
    end
  end

  defp maybe_put_key(opts, nil), do: opts
  defp maybe_put_key(opts, key), do: Keyword.put(opts, :key, key)

  # SQLite will create a *plaintext* database for a tenant whose key is missing.
  defp verify_key(nil, true), do: {:error, :no_key}
  defp verify_key(_key, _encrypted?), do: :ok

  # `Ecto.Migrator` treats a missing directory as one with no migrations, which would
  # leave every tenant empty and surface as `no such table` far from the cause.
  defp verify_migrations_path(nil), do: :ok

  defp verify_migrations_path(path) do
    if File.dir?(path), do: :ok, else: {:error, {:missing_migrations_path, path}}
  end

  defp migrate(_repo, _repo_pid, _tenant, nil), do: {:ok, nil}

  defp migrate(repo, repo_pid, tenant, migrations_path) do
    opts = [
      dynamic_repo: repo_pid,
      # Registration already reduced this to one process per file, and with a pool of
      # one there is no second connection for Ecto's lock to take.
      migration_lock: false,
      log: false,
      log_migrations_sql: false
    ]

    source = AshSqlite.MultiTenancy.Migrations.load!(migrations_path)
    statuses = Ecto.Migrator.migrations(repo, source, opts)

    # Only run the migrator when something is pending: the common case is an
    # up-to-date tenant being activated.
    if Enum.any?(statuses, &match?({:down, _, _}, &1)) do
      Ecto.Migrator.run(repo, source, :up, Keyword.put(opts, :all, true))
    end

    {:ok, current_version(statuses)}
  rescue
    exception ->
      Logger.error("""
      migrating tenant #{inspect(tenant)} raised #{inspect(exception.__struct__)}: \
      #{Exception.message(exception)}
      """)

      {:error, {:migration_failed, exception.__struct__}}
  end

  # Every version in the directory, because anything pending has just been run.
  defp current_version([]), do: nil
  defp current_version(statuses), do: statuses |> Enum.map(&elem(&1, 1)) |> Enum.max()

  defp stop_repo_instance(nil), do: :ok

  defp stop_repo_instance(repo_pid) do
    if Process.alive?(repo_pid) do
      # A clean stop closes the connection, which checkpoints the WAL back into the
      # database. A kill leaves it to be replayed by whoever opens the file next.
      Supervisor.stop(repo_pid)
    end

    :ok
  catch
    # The repo is already going down, which is the state we wanted.
    :exit, _ -> :ok
  end
end
