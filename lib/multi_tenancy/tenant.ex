# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Tenant do
  @moduledoc """
  The process that owns one tenant's database: it opens and migrates the file, and its repo instance lives and dies with it.
  """
  use GenServer, restart: :temporary, shutdown: 30_000

  def start_link({repo, tenant, path}) do
    GenServer.start_link(__MODULE__, {repo, tenant, path},
      name: {:via, Registry, {AshSqlite.MultiTenancy.Supervisor.registry(repo), tenant}}
    )
  end

  @doc """
  The repo instance of the tenant process `pid`, waiting up to `timeout` for its database to open.

  `:stopped` means the process has exited.
  """
  @spec instance(pid(), timeout()) ::
          {:ok, pid()} | :stopped | {:timeout, pid()} | {:error, term()}
  def instance(pid, timeout) do
    {:ok, GenServer.call(pid, :instance, timeout)}
  catch
    :exit, {reason, {GenServer, :call, _}}
    when reason in [:noproc, :normal, :shutdown, :killed] ->
      :stopped

    :exit, {{:shutdown, _}, {GenServer, :call, _}} ->
      :stopped

    :exit, {:timeout, {GenServer, :call, _}} ->
      {:timeout, pid}

    :exit, reason ->
      {:error, reason}
  end

  @impl true
  # `DynamicSupervisor.start_child/2` runs `init/1` inside the supervisor, so opening
  # here would queue every tenant behind every other tenant's open.
  def init({repo, tenant, path}) do
    # Trapped so `terminate/2` can stop the instance before this process leaves the
    # Registry; otherwise a successor could open the file while the old pool still holds it.
    Process.flag(:trap_exit, true)
    {:ok, %{repo: repo, tenant: tenant, path: path, instance: nil}, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    registry = AshSqlite.MultiTenancy.Supervisor.registry(state.repo)
    {:ok, migrations} = Registry.meta(registry, :migrations)
    File.mkdir_p!(Path.dirname(state.path))

    {:ok, instance} = state.repo.start_link(name: nil, database: state.path, tenant: state.tenant)
    state = %{state | instance: instance}

    Ecto.Migrator.run(state.repo, migrations, :up, all: true, dynamic_repo: instance, log: false)
    Ecto.Adapters.SQL.query!(instance, "SELECT 1", [])

    {:noreply, state}
  end

  @impl true
  def handle_call(:instance, _from, state), do: {:reply, state.instance, state}

  @impl true
  def handle_info({:EXIT, instance, reason}, %{instance: instance} = state) do
    {:stop, reason, %{state | instance: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{instance: instance}) when is_pid(instance) do
    Supervisor.stop(instance, :shutdown)
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
