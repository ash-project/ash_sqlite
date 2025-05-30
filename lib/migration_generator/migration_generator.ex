defmodule AshSqlite.MigrationGenerator do
  @moduledoc false

  require Logger

  alias AshSqlite.MigrationGenerator.{Operation, Phase}

  defstruct snapshot_path: nil,
            migration_path: nil,
            name: nil,
            quiet: false,
            current_snapshots: nil,
            answers: [],
            no_shell?: false,
            format: true,
            dry_run: false,
            check: false,
            dev: false,
            auto_name: false,
            drop_columns: false

  def generate(domains, opts \\ []) do
    domains = List.wrap(domains)
    opts = opts(opts)

    all_resources = Enum.uniq(Enum.flat_map(domains, &Ash.Domain.Info.resources/1))

    snapshots =
      all_resources
      |> Enum.filter(fn resource ->
        Ash.DataLayer.data_layer(resource) == AshSqlite.DataLayer &&
          AshSqlite.DataLayer.Info.migrate?(resource)
      end)
      |> Enum.flat_map(&get_snapshots(&1, all_resources))

    repos =
      snapshots
      |> Enum.map(& &1.repo)
      |> Enum.uniq()

    extension_migration_files =
      create_extension_migrations(repos, opts)

    migration_files =
      create_migrations(snapshots, opts)

    files = extension_migration_files ++ migration_files

    case files do
      [] ->
        if !opts.check || opts.dry_run do
          Mix.shell().info(
            "No changes detected, so no migrations or snapshots have been created."
          )
        end

        :ok

      files ->
        cond do
          opts.check ->
            raise Ash.Error.Framework.PendingCodegen,
              diff: files

          opts.dry_run ->
            Mix.shell().info(
              files
              |> Enum.sort_by(&elem(&1, 0))
              |> Enum.map_join("\n\n", fn {file, contents} ->
                "#{file}\n#{contents}"
              end)
            )

          true ->
            Enum.each(files, fn {file, contents} ->
              Mix.Generator.create_file(file, contents, force?: true)
            end)
        end
    end
  end

  @doc """
  A work in progress utility for getting snapshots.

  Does not support everything supported by the migration generator.
  """
  def take_snapshots(domain, repo, only_resources \\ nil) do
    all_resources = domain |> Ash.Domain.Info.resources() |> Enum.uniq()

    all_resources
    |> Enum.filter(fn resource ->
      Ash.DataLayer.data_layer(resource) == AshSqlite.DataLayer &&
        AshSqlite.DataLayer.Info.repo(resource) == repo &&
        (is_nil(only_resources) || resource in only_resources)
    end)
    |> Enum.flat_map(&get_snapshots(&1, all_resources))
  end

  @doc """
  A work in progress utility for getting operations between snapshots.

  Does not support everything supported by the migration generator.
  """
  def get_operations_from_snapshots(old_snapshots, new_snapshots, opts \\ []) do
    opts = %{opts(opts) | no_shell?: true}

    old_snapshots =
      old_snapshots
      |> Enum.map(&sanitize_snapshot/1)

    new_snapshots
    |> deduplicate_snapshots(opts, old_snapshots)
    |> fetch_operations(opts)
    |> Enum.flat_map(&elem(&1, 1))
    |> Enum.uniq()
    |> organize_operations()
  end

  defp add_references_primary_key(snapshot, snapshots) do
    %{
      snapshot
      | attributes:
          snapshot.attributes
          |> Enum.map(fn
            %{references: references} = attribute when not is_nil(references) ->
              if is_nil(Map.get(references, :primary_key?)) do
                %{
                  attribute
                  | references:
                      Map.put(
                        references,
                        :primary_key?,
                        find_references_primary_key(
                          references,
                          snapshots
                        )
                      )
                }
              else
                attribute
              end

            attribute ->
              attribute
          end)
    }
  end

  defp find_references_primary_key(references, snapshots) do
    Enum.find_value(snapshots, false, fn snapshot ->
      if snapshot && references && snapshot.table == references.table do
        Enum.any?(snapshot.attributes, fn attribute ->
          attribute.source == references.destination_attribute && attribute.primary_key?
        end)
      end
    end)
  end

  defp opts(opts) do
    struct(__MODULE__, opts)
  end

  defp snapshot_path(%{snapshot_path: snapshot_path}, _) when not is_nil(snapshot_path),
    do: snapshot_path

  defp snapshot_path(_config, repo) do
    # Copied from ecto's mix task, thanks Ecto ❤️
    config = repo.config()

    if snapshot_path = config[:snapshots_path] do
      snapshot_path
    else
      priv =
        config[:priv] || "priv/"

      app = Keyword.fetch!(config, :otp_app)

      Application.app_dir(
        app,
        Path.join([
          priv,
          "resource_snapshots"
        ])
      )
    end
  end

  defp create_extension_migrations(repos, opts) do
    for repo <- repos do
      snapshot_path = snapshot_path(opts, repo)
      snapshot_file = Path.join(snapshot_path, "extensions.json")

      installed_extensions =
        if File.exists?(snapshot_file) do
          snapshot_file
          |> File.read!()
          |> Jason.decode!(keys: :atoms!)
        else
          []
        end

      {_extensions_snapshot, installed_extensions} =
        case installed_extensions do
          installed when is_list(installed) ->
            {%{
               installed: installed
             }, installed}

          other ->
            {other, other.installed}
        end

      requesteds =
        repo.installed_extensions()
        |> Enum.map(fn
          extension_module when is_atom(extension_module) ->
            {ext_name, version, _up_fn, _down_fn} = extension = extension_module.extension()

            {"#{ext_name}_v#{version}", extension}

          extension_name ->
            {extension_name, extension_name}
        end)

      to_install =
        requesteds
        |> Enum.filter(fn {name, _extension} -> !Enum.member?(installed_extensions, name) end)
        |> Enum.map(fn {_name, extension} -> extension end)

      if Enum.empty?(to_install) do
        []
      else
        {module, migration_name} =
          case to_install do
            [{ext_name, version, _up_fn, _down_fn}] ->
              {"install_#{ext_name}_v#{version}",
               "#{timestamp(true)}_install_#{ext_name}_v#{version}_extension"}

            [single] ->
              {"install_#{single}", "#{timestamp(true)}_install_#{single}_extension"}

            multiple ->
              {"install_#{Enum.count(multiple)}_extensions",
               "#{timestamp(true)}_install_#{Enum.count(multiple)}_extensions"}
          end

        migration_file =
          opts
          |> migration_path(repo)
          |> Path.join(migration_name <> "#{if opts.dev, do: "_dev"}.exs")

        sanitized_module =
          module
          |> String.replace("-", "_")
          |> Macro.camelize()

        module_name = Module.concat([repo, Migrations, sanitized_module])

        install =
          Enum.map_join(to_install, "\n", fn
            {_ext_name, version, up_fn, _down_fn} when is_function(up_fn, 1) ->
              up_fn.(version)

            extension ->
              raise "only custom extensions supported currently. Got #{inspect(extension)}"
          end)

        uninstall =
          Enum.map_join(to_install, "\n", fn
            {_ext_name, version, _up_fn, down_fn} when is_function(down_fn, 1) ->
              down_fn.(version)

            extension ->
              raise "only custom extensions supported currently. Got #{inspect(extension)}"
          end)

        contents = """
        defmodule #{inspect(module_name)} do
          @moduledoc \"\"\"
          Installs any extensions that are mentioned in the repo's `installed_extensions/0` callback

          This file was autogenerated with `mix ash_sqlite.generate_migrations`
          \"\"\"

          use Ecto.Migration

          def up do
            #{install}
          end

          def down do
            # Uncomment this if you actually want to uninstall the extensions
            # when this migration is rolled back:
            #{uninstall}
          end
        end
        """

        installed = Enum.map(requesteds, fn {name, _extension} -> name end)

        snapshot_contents =
          Jason.encode!(
            %{
              installed: installed
            },
            pretty: true
          )

        contents = format(contents, opts)

        [
          {snapshot_file, snapshot_contents},
          {migration_file, contents}
        ]
      end
    end
    |> List.flatten()
  end

  defp create_migrations(snapshots, opts) do
    snapshots
    |> Enum.group_by(& &1.repo)
    |> Enum.flat_map(fn {repo, snapshots} ->
      deduped = deduplicate_snapshots(snapshots, opts)

      snapshots_with_operations =
        deduped
        |> fetch_operations(opts)
        |> Enum.map(&add_order_to_operations/1)

      snapshots = Enum.map(snapshots_with_operations, &elem(&1, 0))

      snapshots_with_operations
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.uniq()
      |> case do
        [] ->
          []

        operations ->
          dev_migrations = get_dev_migrations(opts, repo)

          if !opts.dev and dev_migrations != [] do
            if opts.check do
              Mix.shell().error("""
              Codegen check failed.

              You have migrations remaining that were generated with the --dev flag.

              Run `mix ash.codegen <name>` to remove the dev migraitons and replace them
              with production ready migrations.
              """)

              exit({:shutdown, 1})
            else
              remove_dev_migrations_and_snapshots(dev_migrations, repo, opts, snapshots)
            end
          end

          migration_files =
            operations
            |> organize_operations
            |> build_up_and_down()
            |> migration(repo, opts)

          snapshot_files = create_new_snapshot(snapshots, repo_name(repo), opts)

          [migration_files] ++ snapshot_files
      end
    end)
  end

  defp get_dev_migrations(opts, repo) do
    opts
    |> migration_path(repo)
    |> File.ls()
    |> case do
      {:error, _error} -> []
      {:ok, migrations} -> Enum.filter(migrations, &String.contains?(&1, "_dev.exs"))
    end
  end

  if Mix.env() == :test do
    defp with_repo_not_in_test(repo, fun) do
      fun.(repo)
    end
  else
    defp with_repo_not_in_test(repo, fun) do
      Ecto.Migrator.with_repo(repo, fun)
    end
  end

  defp remove_dev_migrations_and_snapshots(dev_migrations, repo, opts, snapshots) do
    dev_migrations =
      Enum.map(dev_migrations, fn migration ->
        opts
        |> migration_path(repo)
        |> Path.join(migration)
      end)

    with_repo_not_in_test(repo, fn repo ->
      {repo, query, opts} = Ecto.Migration.SchemaMigration.versions(repo, [], nil)

      repo.transaction(fn ->
        Ecto.Migration.SchemaMigration.ensure_schema_migrations_table!(
          repo,
          repo.config(),
          []
        )

        versions = repo.all(query, opts)

        dev_migrations
        |> Enum.map(&extract_migration_info/1)
        |> Enum.filter(& &1)
        |> Enum.map(&load_migration!/1)
        |> Enum.sort()
        |> Enum.filter(fn {version, _} ->
          version in versions
        end)
        |> Enum.each(fn {version, mod} ->
          Ecto.Migration.Runner.run(
            repo,
            [],
            version,
            mod,
            :forward,
            :down,
            :down,
            all: true
          )

          Ecto.Migration.SchemaMigration.down(repo, repo.config(), version, [])
        end)
      end)
    end)

    # Remove dev migration files
    Enum.each(dev_migrations, &File.rm!(&1))

    # Remove dev snapshots
    Enum.each(snapshots, fn snapshot ->
      snapshot_folder =
        opts
        |> snapshot_path(snapshot.repo)
        |> Path.join(repo_name(snapshot.repo))
        |> Path.join(snapshot.table)

      if File.exists?(snapshot_folder) do
        snapshot_folder
        |> File.ls!()
        |> Enum.filter(&String.contains?(&1, "_dev.json"))
        |> Enum.each(fn snapshot_name ->
          snapshot_folder
          |> Path.join(snapshot_name)
          |> File.rm!()
        end)
      end
    end)
  end

  defp load_migration!({version, _, file}) when is_binary(file) do
    loaded_modules = file |> compile_file() |> Enum.map(&elem(&1, 0))

    if mod = Enum.find(loaded_modules, &migration?/1) do
      {version, mod}
    else
      raise Ecto.MigrationError,
            "file #{Path.relative_to_cwd(file)} does not define an Ecto.Migration"
    end
  end

  defp compile_file(file) do
    Code.compile_file(file)
  end

  defp migration?(mod) do
    function_exported?(mod, :__migration__, 0)
  end

  defp extract_migration_info(file) do
    base = Path.basename(file)

    case Integer.parse(Path.rootname(base)) do
      {integer, "_" <> name} -> {integer, name, file}
      _ -> nil
    end
  end

  defp add_order_to_operations({snapshot, operations}) do
    operations_with_order = Enum.map(operations, &add_order_to_operation(&1, snapshot.attributes))

    {snapshot, operations_with_order}
  end

  defp add_order_to_operation(%{attribute: attribute} = op, attributes) do
    order = Enum.find_index(attributes, &(&1.source == attribute.source))
    attribute = Map.put(attribute, :order, order)

    %{op | attribute: attribute}
  end

  defp add_order_to_operation(%{new_attribute: attribute} = op, attributes) do
    order = Enum.find_index(attributes, &(&1.source == attribute.source))
    attribute = Map.put(attribute, :order, order)

    %{op | new_attribute: attribute}
  end

  defp add_order_to_operation(op, _), do: op

  defp organize_operations([]), do: []

  defp organize_operations(operations) do
    operations
    |> sort_operations()
    |> streamline()
    |> group_into_phases()
    |> clean_phases()
  end

  defp clean_phases(phases) do
    phases
    |> Enum.flat_map(fn
      %{operations: []} ->
        []

      %{operations: operations} = phase ->
        if Enum.all?(operations, &match?(%{commented?: true}, &1)) do
          [%{phase | commented?: true}]
        else
          [phase]
        end

      op ->
        [op]
    end)
  end

  defp deduplicate_snapshots(snapshots, opts, existing_snapshots \\ []) do
    grouped =
      snapshots
      |> Enum.group_by(fn snapshot ->
        snapshot.table
      end)

    old_snapshots =
      Map.new(grouped, fn {key, [snapshot | _]} ->
        old_snapshot =
          if opts.no_shell? do
            Enum.find(existing_snapshots, &(&1.table == snapshot.table))
          else
            get_existing_snapshot(snapshot, opts)
          end

        {
          key,
          old_snapshot
        }
      end)

    old_snapshots_list = Map.values(old_snapshots)

    old_snapshots =
      Map.new(old_snapshots, fn {key, old_snapshot} ->
        if old_snapshot do
          {key, add_references_primary_key(old_snapshot, old_snapshots_list)}
        else
          {key, old_snapshot}
        end
      end)

    grouped
    |> Enum.map(fn {key, [snapshot | _] = snapshots} ->
      existing_snapshot = old_snapshots[key]

      {primary_key, identities} = merge_primary_keys(existing_snapshot, snapshots, opts)

      attributes = Enum.flat_map(snapshots, & &1.attributes)

      count_with_create = Enum.count(snapshots, & &1.has_create_action)

      new_snapshot = %{
        snapshot
        | attributes: merge_attributes(attributes, snapshot.table, count_with_create),
          identities: snapshots |> Enum.flat_map(& &1.identities) |> Enum.uniq(),
          custom_indexes: snapshots |> Enum.flat_map(& &1.custom_indexes) |> Enum.uniq(),
          custom_statements: snapshots |> Enum.flat_map(& &1.custom_statements) |> Enum.uniq()
      }

      all_identities =
        new_snapshot.identities
        |> Kernel.++(identities)
        |> Enum.sort_by(& &1.name)
        # We sort the identities by there being an identity with a matching name in the existing snapshot
        # so that we prefer identities that currently exist over new ones
        |> Enum.sort_by(fn identity ->
          existing_snapshot
          |> Kernel.||(%{})
          |> Map.get(:identities, [])
          |> Enum.any?(fn existing_identity ->
            existing_identity.name == identity.name
          end)
          |> Kernel.!()
        end)
        |> Enum.uniq_by(fn identity ->
          {Enum.sort(identity.keys), identity.base_filter}
        end)

      new_snapshot = %{new_snapshot | identities: all_identities}

      {
        %{
          new_snapshot
          | attributes:
              Enum.map(new_snapshot.attributes, fn attribute ->
                if attribute.source in primary_key do
                  %{attribute | primary_key?: true}
                else
                  %{attribute | primary_key?: false}
                end
              end)
        },
        existing_snapshot
      }
    end)
  end

  defp merge_attributes(attributes, table, count) do
    attributes
    |> Enum.with_index()
    |> Enum.map(fn {attr, i} -> Map.put(attr, :order, i) end)
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {source, attributes} ->
      size =
        attributes
        |> Enum.map(& &1.size)
        |> Enum.filter(& &1)
        |> case do
          [] ->
            nil

          sizes ->
            Enum.max(sizes)
        end

      %{
        source: source,
        type: merge_types(Enum.map(attributes, & &1.type), source, table),
        size: size,
        default: merge_defaults(Enum.map(attributes, & &1.default)),
        allow_nil?: Enum.any?(attributes, & &1.allow_nil?) || Enum.count(attributes) < count,
        generated?: Enum.any?(attributes, & &1.generated?),
        references: merge_references(Enum.map(attributes, & &1.references), source, table),
        primary_key?: false,
        order: attributes |> Enum.map(& &1.order) |> Enum.min()
      }
    end)
    |> Enum.sort(&(&1.order < &2.order))
    |> Enum.map(&Map.drop(&1, [:order]))
  end

  defp merge_references(references, name, table) do
    references
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] ->
        nil

      references ->
        %{
          destination_attribute: merge_uniq!(references, table, :destination_attribute, name),
          deferrable: merge_uniq!(references, table, :deferrable, name),
          destination_attribute_default:
            merge_uniq!(references, table, :destination_attribute_default, name),
          destination_attribute_generated:
            merge_uniq!(references, table, :destination_attribute_generated, name),
          multitenancy: merge_uniq!(references, table, :multitenancy, name),
          primary_key?: merge_uniq!(references, table, :primary_key?, name),
          on_delete: merge_uniq!(references, table, :on_delete, name),
          on_update: merge_uniq!(references, table, :on_update, name),
          name: merge_uniq!(references, table, :name, name),
          table: merge_uniq!(references, table, :table, name)
        }
    end
  end

  defp merge_uniq!(references, table, field, attribute) do
    references
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] ->
        nil

      [value] ->
        value

      values ->
        values = Enum.map_join(values, "\n", &"  * #{inspect(&1)}")

        raise """
        Conflicting configurations for references for #{table}.#{attribute}:

        Values:

        #{values}
        """
    end
  end

  defp merge_types(types, name, table) do
    types
    |> Enum.uniq()
    |> case do
      [type] ->
        type

      types ->
        raise "Conflicting types for table `#{table}.#{name}`: #{inspect(types)}"
    end
  end

  defp merge_defaults(defaults) do
    defaults
    |> Enum.uniq()
    |> case do
      [default] -> default
      _ -> "nil"
    end
  end

  defp merge_primary_keys(nil, [snapshot | _] = snapshots, opts) do
    snapshots
    |> Enum.map(&pkey_names(&1.attributes))
    |> Enum.uniq()
    |> case do
      [pkey_names] ->
        {pkey_names, []}

      unique_primary_keys ->
        unique_primary_key_names =
          unique_primary_keys
          |> Enum.with_index()
          |> Enum.map_join("\n", fn {pkey, index} ->
            "#{index}: #{inspect(pkey)}"
          end)

        choice =
          if opts.no_shell? do
            raise "Unimplemented: cannot resolve primary key ambiguity without shell input"
          else
            message = """
            Which primary key should be used for the table `#{snapshot.table}` (enter the number)?

            #{unique_primary_key_names}
            """

            message
            |> Mix.shell().prompt()
            |> String.to_integer()
          end

        identities =
          unique_primary_keys
          |> List.delete_at(choice)
          |> Enum.map(fn pkey_names ->
            pkey_name_string = Enum.join(pkey_names, "_")
            name = snapshot.table <> "_" <> pkey_name_string

            %{
              keys: pkey_names,
              name: name
            }
          end)

        primary_key = Enum.sort(Enum.at(unique_primary_keys, choice))

        identities =
          Enum.reject(identities, fn identity ->
            Enum.sort(identity.keys) == primary_key
          end)

        {primary_key, identities}
    end
  end

  defp merge_primary_keys(existing_snapshot, snapshots, opts) do
    pkey_names = pkey_names(existing_snapshot.attributes)

    one_pkey_exists? =
      Enum.any?(snapshots, fn snapshot ->
        pkey_names(snapshot.attributes) == pkey_names
      end)

    if one_pkey_exists? do
      identities =
        snapshots
        |> Enum.map(&pkey_names(&1.attributes))
        |> Enum.uniq()
        |> Enum.reject(&(&1 == pkey_names))
        |> Enum.map(fn pkey_names ->
          pkey_name_string = Enum.join(pkey_names, "_")
          name = existing_snapshot.table <> "_" <> pkey_name_string

          %{
            keys: pkey_names,
            name: name
          }
        end)

      {pkey_names, identities}
    else
      merge_primary_keys(nil, snapshots, opts)
    end
  end

  defp pkey_names(attributes) do
    attributes
    |> Enum.filter(& &1.primary_key?)
    |> Enum.map(& &1.source)
    |> Enum.sort()
  end

  defp migration_path(opts, repo) do
    # Copied from ecto's mix task, thanks Ecto ❤️
    config = repo.config()
    app = Keyword.fetch!(config, :otp_app)

    if path = opts.migration_path || config[:tenant_migrations_path] do
      path
    else
      priv =
        config[:priv] || "priv/#{repo |> Module.split() |> List.last() |> Macro.underscore()}"

      Application.app_dir(app, Path.join(priv, "migrations"))
    end
  end

  defp repo_name(repo) do
    repo |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp migration({up, down}, repo, opts) do
    migration_path = migration_path(opts, repo)

    require_name!(opts)

    {migration_name, last_part} =
      if opts.name do
        {"#{timestamp(true)}_#{opts.name}", "#{opts.name}"}
      else
        count =
          migration_path
          |> Path.join("*_migrate_resources*")
          |> Path.wildcard()
          |> Enum.map(fn path ->
            path
            |> Path.basename()
            |> String.split("_migrate_resources", parts: 2)
            |> Enum.at(1)
            |> Integer.parse()
            |> case do
              {integer, _} ->
                integer

              _ ->
                0
            end
          end)
          |> Enum.max(fn -> 0 end)
          |> Kernel.+(1)

        {"#{timestamp(true)}_migrate_resources#{count}", "migrate_resources#{count}"}
      end

    migration_file =
      migration_path
      |> Path.join(migration_name <> "#{if opts.dev, do: "_dev"}.exs")

    module_name =
      Module.concat([repo, Migrations, Macro.camelize(last_part)])

    contents = """
    defmodule #{inspect(module_name)} do
      @moduledoc \"\"\"
      Updates resources based on their most recent snapshots.

      This file was autogenerated with `mix ash_sqlite.generate_migrations`
      \"\"\"

      use Ecto.Migration

      def up do
        #{up}
      end

      def down do
        #{down}
      end
    end
    """

    try do
      {migration_file, format(contents, opts)}
    rescue
      exception ->
        reraise(
          """
          Exception while formatting generated code:
          #{Exception.format(:error, exception, __STACKTRACE__)}

          Code:

          #{add_line_numbers(contents)}

          To generate it unformatted anyway, but manually fix it, use the `--no-format` option.
          """,
          __STACKTRACE__
        )
    end
  end

  defp require_name!(opts) do
    if !opts.name && !opts.dry_run && !opts.check && !opts.dev && !opts.auto_name do
      raise """
      Name must be provided when generating migrations, unless `--dry-run` or `--check` or `--dev` is also provided.

      Please provide a name. for example:

          mix ash_sqlite.generate_migrations <name> ...args
      """
    end

    :ok
  end

  defp add_line_numbers(contents) do
    lines = String.split(contents, "\n")

    digits = String.length(to_string(Enum.count(lines)))

    lines
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {line, index} ->
      "#{String.pad_trailing(to_string(index), digits, " ")} | #{line}"
    end)
  end

  defp create_new_snapshot(snapshots, repo_name, opts) do
    Enum.map(snapshots, fn snapshot ->
      snapshot_binary = snapshot_to_binary(snapshot)

      snapshot_folder =
        opts
        |> snapshot_path(snapshot.repo)
        |> Path.join(repo_name)

      dev = if opts.dev, do: "_dev"

      snapshot_file =
        Path.join(snapshot_folder, "#{snapshot.table}/#{timestamp()}#{dev}.json")

      old_snapshot_folder = Path.join(snapshot_folder, "#{snapshot.table}#{dev}.json")

      if File.exists?(old_snapshot_folder) do
        new_snapshot_folder = Path.join(snapshot_folder, "#{snapshot.table}/initial#{dev}.json")
        File.rename(old_snapshot_folder, new_snapshot_folder)
      end

      File.mkdir_p(Path.dirname(snapshot_file))

      {snapshot_file, snapshot_binary}
    end)
  end

  @doc false
  def build_up_and_down(phases) do
    up =
      Enum.map_join(phases, "\n", fn phase ->
        phase
        |> phase.__struct__.up()
        |> Kernel.<>("\n")
        |> maybe_comment(phase)
      end)

    down =
      phases
      |> Enum.reverse()
      |> Enum.map_join("\n", fn phase ->
        phase
        |> phase.__struct__.down()
        |> Kernel.<>("\n")
        |> maybe_comment(phase)
      end)

    {up, down}
  end

  defp maybe_comment(text, %{commented?: true}) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if String.starts_with?(line, "#") do
        line
      else
        "# #{line}"
      end
    end)
  end

  defp maybe_comment(text, _), do: text

  defp format(string, opts) do
    if opts.format do
      Code.format_string!(string, locals_without_parens: ecto_sql_locals_without_parens())
    else
      string
    end
  rescue
    exception ->
      IO.puts("""
      Exception while formatting:

      #{inspect(exception)}

      #{inspect(string)}
      """)

      reraise exception, __STACKTRACE__
  end

  defp ecto_sql_locals_without_parens do
    path = File.cwd!() |> Path.join("deps/ecto_sql/.formatter.exs")

    if File.exists?(path) do
      {opts, _} = Code.eval_file(path)
      Keyword.get(opts, :locals_without_parens, [])
    else
      []
    end
  end

  defp streamline(ops, acc \\ [])
  defp streamline([], acc), do: Enum.reverse(acc)

  defp streamline(
         [
           %Operation.AddAttribute{
             attribute: %{
               source: name
             },
             table: table
           } = add
           | rest
         ],
         acc
       ) do
    rest
    |> Enum.take_while(fn
      %custom{} when custom in [Operation.AddCustomStatement, Operation.RemoveCustomStatement] ->
        false

      op ->
        op.table == table
    end)
    |> Enum.with_index()
    |> Enum.find(fn
      {%Operation.AlterAttribute{
         new_attribute: %{source: ^name, references: references},
         old_attribute: %{source: ^name}
       }, _}
      when not is_nil(references) ->
        true

      _ ->
        false
    end)
    |> case do
      nil ->
        streamline(rest, [add | acc])

      {alter, index} ->
        new_attribute = Map.put(add.attribute, :references, alter.new_attribute.references)
        streamline(List.delete_at(rest, index), [%{add | attribute: new_attribute} | acc])
    end
  end

  defp streamline([first | rest], acc) do
    streamline(rest, [first | acc])
  end

  defp group_into_phases(ops, current \\ nil, acc \\ [])

  defp group_into_phases([], nil, acc), do: Enum.reverse(acc)

  defp group_into_phases([], phase, acc) do
    phase = %{phase | operations: Enum.reverse(phase.operations)}
    Enum.reverse([phase | acc])
  end

  defp group_into_phases(
         [
           %Operation.CreateTable{table: table, options: options, multitenancy: multitenancy}
           | rest
         ],
         nil,
         acc
       ) do
    # this is kind of a hack
    {has_to_be_in_this_phase, rest} =
      Enum.split_with(rest, fn
        %Operation.AddAttribute{table: ^table} -> true
        _ -> false
      end)

    group_into_phases(
      rest,
      %Phase.Create{
        table: table,
        multitenancy: multitenancy,
        options: options,
        operations: has_to_be_in_this_phase
      },
      acc
    )
  end

  defp group_into_phases(
         [%Operation.AddAttribute{table: table} = op | rest],
         %{table: table} = phase,
         acc
       ) do
    group_into_phases(rest, %{phase | operations: [op | phase.operations]}, acc)
  end

  defp group_into_phases(
         [%Operation.AlterAttribute{table: table} = op | rest],
         %Phase.Alter{table: table} = phase,
         acc
       ) do
    group_into_phases(rest, %{phase | operations: [op | phase.operations]}, acc)
  end

  defp group_into_phases(
         [%Operation.RenameAttribute{table: table} = op | rest],
         %Phase.Alter{table: table} = phase,
         acc
       ) do
    group_into_phases(rest, %{phase | operations: [op | phase.operations]}, acc)
  end

  defp group_into_phases(
         [%Operation.RemoveAttribute{table: table} = op | rest],
         %{table: table} = phase,
         acc
       ) do
    group_into_phases(rest, %{phase | operations: [op | phase.operations]}, acc)
  end

  defp group_into_phases([%{no_phase: true} = op | rest], nil, acc) do
    group_into_phases(rest, nil, [op | acc])
  end

  defp group_into_phases([operation | rest], nil, acc) do
    phase = %Phase.Alter{
      operations: [operation],
      multitenancy: operation.multitenancy,
      table: operation.table
    }

    group_into_phases(rest, phase, acc)
  end

  defp group_into_phases(operations, phase, acc) do
    phase = %{phase | operations: Enum.reverse(phase.operations)}
    group_into_phases(operations, nil, [phase | acc])
  end

  defp sort_operations(ops, acc \\ [])
  defp sort_operations([], acc), do: acc

  defp sort_operations([op | rest], []), do: sort_operations(rest, [op])

  defp sort_operations([op | rest], acc) do
    acc = Enum.reverse(acc)

    after_index = Enum.find_index(acc, &after?(op, &1))

    new_acc =
      if after_index do
        acc
        |> List.insert_at(after_index, op)
        |> Enum.reverse()
      else
        [op | Enum.reverse(acc)]
      end

    sort_operations(rest, new_acc)
  end

  defp after?(_, %Operation.AlterDeferrability{direction: :down}), do: true
  defp after?(%Operation.AlterDeferrability{direction: :up}, _), do: true

  defp after?(
         %Operation.RemovePrimaryKey{},
         %Operation.DropForeignKey{}
       ),
       do: true

  defp after?(
         %Operation.DropForeignKey{},
         %Operation.RemovePrimaryKey{}
       ),
       do: false

  defp after?(%Operation.RemovePrimaryKey{}, _), do: false
  defp after?(_, %Operation.RemovePrimaryKey{}), do: true
  defp after?(%Operation.RemovePrimaryKeyDown{}, _), do: true
  defp after?(_, %Operation.RemovePrimaryKeyDown{}), do: false

  defp after?(
         %Operation.AddCustomStatement{},
         _
       ),
       do: true

  defp after?(
         _,
         %Operation.RemoveCustomStatement{}
       ),
       do: true

  defp after?(
         %Operation.AddAttribute{attribute: %{order: l}, table: table},
         %Operation.AddAttribute{attribute: %{order: r}, table: table}
       ),
       do: l > r

  defp after?(
         %Operation.RenameUniqueIndex{
           table: table
         },
         %{table: table}
       ) do
    true
  end

  defp after?(
         %Operation.AddUniqueIndex{
           table: table
         },
         %{table: table}
       ) do
    true
  end

  defp after?(
         %Operation.AddCustomIndex{
           table: table
         },
         %Operation.AddAttribute{table: table}
       ) do
    true
  end

  defp after?(
         %Operation.RemoveUniqueIndex{table: table},
         %Operation.AddUniqueIndex{table: table}
       ) do
    false
  end

  defp after?(
         %Operation.RemoveUniqueIndex{table: table},
         %{table: table}
       ) do
    true
  end

  defp after?(%Operation.AlterAttribute{table: table}, %Operation.DropForeignKey{
         table: table,
         direction: :up
       }),
       do: true

  defp after?(
         %Operation.AlterAttribute{table: table},
         %Operation.DropForeignKey{
           table: table,
           direction: :down
         }
       ),
       do: false

  defp after?(
         %Operation.DropForeignKey{
           table: table,
           direction: :down
         },
         %Operation.AlterAttribute{table: table}
       ),
       do: true

  defp after?(%Operation.AddAttribute{table: table}, %Operation.CreateTable{
         table: table
       }) do
    true
  end

  defp after?(
         %Operation.AddAttribute{
           attribute: %{
             references: %{table: table, destination_attribute: name}
           }
         },
         %Operation.AddAttribute{table: table, attribute: %{source: name}}
       ),
       do: true

  defp after?(
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: false
           }
         },
         %Operation.AddAttribute{table: table, attribute: %{primary_key?: true}}
       ),
       do: true

  defp after?(
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: true
           }
         },
         %Operation.RemoveAttribute{
           table: table,
           attribute: %{primary_key?: true}
         }
       ),
       do: true

  defp after?(
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: true
           }
         },
         %Operation.AlterAttribute{
           table: table,
           new_attribute: %{primary_key?: false},
           old_attribute: %{primary_key?: true}
         }
       ),
       do: true

  defp after?(
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: true
           }
         },
         %Operation.AlterAttribute{
           table: table,
           new_attribute: %{primary_key?: false},
           old_attribute: %{primary_key?: true}
         }
       ),
       do: true

  defp after?(
         %Operation.RemoveAttribute{
           table: table,
           attribute: %{primary_key?: true}
         },
         %Operation.AlterAttribute{
           table: table,
           new_attribute: %{
             primary_key?: true
           },
           old_attribute: %{
             primary_key?: false
           }
         }
       ),
       do: true

  defp after?(
         %Operation.AlterAttribute{
           table: table,
           new_attribute: %{primary_key?: false},
           old_attribute: %{
             primary_key?: true
           }
         },
         %Operation.AlterAttribute{
           table: table,
           new_attribute: %{
             primary_key?: true
           },
           old_attribute: %{
             primary_key?: false
           }
         }
       ),
       do: true

  defp after?(
         %Operation.AlterAttribute{
           table: table,
           new_attribute: %{primary_key?: false},
           old_attribute: %{
             primary_key?: true
           }
         },
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: true
           }
         }
       ),
       do: false

  defp after?(
         %Operation.AlterAttribute{
           table: table,
           new_attribute: %{primary_key?: false},
           old_attribute: %{primary_key?: true}
         },
         %Operation.AddAttribute{
           table: table,
           attribute: %{
             primary_key?: true
           }
         }
       ),
       do: true

  defp after?(
         %Operation.AlterAttribute{
           new_attribute: %{
             references: %{destination_attribute: destination_attribute, table: table}
           }
         },
         %Operation.AddUniqueIndex{identity: %{keys: keys}, table: table}
       ) do
    destination_attribute in keys
  end

  defp after?(
         %Operation.AlterAttribute{
           new_attribute: %{references: %{table: table, destination_attribute: source}}
         },
         %Operation.AlterAttribute{
           new_attribute: %{
             source: source
           },
           table: table
         }
       ) do
    true
  end

  defp after?(
         %Operation.AlterAttribute{
           new_attribute: %{
             source: source
           },
           table: table
         },
         %Operation.AlterAttribute{
           new_attribute: %{references: %{table: table, destination_attribute: source}}
         }
       ) do
    false
  end

  defp after?(
         %Operation.RemoveAttribute{attribute: %{source: source}, table: table},
         %Operation.AlterAttribute{
           old_attribute: %{
             references: %{table: table, destination_attribute: source}
           }
         }
       ),
       do: true

  defp after?(
         %Operation.AlterAttribute{
           new_attribute: %{
             references: %{table: table, destination_attribute: name}
           }
         },
         %Operation.AddAttribute{table: table, attribute: %{source: name}}
       ),
       do: true

  defp after?(
         %Operation.AlterAttribute{new_attribute: %{references: references}, table: table},
         %{table: table}
       )
       when not is_nil(references),
       do: true

  defp after?(_, _), do: false

  defp fetch_operations(snapshots, opts) do
    snapshots
    |> Enum.map(fn {snapshot, existing_snapshot} ->
      {snapshot, do_fetch_operations(snapshot, existing_snapshot, opts)}
    end)
    |> Enum.reject(fn {_, ops} ->
      Enum.empty?(ops)
    end)
  end

  defp do_fetch_operations(snapshot, existing_snapshot, opts, acc \\ [])

  defp do_fetch_operations(snapshot, nil, opts, acc) do
    empty_snapshot = %{
      attributes: [],
      identities: [],
      custom_indexes: [],
      custom_statements: [],
      table: snapshot.table,
      repo: snapshot.repo,
      base_filter: nil,
      empty?: true,
      multitenancy: %{
        attribute: nil,
        strategy: nil,
        global: nil
      }
    }

    do_fetch_operations(snapshot, empty_snapshot, opts, [
      %Operation.CreateTable{
        table: snapshot.table,
        multitenancy: snapshot.multitenancy,
        old_multitenancy: empty_snapshot.multitenancy,
        options: [strict?: snapshot.strict?]
      }
      | acc
    ])
  end

  defp do_fetch_operations(snapshot, old_snapshot, opts, acc) do
    attribute_operations = attribute_operations(snapshot, old_snapshot, opts)
    pkey_operations = pkey_operations(snapshot, old_snapshot, attribute_operations)

    rewrite_all_identities? = changing_multitenancy_affects_identities?(snapshot, old_snapshot)

    custom_statements_to_add =
      snapshot.custom_statements
      |> Enum.reject(fn statement ->
        Enum.any?(old_snapshot.custom_statements, &(&1.name == statement.name))
      end)
      |> Enum.map(&%Operation.AddCustomStatement{statement: &1, table: snapshot.table})

    custom_statements_to_remove =
      old_snapshot.custom_statements
      |> Enum.reject(fn old_statement ->
        Enum.any?(snapshot.custom_statements, &(&1.name == old_statement.name))
      end)
      |> Enum.map(&%Operation.RemoveCustomStatement{statement: &1, table: snapshot.table})

    custom_statements_to_alter =
      snapshot.custom_statements
      |> Enum.flat_map(fn statement ->
        old_statement = Enum.find(old_snapshot.custom_statements, &(&1.name == statement.name))

        if old_statement &&
             (old_statement.code? != statement.code? ||
                old_statement.up != statement.up || old_statement.down != statement.down) do
          [
            %Operation.RemoveCustomStatement{statement: old_statement, table: snapshot.table},
            %Operation.AddCustomStatement{statement: statement, table: snapshot.table}
          ]
        else
          []
        end
      end)

    custom_indexes_to_add =
      Enum.filter(snapshot.custom_indexes, fn index ->
        !Enum.find(old_snapshot.custom_indexes, fn old_custom_index ->
          indexes_match?(snapshot.table, old_custom_index, index)
        end)
      end)
      |> Enum.map(fn custom_index ->
        %Operation.AddCustomIndex{
          index: custom_index,
          table: snapshot.table,
          multitenancy: snapshot.multitenancy,
          base_filter: snapshot.base_filter
        }
      end)

    custom_indexes_to_remove =
      Enum.filter(old_snapshot.custom_indexes, fn old_custom_index ->
        rewrite_all_identities? ||
          !Enum.find(snapshot.custom_indexes, fn index ->
            indexes_match?(snapshot.table, old_custom_index, index)
          end)
      end)
      |> Enum.map(fn custom_index ->
        %Operation.RemoveCustomIndex{
          index: custom_index,
          table: old_snapshot.table,
          multitenancy: old_snapshot.multitenancy,
          base_filter: old_snapshot.base_filter
        }
      end)

    unique_indexes_to_remove =
      if rewrite_all_identities? do
        old_snapshot.identities
      else
        Enum.reject(old_snapshot.identities, fn old_identity ->
          Enum.find(snapshot.identities, fn identity ->
            identity.name == old_identity.name &&
              Enum.sort(old_identity.keys) == Enum.sort(identity.keys) &&
              old_identity.base_filter == identity.base_filter
          end)
        end)
      end
      |> Enum.map(fn identity ->
        %Operation.RemoveUniqueIndex{
          identity: identity,
          table: snapshot.table
        }
      end)

    unique_indexes_to_rename =
      if rewrite_all_identities? do
        []
      else
        snapshot.identities
        |> Enum.map(fn identity ->
          Enum.find_value(old_snapshot.identities, fn old_identity ->
            if old_identity.name == identity.name &&
                 old_identity.index_name != identity.index_name do
              {old_identity, identity}
            end
          end)
        end)
        |> Enum.filter(& &1)
      end
      |> Enum.map(fn {old_identity, new_identity} ->
        %Operation.RenameUniqueIndex{
          old_identity: old_identity,
          new_identity: new_identity,
          table: snapshot.table
        }
      end)

    unique_indexes_to_add =
      if rewrite_all_identities? do
        snapshot.identities
      else
        Enum.reject(snapshot.identities, fn identity ->
          Enum.find(old_snapshot.identities, fn old_identity ->
            old_identity.name == identity.name &&
              Enum.sort(old_identity.keys) == Enum.sort(identity.keys) &&
              old_identity.base_filter == identity.base_filter
          end)
        end)
      end
      |> Enum.map(fn identity ->
        %Operation.AddUniqueIndex{
          identity: identity,
          table: snapshot.table
        }
      end)

    [
      pkey_operations,
      unique_indexes_to_remove,
      attribute_operations,
      unique_indexes_to_add,
      unique_indexes_to_rename,
      custom_indexes_to_add,
      custom_indexes_to_remove,
      custom_statements_to_add,
      custom_statements_to_remove,
      custom_statements_to_alter,
      acc
    ]
    |> Enum.concat()
    |> Enum.map(&Map.put(&1, :multitenancy, snapshot.multitenancy))
    |> Enum.map(&Map.put(&1, :old_multitenancy, old_snapshot.multitenancy))
  end

  defp indexes_match?(table, left, right) do
    left =
      left
      |> Map.update!(:fields, fn fields ->
        Enum.map(fields, &to_string/1)
      end)
      |> add_custom_index_name(table)

    right =
      right
      |> Map.update!(:fields, fn fields ->
        Enum.map(fields, &to_string/1)
      end)
      |> add_custom_index_name(table)

    left == right
  end

  defp add_custom_index_name(custom_index, table) do
    custom_index
    |> Map.put_new_lazy(:name, fn ->
      AshSqlite.CustomIndex.name(table, %{fields: custom_index.fields})
    end)
    |> Map.update!(
      :name,
      &(&1 || AshSqlite.CustomIndex.name(table, %{fields: custom_index.fields}))
    )
  end

  defp pkey_operations(snapshot, old_snapshot, attribute_operations) do
    if old_snapshot[:empty?] do
      []
    else
      must_drop_pkey? =
        Enum.any?(
          attribute_operations,
          fn
            %Operation.AlterAttribute{
              old_attribute: %{primary_key?: old_primary_key},
              new_attribute: %{primary_key?: new_primary_key}
            }
            when old_primary_key != new_primary_key ->
              true

            %Operation.AddAttribute{
              attribute: %{primary_key?: true}
            } ->
              true

            _ ->
              false
          end
        )

      if must_drop_pkey? do
        [
          %Operation.RemovePrimaryKey{table: snapshot.table},
          %Operation.RemovePrimaryKeyDown{table: snapshot.table}
        ]
      else
        []
      end
    end
  end

  defp attribute_operations(snapshot, old_snapshot, opts) do
    attributes_to_add =
      Enum.reject(snapshot.attributes, fn attribute ->
        Enum.find(old_snapshot.attributes, &(&1.source == attribute.source))
      end)

    attributes_to_remove =
      Enum.reject(old_snapshot.attributes, fn attribute ->
        Enum.find(snapshot.attributes, &(&1.source == attribute.source))
      end)

    {attributes_to_add, attributes_to_remove, attributes_to_rename} =
      resolve_renames(snapshot.table, attributes_to_add, attributes_to_remove, opts)

    attributes_to_alter =
      snapshot.attributes
      |> Enum.map(fn attribute ->
        {attribute,
         Enum.find(
           old_snapshot.attributes,
           &(&1.source == attribute.source &&
               attributes_unequal?(&1, attribute, snapshot.repo, old_snapshot, snapshot))
         )}
      end)
      |> Enum.filter(&elem(&1, 1))

    rename_attribute_events =
      Enum.map(attributes_to_rename, fn {new, old} ->
        %Operation.RenameAttribute{
          new_attribute: new,
          old_attribute: old,
          table: snapshot.table
        }
      end)

    add_attribute_events =
      Enum.flat_map(attributes_to_add, fn attribute ->
        if attribute.references do
          [
            %Operation.AddAttribute{
              attribute: attribute,
              table: snapshot.table
            },
            %Operation.DropForeignKey{
              attribute: attribute,
              table: snapshot.table,
              multitenancy: Map.get(attribute, :multitenancy),
              direction: :down
            }
          ]
        else
          [
            %Operation.AddAttribute{
              attribute: attribute,
              table: snapshot.table
            }
          ]
        end
      end)

    alter_attribute_events =
      Enum.flat_map(attributes_to_alter, fn {new_attribute, old_attribute} ->
        deferrable_ops =
          if differently_deferrable?(new_attribute, old_attribute) do
            [
              %Operation.AlterDeferrability{
                table: snapshot.table,
                references: new_attribute.references,
                direction: :up
              },
              %Operation.AlterDeferrability{
                table: snapshot.table,
                references: Map.get(old_attribute, :references),
                direction: :down
              }
            ]
          else
            []
          end

        if has_reference?(old_snapshot.multitenancy, old_attribute) and
             Map.get(old_attribute, :references) != Map.get(new_attribute, :references) do
          redo_deferrability =
            if differently_deferrable?(new_attribute, old_attribute) do
              []
            else
              [
                %Operation.AlterDeferrability{
                  table: snapshot.table,
                  references: new_attribute.references,
                  direction: :up
                }
              ]
            end

          old_and_alter =
            [
              %Operation.DropForeignKey{
                attribute: old_attribute,
                table: snapshot.table,
                multitenancy: old_snapshot.multitenancy,
                direction: :up
              },
              %Operation.AlterAttribute{
                new_attribute: new_attribute,
                old_attribute: old_attribute,
                table: snapshot.table
              }
            ] ++ redo_deferrability

          if has_reference?(snapshot.multitenancy, new_attribute) do
            reference_ops = [
              %Operation.DropForeignKey{
                attribute: new_attribute,
                table: snapshot.table,
                multitenancy: snapshot.multitenancy,
                direction: :down
              }
            ]

            old_and_alter ++
              reference_ops
          else
            old_and_alter
          end
        else
          [
            %Operation.AlterAttribute{
              new_attribute: Map.delete(new_attribute, :references),
              old_attribute: Map.delete(old_attribute, :references),
              table: snapshot.table
            }
          ]
        end
        |> Enum.concat(deferrable_ops)
      end)

    remove_attribute_events =
      Enum.map(attributes_to_remove, fn attribute ->
        %Operation.RemoveAttribute{
          attribute: attribute,
          table: snapshot.table,
          commented?: !opts.drop_columns
        }
      end)

    add_attribute_events ++
      alter_attribute_events ++ remove_attribute_events ++ rename_attribute_events
  end

  defp differently_deferrable?(%{references: %{deferrable: left}}, %{
         references: %{deferrable: right}
       })
       when left != right do
    true
  end

  defp differently_deferrable?(%{references: %{deferrable: same}}, %{
         references: %{deferrable: same}
       }) do
    false
  end

  defp differently_deferrable?(%{references: %{deferrable: left}}, _) when left != false, do: true

  defp differently_deferrable?(_, %{references: %{deferrable: right}}) when right != false,
    do: true

  defp differently_deferrable?(_, _), do: false

  # This exists to handle the fact that the remapping of the key name -> source caused attributes
  # to be considered unequal. We ignore things that only differ in that way using this function.
  defp attributes_unequal?(left, right, repo, _old_snapshot, _new_snapshot) do
    left = clean_for_equality(left, repo)

    right = clean_for_equality(right, repo)

    left != right
  end

  defp clean_for_equality(attribute, _repo) do
    cond do
      attribute[:source] ->
        Map.put(attribute, :name, attribute[:source])
        |> Map.update!(:source, &to_string/1)
        |> Map.update!(:name, &to_string/1)

      attribute[:name] ->
        attribute
        |> Map.put(:source, attribute[:name])
        |> Map.update!(:source, &to_string/1)
        |> Map.update!(:name, &to_string/1)

      true ->
        attribute
    end
    |> add_ignore()
    |> then(fn
      # only :integer cares about `destination_attribute_generated`
      # so we clean it here to avoid generating unnecessary snapshots
      # during the transitionary period of adding it
      %{type: type, references: references} = attribute
      when not is_nil(references) and type != :integer ->
        Map.update!(attribute, :references, &Map.delete(&1, :destination_attribute_generated))

      attribute ->
        attribute
    end)
  end

  defp add_ignore(%{references: references} = attribute) when is_map(references) do
    %{attribute | references: Map.put_new(references, :ignore?, false)}
  end

  defp add_ignore(attribute) do
    attribute
  end

  def changing_multitenancy_affects_identities?(snapshot, old_snapshot) do
    snapshot.multitenancy != old_snapshot.multitenancy ||
      snapshot.base_filter != old_snapshot.base_filter
  end

  def has_reference?(_multitenancy, attribute) do
    not is_nil(Map.get(attribute, :references))
  end

  def get_existing_snapshot(snapshot, opts) do
    repo_name = snapshot.repo |> Module.split() |> List.last() |> Macro.underscore()

    folder =
      opts
      |> snapshot_path(snapshot.repo)
      |> Path.join(repo_name)

    snapshot_folder = Path.join(folder, snapshot.table)

    if File.exists?(snapshot_folder) do
      snapshot_folder
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(&String.trim_trailing(&1, ".json"))
      |> Enum.map(&Integer.parse/1)
      |> Enum.filter(fn
        {_int, remaining} ->
          remaining == ""

        :error ->
          false
      end)
      |> Enum.map(&elem(&1, 0))
      |> case do
        [] ->
          get_old_snapshot(folder, snapshot)

        timestamps ->
          timestamp = Enum.max(timestamps)
          snapshot_file = Path.join(snapshot_folder, "#{timestamp}.json")

          snapshot_file
          |> File.read!()
          |> load_snapshot()
      end
    else
      get_old_snapshot(folder, snapshot)
    end
  end

  defp get_old_snapshot(folder, snapshot) do
    old_snapshot_file = Path.join(folder, "#{snapshot.table}.json")
    # This is adapter code for the old version, where migrations were stored in a flat directory
    if File.exists?(old_snapshot_file) do
      old_snapshot_file
      |> File.read!()
      |> load_snapshot()
    end
  end

  defp resolve_renames(_table, adding, [], _opts), do: {adding, [], []}

  defp resolve_renames(_table, [], removing, _opts), do: {[], removing, []}

  defp resolve_renames(table, [adding], [removing], opts) do
    if renaming_to?(table, removing.source, adding.source, opts) do
      {[], [], [{adding, removing}]}
    else
      {[adding], [removing], []}
    end
  end

  defp resolve_renames(table, adding, [removing | rest], opts) do
    {new_adding, new_removing, new_renames} =
      if renaming?(table, removing, opts) do
        new_attribute =
          if opts.no_shell? do
            raise "Unimplemented: Cannot get new_attribute without the shell!"
          else
            get_new_attribute(adding)
          end

        {adding -- [new_attribute], [], [{new_attribute, removing}]}
      else
        {adding, [removing], []}
      end

    {rest_adding, rest_removing, rest_renames} = resolve_renames(table, new_adding, rest, opts)

    {new_adding ++ rest_adding, new_removing ++ rest_removing, rest_renames ++ new_renames}
  end

  defp renaming_to?(table, removing, adding, opts) do
    if opts.no_shell? do
      raise "Unimplemented: cannot determine: Are you renaming #{table}.#{removing} to #{table}.#{adding}? without shell input"
    else
      Mix.shell().yes?("Are you renaming #{table}.#{removing} to #{table}.#{adding}?")
    end
  end

  defp renaming?(table, removing, opts) do
    if opts.dev do
      false
    else
      if opts.no_shell? do
        raise "Unimplemented: cannot determine: Are you renaming #{table}.#{removing.source}? without shell input"
      else
        Mix.shell().yes?("Are you renaming #{table}.#{removing.source}?")
      end
    end
  end

  defp get_new_attribute(adding, tries \\ 3)

  defp get_new_attribute(_adding, 0) do
    raise "Could not get matching name after 3 attempts."
  end

  defp get_new_attribute(adding, tries) do
    name =
      Mix.shell().prompt(
        "What are you renaming it to?: #{Enum.map_join(adding, ", ", & &1.source)}"
      )

    name =
      if name do
        String.trim(name)
      else
        nil
      end

    case Enum.find(adding, &(to_string(&1.source) == name)) do
      nil -> get_new_attribute(adding, tries - 1)
      new_attribute -> new_attribute
    end
  end

  defp timestamp(require_unique? \\ false) do
    # Alright, this is silly I know. But migration ids need to be unique
    # and "synthesizing" that behavior is significantly more annoying than
    # just waiting a bit, ensuring the migration versions are unique.
    if require_unique?, do: :timer.sleep(1500)
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: <<?0, ?0 + i>>
  defp pad(i), do: to_string(i)

  def get_snapshots(resource, all_resources) do
    Code.ensure_compiled!(AshSqlite.DataLayer.Info.repo(resource))

    if AshSqlite.DataLayer.Info.polymorphic?(resource) do
      all_resources
      |> Enum.flat_map(&Ash.Resource.Info.relationships/1)
      |> Enum.filter(&(&1.destination == resource))
      |> Enum.reject(&(&1.type == :belongs_to))
      |> Enum.filter(& &1.context[:data_layer][:table])
      |> Enum.uniq()
      |> Enum.map(fn relationship ->
        resource
        |> do_snapshot(relationship.context[:data_layer][:table])
        |> Map.update!(:identities, fn identities ->
          identity_index_names = AshSqlite.DataLayer.Info.identity_index_names(resource)

          Enum.map(identities, fn identity ->
            Map.put(
              identity,
              :index_name,
              identity_index_names[identity.name] ||
                "#{relationship.context[:data_layer][:table]}_#{identity.name}_index"
            )
          end)
        end)
        |> Map.update!(:attributes, fn attributes ->
          Enum.map(attributes, fn attribute ->
            destination_attribute_source =
              relationship.destination
              |> Ash.Resource.Info.attribute(relationship.destination_attribute)
              |> Map.get(:source)

            if attribute.source == destination_attribute_source do
              source_attribute =
                Ash.Resource.Info.attribute(relationship.source, relationship.source_attribute)

              Map.put(attribute, :references, %{
                destination_attribute: source_attribute.source,
                destination_attribute_default:
                  default(
                    source_attribute,
                    relationship.destination,
                    AshSqlite.DataLayer.Info.repo(relationship.destination)
                  ),
                deferrable: false,
                destination_attribute_generated: source_attribute.generated?,
                multitenancy: multitenancy(relationship.source),
                table: AshSqlite.DataLayer.Info.table(relationship.source),
                on_delete: AshSqlite.DataLayer.Info.polymorphic_on_delete(relationship.source),
                on_update: AshSqlite.DataLayer.Info.polymorphic_on_update(relationship.source),
                primary_key?: source_attribute.primary_key?,
                name:
                  AshSqlite.DataLayer.Info.polymorphic_name(relationship.source) ||
                    "#{relationship.context[:data_layer][:table]}_#{destination_attribute_source}_fkey"
              })
            else
              attribute
            end
          end)
        end)
      end)
    else
      [do_snapshot(resource, AshSqlite.DataLayer.Info.table(resource))]
    end
  end

  defp do_snapshot(resource, table) do
    snapshot = %{
      attributes: attributes(resource, table),
      identities: identities(resource),
      table: table || AshSqlite.DataLayer.Info.table(resource),
      custom_indexes: custom_indexes(resource),
      custom_statements: custom_statements(resource),
      repo: AshSqlite.DataLayer.Info.repo(resource),
      multitenancy: multitenancy(resource),
      base_filter: AshSqlite.DataLayer.Info.base_filter_sql(resource),
      has_create_action: has_create_action?(resource),
      strict?: AshSqlite.DataLayer.Info.strict?(resource)
    }

    hash =
      :sha256
      |> :crypto.hash(inspect(snapshot))
      |> Base.encode16()

    Map.put(snapshot, :hash, hash)
  end

  defp has_create_action?(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.any?(&(&1.type == :create && !&1.manual))
  end

  defp custom_indexes(resource) do
    resource
    |> AshSqlite.DataLayer.Info.custom_indexes()
    |> Enum.map(fn custom_index ->
      Map.take(custom_index, AshSqlite.CustomIndex.fields())
    end)
  end

  defp custom_statements(resource) do
    resource
    |> AshSqlite.DataLayer.Info.custom_statements()
    |> Enum.map(fn custom_statement ->
      Map.take(custom_statement, AshSqlite.Statement.fields())
    end)
  end

  defp multitenancy(resource) do
    strategy = Ash.Resource.Info.multitenancy_strategy(resource)
    attribute = Ash.Resource.Info.multitenancy_attribute(resource)
    global = Ash.Resource.Info.multitenancy_global?(resource)

    %{
      strategy: strategy,
      attribute: attribute,
      global: global
    }
  end

  defp attributes(resource, table) do
    repo = AshSqlite.DataLayer.Info.repo(resource)
    ignored = AshSqlite.DataLayer.Info.migration_ignore_attributes(resource) || []

    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(&(&1.name in ignored))
    |> Enum.map(
      &Map.take(&1, [
        :name,
        :source,
        :type,
        :default,
        :allow_nil?,
        :generated?,
        :primary_key?,
        :constraints
      ])
    )
    |> Enum.map(fn attribute ->
      default = default(attribute, resource, repo)

      type =
        AshSqlite.DataLayer.Info.migration_types(resource)[attribute.name] ||
          migration_type(attribute.type, attribute.constraints)

      type =
        if :erlang.function_exported(repo, :override_migration_type, 1) do
          repo.override_migration_type(type)
        else
          type
        end

      {type, size} =
        case type do
          {:varchar, size} ->
            {:varchar, size}

          {:binary, size} ->
            {:binary, size}

          {other, size} when is_atom(other) and is_integer(size) ->
            {other, size}

          other ->
            {other, nil}
        end

      attribute
      |> Map.put(:default, default)
      |> Map.put(:size, size)
      |> Map.put(:type, type)
      |> Map.put(:source, attribute.source || attribute.name)
      |> Map.drop([:name, :constraints])
    end)
    |> Enum.map(fn attribute ->
      references = find_reference(resource, table, attribute)

      Map.put(attribute, :references, references)
    end)
  end

  defp find_reference(resource, table, attribute) do
    Enum.find_value(Ash.Resource.Info.relationships(resource), fn relationship ->
      source_attribute_name =
        relationship.source
        |> Ash.Resource.Info.attribute(relationship.source_attribute)
        |> then(fn attribute ->
          attribute.source || attribute.name
        end)

      if attribute.source == source_attribute_name && relationship.type == :belongs_to &&
           foreign_key?(relationship) do
        configured_reference =
          configured_reference(resource, table, attribute.source || attribute.name, relationship)

        unless Map.get(configured_reference, :ignore?) do
          destination_attribute =
            Ash.Resource.Info.attribute(
              relationship.destination,
              relationship.destination_attribute
            )

          destination_attribute_source =
            destination_attribute.source || destination_attribute.name

          %{
            destination_attribute: destination_attribute_source,
            deferrable: configured_reference.deferrable,
            multitenancy: multitenancy(relationship.destination),
            on_delete: configured_reference.on_delete,
            on_update: configured_reference.on_update,
            name: configured_reference.name,
            primary_key?: destination_attribute.primary_key?,
            table:
              relationship.context[:data_layer][:table] ||
                AshSqlite.DataLayer.Info.table(relationship.destination)
          }
        end
      end
    end)
  end

  defp configured_reference(resource, table, attribute, relationship) do
    ref =
      resource
      |> AshSqlite.DataLayer.Info.references()
      |> Enum.find(&(&1.relationship == relationship.name))
      |> Kernel.||(%{
        on_delete: nil,
        on_update: nil,
        deferrable: false,
        name: nil,
        ignore?: false
      })

    ref
    |> Map.put(:name, ref.name || "#{table}_#{attribute}_fkey")
    |> Map.put(
      :primary_key?,
      Ash.Resource.Info.attribute(
        relationship.destination,
        relationship.destination_attribute
      ).primary_key?
    )
  end

  def get_migration_type(type, constraints), do: migration_type(type, constraints)

  defp migration_type({:array, type}, constraints),
    do: {:array, migration_type(type, constraints)}

  defp migration_type(Ash.Type.CiString, _), do: :citext
  defp migration_type(Ash.Type.UUID, _), do: :uuid
  defp migration_type(Ash.Type.Integer, _), do: :bigint

  defp migration_type(other, constraints) do
    type = Ash.Type.get_type(other)

    migration_type_from_storage_type(Ash.Type.storage_type(type, constraints))
  end

  defp migration_type_from_storage_type(:string), do: :text
  defp migration_type_from_storage_type(:ci_string), do: :citext
  defp migration_type_from_storage_type(storage_type), do: storage_type

  defp foreign_key?(relationship) do
    Ash.DataLayer.data_layer(relationship.source) == AshSqlite.DataLayer &&
      AshSqlite.DataLayer.Info.repo(relationship.source) ==
        AshSqlite.DataLayer.Info.repo(relationship.destination)
  end

  defp identities(resource) do
    identity_index_names = AshSqlite.DataLayer.Info.identity_index_names(resource)

    resource
    |> Ash.Resource.Info.identities()
    |> case do
      [] ->
        []

      identities ->
        base_filter = Ash.Resource.Info.base_filter(resource)

        if base_filter && !AshSqlite.DataLayer.Info.base_filter_sql(resource) do
          raise """
          Cannot create a unique index for a resource with a base filter without also configuring `base_filter_sql`.

          You must provide the `base_filter_sql` option, or skip unique indexes with `skip_unique_indexes`"
          """
        end

        identities
    end
    |> Enum.reject(fn identity ->
      identity.name in AshSqlite.DataLayer.Info.skip_unique_indexes(resource)
    end)
    |> Enum.filter(fn identity ->
      Enum.all?(identity.keys, fn key ->
        Ash.Resource.Info.attribute(resource, key)
      end)
    end)
    |> Enum.sort_by(& &1.name)
    |> Enum.map(&Map.take(&1, [:name, :keys]))
    |> Enum.map(fn %{keys: keys} = identity ->
      %{
        identity
        | keys:
            Enum.map(keys, fn key ->
              attribute = Ash.Resource.Info.attribute(resource, key)
              attribute.source || attribute.name
            end)
      }
    end)
    |> Enum.map(fn identity ->
      Map.put(
        identity,
        :index_name,
        identity_index_names[identity.name] ||
          "#{AshSqlite.DataLayer.Info.table(resource)}_#{identity.name}_index"
      )
    end)
    |> Enum.map(&Map.put(&1, :base_filter, AshSqlite.DataLayer.Info.base_filter_sql(resource)))
  end

  defp default(%{name: name, default: default}, resource, _repo) when is_function(default) do
    configured_default(resource, name) || "nil"
  end

  defp default(%{name: name, default: {_, _, _}}, resource, _),
    do: configured_default(resource, name) || "nil"

  defp default(%{name: name, default: nil}, resource, _),
    do: configured_default(resource, name) || "nil"

  defp default(%{name: name, default: []}, resource, _),
    do: configured_default(resource, name) || "[]"

  defp default(%{name: name, default: default}, resource, _) when default == %{},
    do: configured_default(resource, name) || "%{}"

  defp default(%{name: name, default: value, type: type} = attr, resource, _) do
    case configured_default(resource, name) do
      nil ->
        case migration_default(type, Map.get(attr, :constraints, []), value) do
          {:ok, default} ->
            default

          :error ->
            "nil"
        end

      default ->
        default
    end
  end

  defp migration_default(type, constraints, value) do
    type =
      type
      |> unwrap_type()
      |> Ash.Type.get_type()

    if function_exported?(type, :value_to_sqlite_default, 3) do
      type.value_to_sqlite_default(type, constraints, value)
    else
      :error
    end
  end

  defp unwrap_type({:array, type}), do: unwrap_type(type)
  defp unwrap_type(type), do: type

  defp configured_default(resource, attribute) do
    AshSqlite.DataLayer.Info.migration_defaults(resource)[attribute]
  end

  defp snapshot_to_binary(snapshot) do
    snapshot
    |> Map.update!(:attributes, fn attributes ->
      Enum.map(attributes, fn attribute ->
        %{attribute | type: sanitize_type(attribute.type, attribute[:size])}
      end)
    end)
    |> Jason.encode!(pretty: true)
  end

  defp sanitize_type({:array, type}, size) do
    ["array", sanitize_type(type, size)]
  end

  defp sanitize_type(:varchar, size) when not is_nil(size) do
    ["varchar", size]
  end

  defp sanitize_type(:binary, size) when not is_nil(size) do
    ["binary", size]
  end

  defp sanitize_type(type, size) when is_atom(type) and is_integer(size) do
    [sanitize_type(type, nil), size]
  end

  defp sanitize_type(type, _) do
    type
  end

  defp load_snapshot(json) do
    json
    |> Jason.decode!(keys: :atoms!)
    |> sanitize_snapshot()
  end

  defp sanitize_snapshot(snapshot) do
    snapshot
    |> Map.put_new(:has_create_action, true)
    |> Map.update!(:identities, fn identities ->
      Enum.map(identities, &load_identity(&1, snapshot.table))
    end)
    |> Map.update!(:attributes, fn attributes ->
      Enum.map(attributes, fn attribute ->
        attribute = load_attribute(attribute, snapshot.table)

        if is_map(Map.get(attribute, :references)) do
          %{
            attribute
            | references: rewrite(attribute.references, :ignore, :ignore?)
          }
        else
          attribute
        end
      end)
    end)
    |> Map.put_new(:custom_indexes, [])
    |> Map.update!(:custom_indexes, &load_custom_indexes/1)
    |> Map.put_new(:custom_statements, [])
    |> Map.update!(:custom_statements, &load_custom_statements/1)
    |> Map.update!(:repo, &String.to_atom/1)
    |> Map.put_new(:multitenancy, %{
      attribute: nil,
      strategy: nil,
      global: nil
    })
    |> Map.update!(:multitenancy, &load_multitenancy/1)
    |> Map.put_new(:base_filter, nil)
  end

  defp load_custom_indexes(custom_indexes) do
    Enum.map(custom_indexes || [], fn custom_index ->
      custom_index
      |> Map.put_new(:fields, [])
      |> Map.put_new(:include, [])
      |> Map.put_new(:message, nil)
    end)
  end

  defp load_custom_statements(statements) do
    Enum.map(statements || [], fn statement ->
      Map.update!(statement, :name, &String.to_atom/1)
    end)
  end

  defp load_multitenancy(multitenancy) do
    multitenancy
    |> Map.update!(:strategy, fn strategy -> strategy && String.to_atom(strategy) end)
    |> Map.update!(:attribute, fn attribute -> attribute && String.to_atom(attribute) end)
  end

  defp load_attribute(attribute, table) do
    type = load_type(attribute.type)

    {type, size} =
      case type do
        {:varchar, size} ->
          {:varchar, size}

        {:binary, size} ->
          {:binary, size}

        {other, size} when is_atom(other) and is_integer(size) ->
          {other, size}

        other ->
          {other, nil}
      end

    attribute =
      if Map.has_key?(attribute, :name) do
        Map.put(attribute, :source, String.to_atom(attribute.name))
      else
        Map.update!(attribute, :source, &String.to_atom/1)
      end

    attribute
    |> Map.put(:type, type)
    |> Map.put(:size, size)
    |> Map.put_new(:default, "nil")
    |> Map.update!(:default, &(&1 || "nil"))
    |> Map.update!(:references, fn
      nil ->
        nil

      references ->
        references
        |> rewrite(
          destination_field: :destination_attribute,
          destination_field_default: :destination_attribute_default,
          destination_field_generated: :destination_attribute_generated
        )
        |> Map.delete(:ignore)
        |> rewrite(:ignore?, :ignore)
        |> Map.update!(:destination_attribute, &String.to_atom/1)
        |> Map.put_new(:deferrable, false)
        |> Map.update!(:deferrable, fn
          "initially" -> :initially
          other -> other
        end)
        |> Map.put_new(:destination_attribute_default, "nil")
        |> Map.put_new(:destination_attribute_generated, false)
        |> Map.put_new(:on_delete, nil)
        |> Map.put_new(:on_update, nil)
        |> Map.update!(:on_delete, &(&1 && String.to_atom(&1)))
        |> Map.update!(:on_update, &(&1 && String.to_atom(&1)))
        |> Map.put(
          :name,
          Map.get(references, :name) || "#{table}_#{attribute.source}_fkey"
        )
        |> Map.put_new(:multitenancy, %{
          attribute: nil,
          strategy: nil,
          global: nil
        })
        |> Map.update!(:multitenancy, &load_multitenancy/1)
        |> sanitize_name(table)
    end)
  end

  defp rewrite(map, keys) do
    Enum.reduce(keys, map, fn {key, to}, map ->
      rewrite(map, key, to)
    end)
  end

  defp rewrite(map, key, to) do
    if Map.has_key?(map, key) do
      map
      |> Map.put(to, Map.get(map, key))
      |> Map.delete(key)
    else
      map
    end
  end

  defp sanitize_name(reference, table) do
    if String.starts_with?(reference.name, "_") do
      Map.put(reference, :name, "#{table}#{reference.name}")
    else
      reference
    end
  end

  defp load_type(["array", type]) do
    {:array, load_type(type)}
  end

  defp load_type(["varchar", size]) do
    {:varchar, size}
  end

  defp load_type(["binary", size]) do
    {:binary, size}
  end

  defp load_type([string, size]) when is_binary(string) and is_integer(size) do
    {String.to_existing_atom(string), size}
  end

  defp load_type(type) do
    String.to_atom(type)
  end

  defp load_identity(identity, table) do
    identity
    |> Map.update!(:name, &String.to_atom/1)
    |> Map.update!(:keys, fn keys ->
      keys
      |> Enum.map(&String.to_atom/1)
      |> Enum.sort()
    end)
    |> add_index_name(table)
    |> Map.put_new(:base_filter, nil)
  end

  defp add_index_name(%{name: name} = index, table) do
    Map.put_new(index, :index_name, "#{table}_#{name}_unique_index")
  end
end
