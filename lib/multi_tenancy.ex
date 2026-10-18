# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy do
  @moduledoc """
  A `c:AshSqlite.Repo.tenant_repo/2` implementation that gives each tenant its own database file.

  Configure the repo with `config :my_app, MyApp.Repo, tenants: [dir: "...", migrations_path: "...", max_children: ..., open_timeout: ...]`
  and implement the callback with `def tenant_repo(tenant, context), do: AshSqlite.MultiTenancy.tenant_repo(__MODULE__, tenant, context)`.
  A tenant's file is opened and migrated on first use, and `init/2` sees the tenant as `config[:tenant]`.
  """

  alias AshSqlite.MultiTenancy.{Supervisor, Tenant}

  @unreserved ~c"abcdefghijklmnopqrstuvwxyz0123456789-_."

  # 255 is the usual per-name limit. `-journal` is the longest suffix SQLite adds to
  # a database's name, and `.db` is ours.
  @max_encoded_bytes 255 - byte_size(".db") - byte_size("-journal")

  @attempts 100

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

    {:ok, dir} = Registry.meta(registry, :dir)
    {:ok, open_timeout} = Registry.meta(registry, :open_timeout)
    path = Path.join(dir, encode(tenant) <> ".db")

    instance(repo, registry, tenant, path, open_timeout, @attempts)
  end

  defp instance(_repo, _registry, tenant, _path, _open_timeout, 0) do
    raise "tenant #{inspect(tenant)} kept stopping while being opened"
  end

  defp instance(repo, registry, tenant, path, open_timeout, attempts) do
    pid =
      case Registry.lookup(registry, tenant) do
        [{pid, _}] -> pid
        [] -> start_tenant(repo, tenant, path)
      end

    case Tenant.instance(pid, open_timeout) do
      {:ok, instance} ->
        instance

      :stopped ->
        # The Registry drops a dead tenant only once it handles the exit, so a lookup
        # straight after can return the same pid again.
        Process.sleep(1)
        instance(repo, registry, tenant, path, open_timeout, attempts - 1)

      {:timeout, pid} ->
        DynamicSupervisor.terminate_child(Supervisor.tenants(repo), pid)

        raise "the database of tenant #{inspect(tenant)} did not open within #{open_timeout}ms. \
        Raise `tenants: [open_timeout: ...]` if opening it legitimately takes longer."

      {:error, reason} ->
        raise "could not open the database of tenant #{inspect(tenant)}: #{Exception.format_exit(reason)}"
    end
  end

  defp start_tenant(repo, tenant, path) do
    case DynamicSupervisor.start_child(Supervisor.tenants(repo), {Tenant, {repo, tenant, path}}) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid

      {:error, :max_children} ->
        raise "could not open tenant #{inspect(tenant)}: #{inspect(repo)} already has the \
        most tenants open that `tenants: [max_children: ...]` allows."

      {:error, reason} ->
        raise "could not start tenant #{inspect(tenant)}: #{inspect(reason)}"
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
