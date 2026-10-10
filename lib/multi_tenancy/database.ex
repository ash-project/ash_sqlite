# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Database do
  @moduledoc """
  Turns a tenant into the name of its database file. The encoding is reversible, so no two tenants can name one file.
  """

  @unreserved ~c"abcdefghijklmnopqrstuvwxyz0123456789-_."

  # 255 is the usual per-name limit. `-shm` is the longest suffix a SQLite
  # database adds to its own name, and `.db` is ours, so this is what is left.
  @max_encoded_bytes 255 - byte_size(".db") - byte_size("-shm")

  @doc "Encodes `tenant` as a path-safe name, reversibly."
  @spec encode(String.t()) :: String.t()
  def encode(tenant) when is_binary(tenant) and byte_size(tenant) > 0 do
    encoded = tenant |> :binary.bin_to_list() |> Enum.map_join(&encode_byte/1)

    if byte_size(encoded) > @max_encoded_bytes do
      raise ArgumentError, """
      tenant #{inspect(tenant)} encodes to #{byte_size(encoded)} bytes, and a \
      database name can be at most #{@max_encoded_bytes}.

      Bytes outside #{inspect(to_string(@unreserved))} take three bytes each once \
      escaped, so a tenant of mostly-escaped bytes reaches the limit at about \
      #{div(@max_encoded_bytes, 3)} characters. Use a shorter identifier — a slug \
      or a UUID — as the tenant, and keep the display name in a column.
      """
    end

    encoded
  end

  def encode(tenant) when is_binary(tenant) do
    raise ArgumentError, "the tenant of an AshSqlite resource cannot be an empty string"
  end

  def encode(other) do
    raise ArgumentError, """
    expected a binary tenant, got: #{inspect(other)}

    A tenant names a database file, and a non-binary tenant would have to be \
    stringified to do that. Doing so here would let two different tenants -- \
    #{inspect(other)} and #{inspect(to_string_safe(other))} -- name one file while \
    remaining two tenants to Ash, so their rows would share a database with \
    nothing raising.

    Convert it where you set the tenant instead.
    """
  end

  @doc "Recovers the tenant from a name produced by `encode/1`."
  @spec decode(String.t()) :: {:ok, String.t()} | :error
  def decode(encoded) when is_binary(encoded), do: decode(encoded, [])

  @doc "The absolute path of `tenant`'s database inside `dir`."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(dir, tenant), do: Path.join(dir, encode(tenant) <> ".db")

  @doc "Every file that makes up `path`, including the ones SQLite adds."
  @spec sidecars(Path.t()) :: [Path.t()]
  def sidecars(path), do: [path, path <> "-wal", path <> "-shm"]

  @doc "The tenant a database file inside `dir` belongs to."
  @spec tenant_from_path(Path.t(), Path.t()) :: {:ok, String.t()} | :error
  def tenant_from_path(dir, path) do
    with {:ok, relative} <- relative_to(dir, path),
         {:ok, base} <- strip_extension(relative) do
      decode(base)
    end
  end

  @doc "Every tenant with a database in `dir`, in no particular order."
  @spec list(Path.t()) :: [String.t()]
  def list(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        for entry <- entries,
            {:ok, tenant} <- [tenant_from_path(dir, Path.join(dir, entry))],
            do: tenant

      {:error, _} ->
        []
    end
  end

  defp relative_to(dir, path) do
    case Path.relative_to(path, dir) do
      ^path -> :error
      relative -> if Path.dirname(relative) == ".", do: {:ok, relative}, else: :error
    end
  end

  defp strip_extension(name) do
    case Path.extname(name) do
      ".db" -> {:ok, Path.rootname(name, ".db")}
      _ -> :error
    end
  end

  defp encode_byte(byte) when byte in @unreserved, do: <<byte>>

  defp encode_byte(byte) do
    <<hi::4, lo::4>> = <<byte>>
    <<?~, hex(hi), hex(lo)>>
  end

  # Lowercase, so that the encoded alphabet as a whole is lowercase and two
  # encodings can never differ only by case. See the moduledoc.
  defp hex(nibble) when nibble < 10, do: ?0 + nibble
  defp hex(nibble), do: ?a + nibble - 10

  defp decode(<<>>, []), do: :error
  defp decode(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp decode(<<?~, hi, lo, rest::binary>>, acc) do
    with {:ok, hi} <- unhex(hi), {:ok, lo} <- unhex(lo) do
      decode(rest, [<<hi::4, lo::4>> | acc])
    end
  end

  defp decode(<<?~, _::binary>>, _acc), do: :error

  defp decode(<<byte, rest::binary>>, acc) when byte in @unreserved,
    do: decode(rest, [byte | acc])

  defp decode(_, _acc), do: :error

  defp unhex(char) when char in ?0..?9, do: {:ok, char - ?0}
  defp unhex(char) when char in ?a..?f, do: {:ok, char - ?a + 10}
  defp unhex(_char), do: :error

  defp to_string_safe(term) do
    to_string(term)
  rescue
    _ -> inspect(term)
  end
end
