# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Binds do
  @moduledoc """
  Counts who is using each tenant, so that closing one can be safe.
  """
  use GenServer

  @doc false
  def child_spec(repo) do
    %{id: {__MODULE__, repo}, start: {__MODULE__, :start_link, [repo]}}
  end

  @doc false
  def start_link(repo), do: GenServer.start_link(__MODULE__, repo, name: name(repo))

  @doc "The table serving `repo`."
  @spec name(module()) :: module()
  def name(repo), do: Module.concat(repo, TenantBinds)

  @doc "Records that the calling process has bound `tenant`."
  @spec bound(module(), String.t()) :: :ok | :closing
  def bound(repo, tenant) do
    if closing?(repo, tenant) do
      :closing
    else
      :ets.update_counter(name(repo), {:binds, tenant}, {2, 1}, {{:binds, tenant}, 0})
      :ok
    end
  end

  @doc "Records that the calling process has released `tenant`, and marks it used."
  @spec released(module(), String.t()) :: :ok
  def released(repo, tenant) do
    # Clamped at zero: an unmatched release would make a busy tenant look evictable.
    :ets.update_counter(name(repo), {:binds, tenant}, {2, -1, 0, 0}, {{:binds, tenant}, 0})
    touch(repo, tenant)
  end

  @doc "How many processes are bound to `tenant`."
  @spec count(module(), String.t()) :: non_neg_integer()
  def count(repo, tenant) do
    case :ets.lookup(name(repo), {:binds, tenant}) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  @doc "Marks `tenant` as used now."
  @spec touch(module(), String.t()) :: :ok
  def touch(repo, tenant) do
    :ets.insert(name(repo), {{:used, tenant}, System.monotonic_time()})
    :ok
  end

  @doc "When `tenant` was last used, in `System.monotonic_time/0` units."
  @spec last_used(module(), String.t()) :: integer() | nil
  def last_used(repo, tenant) do
    case :ets.lookup(name(repo), {:used, tenant}) do
      [{_, at}] -> at
      [] -> nil
    end
  end

  @doc "The tenant among `candidates` that should be evicted, if any."
  @spec least_recently_used(module(), [String.t()]) :: String.t() | nil
  def least_recently_used(repo, candidates) do
    candidates
    |> Enum.reject(&(count(repo, &1) > 0 or closing?(repo, &1)))
    |> Enum.min_by(&sort_key(repo, &1), fn -> nil end)
  end

  # Never-used sorts first, and cannot be spelled as a sentinel timestamp:
  # `System.monotonic_time/0` is normally negative, so 0 would read as recent.
  defp sort_key(repo, tenant) do
    case last_used(repo, tenant) do
      nil -> {0, 0}
      at -> {1, at}
    end
  end

  @doc "Marks `tenant` as closing, so that `bound/2` refuses it."
  @spec begin_closing(module(), String.t()) :: :ok
  def begin_closing(repo, tenant) do
    :ets.insert(name(repo), {{:closing, tenant}, true})
    :ok
  end

  @doc "Clears the closing mark for `tenant`."
  @spec end_closing(module(), String.t()) :: :ok
  def end_closing(repo, tenant) do
    :ets.delete(name(repo), {:closing, tenant})
    :ok
  end

  @doc "Whether `tenant` is being closed right now."
  @spec closing?(module(), String.t()) :: boolean()
  def closing?(repo, tenant), do: :ets.member(name(repo), {:closing, tenant})

  @doc "Drops everything recorded about `tenant`."
  @spec forget(module(), String.t()) :: :ok
  def forget(repo, tenant) do
    table = name(repo)
    Enum.each([:binds, :used, :closing], &:ets.delete(table, {&1, tenant}))
    :ok
  end

  @impl true
  def init(repo) do
    # Public: binds happen in arbitrary caller processes, not in this one.
    :ets.new(name(repo), [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, repo}
  end
end
