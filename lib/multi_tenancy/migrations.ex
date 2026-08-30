# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Migrations do
  @moduledoc """
  Compiles a directory of migrations once, rather than once per tenant.
  """

  @doc "The `{version, module}` pairs in `path`, compiling them if needed."
  @spec load!(Path.t()) :: [{integer(), module()}]
  def load!(path) do
    # Keyed by a fingerprint of the directory, so adding a migration invalidates the
    # cache without a restart.
    fingerprint = fingerprint(path)

    case :persistent_term.get(key(path), nil) do
      {^fingerprint, loaded} -> loaded
      _ -> compile!(path, fingerprint)
    end
  end

  @doc "Forgets the compiled migrations for `path`. For tests."
  @spec forget(Path.t()) :: :ok
  def forget(path) do
    :persistent_term.erase(key(path))
    :ok
  end

  # `:persistent_term` because this is written once per directory per boot and read
  # on every activation. Its cost is in writes, which is why residency is not stored
  # here.
  defp compile!(path, fingerprint) do
    loaded = path |> files() |> Enum.map(&load_file!/1) |> Enum.sort()
    :persistent_term.put(key(path), {fingerprint, loaded})
    loaded
  end

  # Mirrors `Ecto.Migrator`'s own naming rules: `<version>_<name>.exs`, and a file
  # ending in `.ex` is not a migration however much it looks like one.
  defp files(path) do
    [path, "**", "*.exs"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&version_of(&1))
  end

  defp version_of(file) do
    case Integer.parse(Path.rootname(Path.basename(file))) do
      {version, "_" <> _name} -> version
      _ -> nil
    end
  end

  defp load_file!(file) do
    modules = file |> Code.compile_file() |> Enum.map(&elem(&1, 0))

    case Enum.find(modules, &migration?/1) do
      nil ->
        raise Ecto.MigrationError,
              "file #{Path.relative_to_cwd(file)} does not define an Ecto.Migration"

      module ->
        {version_of(file), module}
    end
  end

  defp migration?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__migration__, 0)
  end

  defp fingerprint(path) do
    path
    |> files()
    |> Enum.map(fn file ->
      case File.stat(file, time: :posix) do
        {:ok, stat} -> {file, stat.size, stat.mtime}
        {:error, reason} -> {file, reason}
      end
    end)
    |> Enum.sort()
  end

  defp key(path), do: {__MODULE__, Path.expand(path)}
end
