# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Tenant do
  @moduledoc """
  The process that owns one tenant's database: it opens and migrates the file, and its repo instance lives and dies with it.
  """
  use GenServer, restart: :temporary

  @unreserved ~c"abcdefghijklmnopqrstuvwxyz0123456789-_."

  # 255 is the usual per-name limit. `-shm` is the longest suffix SQLite adds to a
  # database's name, and `.db` is ours.
  @max_encoded_bytes 255 - byte_size(".db") - byte_size("-shm")

  def start_link({repo, tenant}) do
    GenServer.start_link(__MODULE__, {repo, tenant},
      name: {:via, Registry, {AshSqlite.MultiTenancy.Supervisor.registry(repo), tenant}}
    )
  end

  @doc "The repo instance of the tenant process `pid`, waiting for its database to open."
  @spec instance(pid(), term()) :: pid()
  def instance(pid, tenant) do
    GenServer.call(pid, :instance, :infinity)
  catch
    :exit, reason ->
      raise "could not open the database of tenant #{inspect(tenant)}: #{Exception.format_exit(reason)}"
  end

  @impl true
  # `DynamicSupervisor.start_child/2` runs `init/1` inside the supervisor, so opening
  # here would queue every tenant behind every other tenant's open.
  def init({repo, tenant}), do: {:ok, {repo, tenant}, {:continue, :open}}

  @impl true
  def handle_continue(:open, {repo, tenant}) do
    {:ok, meta} = registry_meta(repo)
    dir = Keyword.fetch!(meta, :dir)
    File.mkdir_p!(dir)

    {:ok, instance} =
      repo.start_link(
        name: nil,
        database: Path.join(dir, encode(tenant) <> ".db"),
        tenant: tenant
      )

    Ecto.Migrator.run(repo, Keyword.fetch!(meta, :migrations), :up,
      all: true,
      dynamic_repo: instance,
      log: false
    )

    Ecto.Adapters.SQL.query!(instance, "SELECT 1", [])

    {:noreply, %{repo: repo, tenant: tenant, instance: instance}}
  end

  @impl true
  def handle_call(:instance, _from, state), do: {:reply, state.instance, state}

  defp registry_meta(repo) do
    registry = AshSqlite.MultiTenancy.Supervisor.registry(repo)

    with {:ok, migrations} <- Registry.meta(registry, :migrations),
         {:ok, dir} <- Registry.meta(registry, :dir) do
      {:ok, migrations: migrations, dir: dir}
    end
  end

  # Escapes rather than sanitises, so no two tenants share a file and no tenant names a
  # path outside `dir`.
  defp encode(tenant) when is_binary(tenant) and byte_size(tenant) > 0 do
    encoded = tenant |> :binary.bin_to_list() |> Enum.map_join(&encode_byte/1)

    if byte_size(encoded) > @max_encoded_bytes do
      raise ArgumentError, """
      tenant #{inspect(tenant)} encodes to #{byte_size(encoded)} bytes, and a \
      database name can be at most #{@max_encoded_bytes}. Use a shorter identifier, \
      such as a slug or a UUID, as the tenant.
      """
    end

    encoded
  end

  defp encode(tenant) do
    raise ArgumentError, """
    expected a non-empty binary tenant, got: #{inspect(tenant)}

    A tenant names a database file, and stringifying another term here would let two \
    tenants that Ash tells apart name one file. Convert it where you set the tenant.
    """
  end

  defp encode_byte(byte) when byte in @unreserved, do: <<byte>>

  defp encode_byte(byte) do
    <<hi::4, lo::4>> = <<byte>>
    <<?~, hex(hi), hex(lo)>>
  end

  # Lowercase, so two encodings never differ only by case.
  defp hex(nibble) when nibble < 10, do: ?0 + nibble
  defp hex(nibble), do: ?a + nibble - 10
end
