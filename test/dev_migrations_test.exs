# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs.contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.DevMigrationsTest do
  use AshSqlite.RepoCase, async: false
  @moduletag :migration
  @moduletag :tmp_dir

  alias Ecto.Adapters.SQL.Sandbox

  setup %{tmp_dir: tmp_dir} do
    current_shell = Mix.shell()

    :ok = Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(current_shell)
    end)

    Sandbox.checkout(AshSqlite.DevTestRepo)
    Sandbox.mode(AshSqlite.DevTestRepo, {:shared, self()})

    %{
      snapshot_path: Path.join(tmp_dir, "snapshots"),
      migration_path: Path.join(tmp_dir, "migrations")
    }
  end

  defmacrop defresource(mod, do: body) do
    quote do
      Code.compiler_options(ignore_module_conflict: true)

      defmodule unquote(mod) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        unquote(body)
      end

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  defmacrop defposts(do: body) do
    quote do
      defresource Post do
        sqlite do
          table "posts"
          repo(AshSqlite.DevTestRepo)

          custom_indexes do
            # need one without any opts
            index(["id"])
            index(["id"], unique: true, name: "test_unique_index")
          end
        end

        actions do
          defaults([:create, :read, :update, :destroy])
        end

        unquote(body)
      end
    end
  end

  defmacrop defdomain(resources) do
    quote do
      Code.compiler_options(ignore_module_conflict: true)

      defmodule Domain do
        use Ash.Domain

        resources do
          for resource <- unquote(resources) do
            resource(resource)
          end
        end
      end

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  setup do
    File.mkdir_p!("priv/dev_test_repo/migrations")
    resource_dev_path = "priv/resource_snapshots/dev_test_repo"

    initial_resource_files =
      if File.exists?(resource_dev_path), do: File.ls!(resource_dev_path), else: []

    migrations_dev_path = "priv/dev_test_repo/migrations"

    initial_migration_files =
      if File.exists?(migrations_dev_path), do: File.ls!(migrations_dev_path), else: []

    on_exit(fn ->
      if File.exists?(resource_dev_path) do
        current_resource_files = File.ls!(resource_dev_path)
        new_resource_files = current_resource_files -- initial_resource_files
        Enum.each(new_resource_files, &File.rm_rf!(Path.join(resource_dev_path, &1)))
      end

      if File.exists?(migrations_dev_path) do
        current_migration_files = File.ls!(migrations_dev_path)
        new_migration_files = current_migration_files -- initial_migration_files
        Enum.each(new_migration_files, &File.rm!(Path.join(migrations_dev_path, &1)))
      end

      try do
        AshSqlite.DevTestRepo.query!("DROP TABLE IF EXISTS posts")
      catch
        _, _ -> :ok
      end
    end)
  end

  describe "--dev option" do
    test "generates dev migration", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, public?: true)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        dev: true
      )

      assert [dev_file] =
               Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert String.contains?(dev_file, "_dev.exs")
      contents = File.read!(dev_file)

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        auto_name: true
      )

      assert [file] =
               Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      refute String.contains?(file, "_dev.exs")

      assert contents == File.read!(file)
    end

    test "removes dev migrations when generating regular migrations", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, public?: true)
        end
      end

      defdomain([Post])

      # Generate dev migration first
      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        dev: true
      )

      assert [dev_file] =
               Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert String.contains?(dev_file, "_dev.exs")

      # Generate regular migration - should remove dev migration
      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        auto_name: true
      )

      # Should only have regular migration now
      files = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")
      assert length(files) == 1
      assert [regular_file] = files
      refute String.contains?(regular_file, "_dev.exs")
    end

    test "requires name when not using dev option", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string, public?: true)
        end
      end

      defdomain([Post])

      assert_raise RuntimeError, ~r/Name must be provided/, fn ->
        AshSqlite.MigrationGenerator.generate(Domain,
          snapshot_path: snapshot_path,
          migration_path: migration_path
        )
      end
    end
  end
end
