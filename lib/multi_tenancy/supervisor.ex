# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MultiTenancy.Supervisor do
  @moduledoc false
  use Supervisor

  def child_spec(repo, config, ecto_child_spec) do
    case Keyword.fetch(config, :tenants) do
      :error ->
        ecto_child_spec

      {:ok, tenants} ->
        if !AshSqlite.DataLayer.tenant_repo?(repo) do
          raise ArgumentError, """
          #{inspect(repo)} is configured with `tenants:`, but does not implement \
          `c:AshSqlite.Repo.tenant_repo/2`. Add this to the repo:

              def tenant_repo(tenant, context), do: AshSqlite.MultiTenancy.tenant_repo(__MODULE__, tenant, context)
          """
        end

        base_repo = if config[:database], do: [ecto_child_spec], else: []

        %{
          id: repo,
          start: {__MODULE__, :start_link, [{repo, tenants, base_repo}]},
          type: :supervisor
        }
    end
  end

  def start_link({repo, _tenants, _base_repo} = arg) do
    Supervisor.start_link(__MODULE__, arg, name: Module.concat(repo, TenantSupervisor))
  end

  def registry(repo), do: Module.concat(repo, TenantRegistry)
  def tenants(repo), do: Module.concat(repo, Tenants)

  @impl true
  def init({repo, tenants, base_repo}) do
    migrations = compile_migrations(tenants[:migrations_path])

    children =
      [
        {Registry,
         keys: :unique,
         name: registry(repo),
         meta: [
           migrations: migrations,
           dir: Keyword.fetch!(tenants, :dir),
           open_timeout: Keyword.get(tenants, :open_timeout, 15_000)
         ]},
        {DynamicSupervisor,
         name: tenants(repo), max_children: Keyword.get(tenants, :max_children, :infinity)}
      ] ++ base_repo

    # A restarted Registry has forgotten every tenant, so the tenants started after it
    # must go too, or a second process could open the same file.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp compile_migrations(nil), do: []

  # Mirrors `Ecto.Migrator`'s naming rules: `<version>_<name>.exs`.
  defp compile_migrations(path) do
    [path, "**", "*.exs"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      case Integer.parse(Path.basename(file)) do
        {version, "_" <> _} -> [{version, migration_module!(file)}]
        _ -> []
      end
    end)
    |> Enum.sort()
  end

  # A restart, or a second repo sharing the path, reuses the modules already loaded
  # rather than redefining code a running migration may be executing.
  defp migration_module!(file) do
    modules =
      case Code.require_file(file) do
        nil -> modules_compiled_from(file)
        compiled -> Enum.map(compiled, &elem(&1, 0))
      end

    Enum.find(modules, &function_exported?(&1, :__migration__, 0)) ||
      raise Ecto.MigrationError,
            "file #{Path.relative_to_cwd(file)} does not define an Ecto.Migration"
  end

  defp modules_compiled_from(file) do
    source = file |> Path.expand() |> String.to_charlist()

    for {module, _} <- :code.all_loaded(),
        module.module_info(:compile)[:source] == source,
        do: module
  end
end
