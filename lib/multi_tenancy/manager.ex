# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Manager do
  @moduledoc """
  Activates tenants, bounds how many stay resident, and quarantines the ones that cannot start.
  """
  use GenServer

  require Logger

  alias AshSqlite.MultiTenancy.Binds
  alias AshSqlite.MultiTenancy.ConnectionSupervisor
  alias AshSqlite.MultiTenancy.Database
  alias AshSqlite.MultiTenancy.Registry, as: TenantRegistry

  @default_max_resident 256

  defstruct [
    :repo,
    :dir,
    :key_for,
    :migrations_path,
    :max_resident,
    :repo_opts,
    quarantined: %{},
    sealed?: false
  ]

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :repo)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name(Keyword.fetch!(opts, :repo)))
  end

  @doc "The manager serving `repo`."
  @spec name(module()) :: module()
  def name(repo), do: Module.concat(repo, TenantManager)

  @doc "Returns the repo instance serving `tenant`, starting it if it is not resident."
  @spec activate(module(), String.t()) :: {:ok, pid()} | {:error, term()}
  def activate(repo, tenant), do: activate(repo, tenant, 50)

  defp activate(repo, tenant, attempts_left) do
    case GenServer.call(name(repo), {:activate, tenant}, 30_000) do
      {:error, :connection_died} -> retry_activate(repo, tenant, attempts_left)
      other -> other
    end
  end

  # A registration is released when the registry handles the connection's DOWN, so a
  # tenant whose connection just died is briefly impossible to start. Yield and retry.
  defp retry_activate(_repo, _tenant, 0), do: {:error, :connection_died}

  defp retry_activate(repo, tenant, attempts_left) do
    Process.sleep(1)
    activate(repo, tenant, attempts_left - 1)
  end

  @doc """
  Closes a tenant's database, leaving the file on disk.

  Waits up to `:grace_ms` for statements in flight to finish, and reports
  `{:error, :busy}` if they do not. Closing anyway would pull the connection out
  from under them -- and for `rename/3`, move the file too -- so the caller is told
  rather than left to find out. `force: true` closes regardless, which is what
  eviction and `delete/2` want once they know nothing is bound.
  """
  @spec close(module(), String.t(), keyword()) :: :ok | {:error, :busy}
  def close(repo, tenant, opts \\ []) do
    # A caller that had already marked the tenant closing wants it to stay that way
    # afterwards -- `rename/3` holds the mark across the close *and* the file move.
    held_open_by_caller? = Binds.closing?(repo, tenant)
    force? = Keyword.get(opts, :force, false)
    Binds.begin_closing(repo, tenant)

    try do
      if force? or quiesced?(repo, tenant, Keyword.get(opts, :grace_ms, 1_000)) do
        case TenantRegistry.lookup(repo, tenant) do
          {:ok, connection, _repo_pid} -> ConnectionSupervisor.stop_connection(repo, connection)
          :error -> :ok
        end

        Binds.forget(repo, tenant)
        :ok
      else
        {:error, :busy}
      end
    after
      unless held_open_by_caller?, do: Binds.end_closing(repo, tenant)
    end
  end

  @doc """
  Closes a tenant and deletes its database, including the WAL sidecars.

  The tenant is held closed across the close *and* the unlink, as in `rename/3`. A
  request arriving in between would otherwise reopen the database and go on serving
  it from the unlinked inode, accepting writes that are discarded when the
  connection finally closes.
  """
  @spec delete(module(), String.t()) :: {:ok, [Path.t()]}
  def delete(repo, tenant) do
    Binds.begin_closing(repo, tenant)

    try do
      close(repo, tenant, force: true)
      GenServer.call(name(repo), {:delete, tenant})
    after
      Binds.end_closing(repo, tenant)
    end
  end

  @doc """
  Moves a tenant's database to another tenant's name, sidecars included.

  A tenant here is a file, so a tenant renamed without this keeps none of its data:
  the new name addresses a database that does not exist, and the next request
  creates an empty one. Both names are held closed for the move, so nothing reopens
  the file being moved or creates a database at the destination while it happens.

  Refuses rather than overwrites when the destination already has a database.
  """
  @spec rename(module(), String.t(), String.t()) ::
          :ok | {:error, :busy | :no_database | :target_exists | File.posix()}
  def rename(_repo, tenant, tenant), do: :ok

  def rename(repo, from, to) do
    Binds.begin_closing(repo, from)
    Binds.begin_closing(repo, to)

    try do
      # Not moved while something is still reading or writing it: the statement in
      # flight would keep the old inode and commit into the destination's database.
      with :ok <- close(repo, from) do
        GenServer.call(name(repo), {:rename, from, to})
      end
    after
      Binds.end_closing(repo, from)
      Binds.end_closing(repo, to)
    end
  end

  @doc "Stops the node taking on new tenants. The first step of a drain."
  @spec seal(module()) :: :ok
  def seal(repo), do: GenServer.call(name(repo), :seal)

  @doc "Lets the node accept tenants again."
  @spec unseal(module()) :: :ok
  def unseal(repo), do: GenServer.call(name(repo), :unseal)

  @doc "Whether the node is refusing new tenants."
  @spec sealed?(module()) :: boolean()
  def sealed?(repo), do: GenServer.call(name(repo), :sealed?)

  @doc "Tenants that failed to activate, with the reason."
  @spec quarantined(module()) :: %{String.t() => term()}
  def quarantined(repo), do: GenServer.call(name(repo), :quarantined)

  @doc "Clears a tenant's quarantine, so the next request tries again."
  @spec release(module(), String.t()) :: :ok
  def release(repo, tenant), do: GenServer.call(name(repo), {:release, tenant})

  @doc "The fleet configuration."
  @spec config(module()) :: map()
  def config(repo), do: GenServer.call(name(repo), :config)

  @doc "Where `tenant`'s database is, whether or not it exists yet."
  @spec path_for(module(), String.t()) :: Path.t()
  def path_for(repo, tenant), do: GenServer.call(name(repo), {:path_for, tenant})

  @doc """
  Every tenant this node knows of: one with a database in the fleet's directory,
  or one currently resident.

  Derived rather than asked of the application, unlike AshPostgres'
  `all_tenants/0`, because a tenant here *is* a file. Residents are included
  because SQLite creates the file on the first write, so a tenant activated a
  moment ago may not have one yet. A tenant that has never been activated is
  absent, which is also why it needs no migrating -- it is migrated when it is
  first opened.
  """
  @spec all_tenants(module()) :: [String.t()]
  def all_tenants(repo) do
    on_disk = repo |> config() |> Map.fetch!(:dir) |> Database.list()

    Enum.uniq(on_disk ++ TenantRegistry.resident(repo))
  end

  @doc "Activates each tenant in turn, migrating it, and reports what happened."
  @spec migrate_all(module(), [String.t()] | :all, keyword()) ::
          [{String.t(), {:ok, term()} | {:error, term()}}]
  def migrate_all(repo, tenants \\ :all, opts \\ [])

  def migrate_all(repo, :all, opts), do: migrate_all(repo, all_tenants(repo), opts)

  def migrate_all(repo, tenants, opts) do
    close_after? = Keyword.get(opts, :close_after?, true)

    Enum.map(tenants, fn tenant ->
      result =
        with {:ok, _repo_pid} <- activate(repo, tenant),
             {:ok, connection, _} <- TenantRegistry.lookup(repo, tenant) do
          version = AshSqlite.MultiTenancy.Connection.info(connection).schema_version

          # `close_after?` frees residency, it is not part of migrating. A tenant
          # serving traffic stays open rather than turning a migrated tenant into a
          # reported failure.
          if close_after?, do: close(repo, tenant, Keyword.take(opts, [:grace_ms]))

          {:ok, version}
        else
          :error -> {:error, :connection_died}
          {:error, reason} -> {:error, reason}
        end

      {tenant, result}
    end)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      dir: Keyword.fetch!(opts, :dir),
      key_for: Keyword.get(opts, :key_for),
      migrations_path: Keyword.get(opts, :migrations_path),
      max_resident: Keyword.get(opts, :max_resident, @default_max_resident),
      repo_opts: Keyword.get(opts, :repo_opts, [])
    }

    File.mkdir_p!(state.dir)
    {:ok, state}
  end

  @impl true
  def handle_call({:activate, _tenant}, _from, %{sealed?: true} = state) do
    {:reply, {:error, :draining}, state}
  end

  def handle_call({:activate, tenant}, _from, state)
      when is_map_key(state.quarantined, tenant) do
    {:reply, {:error, {:quarantined, state.quarantined[tenant]}}, state}
  end

  def handle_call({:activate, tenant}, _from, state) do
    case TenantRegistry.lookup(state.repo, tenant) do
      {:ok, connection, repo_pid} ->
        {:reply, {:ok, repo_pid || AshSqlite.MultiTenancy.Connection.repo_pid(connection)}, state}

      :error ->
        state = evict_if_needed(state)
        result = start(state, tenant)
        {:reply, result, quarantine_on_failure(state, tenant, result)}
    end
  end

  def handle_call({:delete, tenant}, _from, state) do
    base = Database.path(state.dir, tenant)

    # Closing checkpoints and may remove the sidecars itself, so existence is not
    # stable between a check and a removal. Attempt each and report what went.
    removed = for path <- Database.sidecars(base), File.rm(path) == :ok, do: path

    {:reply, {:ok, removed}, state}
  end

  def handle_call({:rename, from, to}, _from, state) do
    source = Database.path(state.dir, from)
    target = Database.path(state.dir, to)

    cond do
      not File.exists?(source) ->
        {:reply, {:error, :no_database}, state}

      File.exists?(target) ->
        {:reply, {:error, :target_exists}, state}

      true ->
        {:reply, move(source, target),
         %{state | quarantined: Map.delete(state.quarantined, from)}}
    end
  end

  def handle_call(:seal, _from, state), do: {:reply, :ok, %{state | sealed?: true}}
  def handle_call(:unseal, _from, state), do: {:reply, :ok, %{state | sealed?: false}}
  def handle_call(:sealed?, _from, state), do: {:reply, state.sealed?, state}
  def handle_call(:quarantined, _from, state), do: {:reply, state.quarantined, state}

  def handle_call({:release, tenant}, _from, state) do
    {:reply, :ok, %{state | quarantined: Map.delete(state.quarantined, tenant)}}
  end

  def handle_call(:config, _from, state) do
    {:reply, Map.take(state, [:repo, :dir, :migrations_path, :max_resident]), state}
  end

  def handle_call({:path_for, tenant}, _from, state) do
    {:reply, Database.path(state.dir, tenant), state}
  end

  defp start(state, tenant) do
    opts = [
      repo: state.repo,
      tenant: tenant,
      path: Database.path(state.dir, tenant),
      key: key_for(state, tenant),
      # `encrypted?` tells the connection "this fleet uses keys", so that a tenant
      # whose key is missing fails instead of quietly opening a plaintext database.
      encrypted?: not is_nil(state.key_for),
      migrations_path: state.migrations_path,
      repo_opts: state.repo_opts
    ]

    case ConnectionSupervisor.start_connection(state.repo, opts) do
      {:ok, connection} -> published(state, tenant, connection)
      {:error, {:already_started, connection}} -> published(state, tenant, connection)
      {:error, reason} -> {:error, reason}
    end
  end

  defp published(state, tenant, connection) do
    if Process.alive?(connection) do
      # Marked used at activation, or a tenant that is about to be queried would
      # have no timestamp and sort first for eviction.
      Binds.touch(state.repo, tenant)

      case TenantRegistry.lookup(state.repo, tenant) do
        {:ok, _connection, repo_pid} when is_pid(repo_pid) -> {:ok, repo_pid}
        _ -> {:error, :connection_died}
      end
    else
      {:error, :connection_died}
    end
  end

  defp quarantine_on_failure(state, tenant, {:error, reason})
       when reason not in [:connection_died] do
    %{state | quarantined: Map.put(state.quarantined, tenant, reason)}
  end

  defp quarantine_on_failure(state, _tenant, _result), do: state

  defp key_for(%{key_for: nil}, _tenant), do: nil
  defp key_for(%{key_for: fun}, tenant), do: fun.(tenant)

  defp evict_if_needed(state) do
    if TenantRegistry.count(state.repo) >= state.max_resident do
      case Binds.least_recently_used(state.repo, TenantRegistry.resident(state.repo)) do
        nil ->
          Logger.warning("""
          #{inspect(state.repo)} holds #{TenantRegistry.count(state.repo)} tenant \
          databases, at or above max_resident of #{state.max_resident}, and every \
          one of them is in use. Exceeding the limit rather than refusing the \
          tenant that is arriving.
          """)

        tenant ->
          evict(state.repo, tenant)
      end
    end

    state
  end

  # The candidate was chosen because nothing was bound to it, which was true when it
  # was chosen. Marking it closing *before* re-reading the count is what makes it
  # still true: `Binds.bound/2` publishes its increment before reading the mark, so
  # after the mark is set a count of zero means no bind can still arrive. A bind that
  # got in first is left alone and the limit is exceeded instead.
  defp evict(repo, tenant) do
    Binds.begin_closing(repo, tenant)

    try do
      if Binds.count(repo, tenant) == 0 do
        close(repo, tenant, force: true)
      else
        :ok
      end
    after
      Binds.end_closing(repo, tenant)
    end
  end

  # The sidecars only exist between a write and a checkpoint, but when they do they
  # hold committed data the database file does not -- so a move that left them
  # behind would lose the most recent writes.
  defp move(source, target) do
    with :ok <- File.rename(source, target) do
      for {sidecar, renamed} <- Enum.zip(Database.sidecars(source), Database.sidecars(target)),
          sidecar != source,
          File.exists?(sidecar) do
        File.rename(sidecar, renamed)
      end

      :ok
    end
  end

  # A deadline rather than a loop count: `Process.sleep(1)` sleeps *at least* a
  # millisecond, so counting iterations made `grace_ms` mean something between one
  # and several times what it said, depending on how loaded the scheduler was.
  defp quiesced?(repo, tenant, grace_ms) do
    await_quiescence(repo, tenant, System.monotonic_time(:millisecond) + grace_ms)
  end

  defp await_quiescence(repo, tenant, deadline) do
    cond do
      Binds.count(repo, tenant) == 0 -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(1) && await_quiescence(repo, tenant, deadline)
    end
  end
end
