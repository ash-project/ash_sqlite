# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Registry do
  @moduledoc """
  Maps a tenant to the process holding its connection, and to that connection's repo instance.
  """

  @doc false
  def child_spec(repo) do
    %{id: {__MODULE__, repo}, start: {__MODULE__, :start_link, [repo]}, type: :supervisor}
  end

  @doc false
  def start_link(repo) do
    Registry.start_link(
      keys: :unique,
      name: name(repo),
      # Every tenanted statement takes a lookup, so reads are the hot path.
      # Every tenanted statement does a lookup, so reads are the hot path and the
      # partitions are what keep them off one ETS table.
      partitions: System.schedulers_online()
    )
  end

  @doc "The registry serving `repo`."
  @spec name(module()) :: module()
  def name(repo), do: Module.concat(repo, TenantRegistry)

  @doc "The name to start a tenant's connection process under."
  @spec via(module(), String.t()) :: {:via, module(), {module(), String.t(), nil}}
  def via(repo, tenant), do: {:via, Registry, {name(repo), tenant, nil}}

  @doc "Publishes the repo instance pid for `tenant`."
  @spec publish(module(), String.t(), pid()) :: :ok
  def publish(repo, tenant, repo_pid) do
    Registry.update_value(name(repo), tenant, fn _ -> repo_pid end)
    :ok
  end

  @doc "The connection process and repo instance serving `tenant`."
  @spec lookup(module(), String.t()) :: {:ok, pid(), pid() | nil} | :error
  def lookup(repo, tenant) do
    case Registry.lookup(name(repo), tenant) do
      # An entry outlives its process until the partition handles the DOWN, so a
      # hit is not proof of life and a dead pid must read as absent.
      [{connection, repo_pid}] ->
        if Process.alive?(connection), do: {:ok, connection, repo_pid}, else: :error

      [] ->
        :error
    end
  end

  @doc "Tenants with a connection open on this node right now."
  @spec resident(module()) :: [String.t()]
  def resident(repo) do
    Registry.select(name(repo), [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "How many tenants are resident."
  @spec count(module()) :: non_neg_integer()
  def count(repo), do: Registry.count(name(repo))
end
