# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.MigrationGeneratorTest do
  use AshSqlite.RepoCase, async: false
  @moduletag :migration
  @moduletag :tmp_dir

  import ExUnit.CaptureLog
  import AshSqlite.RebuildHelper, only: [generate: 2, generate: 3, last_migration: 1]

  setup %{tmp_dir: tmp_dir} do
    current_shell = Mix.shell()
    :ok = Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(current_shell)
    end)

    %{
      snapshot_path: Path.join(tmp_dir, "snapshots"),
      migration_path: Path.join(tmp_dir, "migrations")
    }
  end

  defmacrop defposts(mod \\ Post, do: body) do
    quote do
      Code.compiler_options(ignore_module_conflict: true)

      defmodule unquote(mod) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "posts"
          repo(AshSqlite.TestRepo)

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

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  defmacrop defresource(mod, table, do: body) do
    quote do
      Code.compiler_options(ignore_module_conflict: true)

      defmodule unquote(mod) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table unquote(table)
          repo(AshSqlite.TestRepo)
        end

        actions do
          defaults([:create, :read, :update, :destroy])
        end

        unquote(body)
      end

      Code.compiler_options(ignore_module_conflict: false)
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

  describe "creating initial snapshots" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        sqlite do
          migration_types(second_title: {:varchar, 16})
          migration_defaults(title_with_default: "\"fred\"")
        end

        identities do
          identity(:title, [:title])
          identity(:thing, [:title, :second_title])
          identity(:thing_with_source, [:title, :title_with_source])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:second_title, :string)
          attribute(:title_with_source, :string, source: :t_w_s)
          attribute(:title_with_default, :string)
          attribute(:email, Test.Support.Types.Email)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "the migration sets up resources correctly", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      # the snapshot exists and contains valid json
      assert File.read!(Path.wildcard("#{snapshot_path}/test_repo/posts/*.json"))
             |> Jason.decode!(keys: :atoms!)

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      file_contents = File.read!(file)

      # the migration creates the table
      assert file_contents =~ "create table(:posts, primary_key: false) do"

      # the migration sets up the custom_indexes
      assert file_contents =~
               ~S{create index(:posts, ["id"], name: "test_unique_index", unique: true)}

      assert file_contents =~ ~S{create index(:posts, ["id"]}

      # the migration adds the id, with its default
      assert file_contents =~
               ~S[add :id, :uuid, null: false, primary_key: true]

      # the migration adds the id, with its default
      assert file_contents =~
               ~S[add :title_with_default, :text, default: "fred"]

      # the migration adds other attributes
      assert file_contents =~ ~S[add :title, :text]

      # the migration unwraps newtypes
      assert file_contents =~ ~S[add :email, :text]

      # the migration adds custom attributes
      assert file_contents =~ ~S[add :second_title, :varchar, size: 16]

      # the migration creates unique_indexes based on the identities of the resource
      assert file_contents =~ ~S{create unique_index(:posts, [:title], name: "posts_title_index")}

      # the migration creates unique_indexes based on the identities of the resource
      assert file_contents =~
               ~S{create unique_index(:posts, [:title, :second_title], name: "posts_thing_index")}

      # the migration creates unique_indexes using the `source` on the attributes of the identity on the resource
      assert file_contents =~
               ~S{create unique_index(:posts, [:title, :t_w_s], name: "posts_thing_with_source_index")}
    end
  end

  describe "creating initial snapshots for resources with attribute multitenancy" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        sqlite do
          custom_indexes do
            index([:organization_id, :name], name: "posts_custom_tenant_index")
          end
        end

        multitenancy do
          strategy(:attribute)
          attribute(:organization_id)
        end

        identities do
          identity(:unique_name_per_org, [:organization_id, :name])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
          attribute(:organization_id, :uuid)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "identity keys that include the tenant attribute are not duplicated", %{
      migration_path: migration_path
    } do
      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      file_contents = File.read!(file)

      assert file_contents =~
               ~S{create unique_index(:posts, [:organization_id, :name], name: "posts_unique_name_per_org_index")}

      assert file_contents =~
               ~S{create index(:posts, ["organization_id", "name"], name: "posts_custom_tenant_index")}

      refute file_contents =~ ~S{:organization_id, :organization_id}
      refute file_contents =~ ~S{"organization_id", "organization_id"}
    end
  end

  describe "strict table" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        sqlite do
          strict?(true)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "creates the table with the strict option", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      # the snapshot exists and contains valid json
      assert File.read!(Path.wildcard("#{snapshot_path}/test_repo/posts/*.json"))
             |> Jason.decode!(keys: :atoms!)

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      file_contents = File.read!(file)

      # the migration creates the table
      assert file_contents =~ ~s'create table(:posts, primary_key: false, options: "STRICT") do'
    end
  end

  describe "dev migrations" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true,
        dev: true
      )

      :ok
    end

    test "running it again doesn't create a new file", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true,
        dev: true
      )

      assert [_] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")
    end
  end

  describe "creating follow up migrations" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "without change", %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")
    end

    test "when renaming an index, it is properly renamed", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        sqlite do
          identity_index_names(title: "titles_r_unique_dawg")
        end

        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      contents = File.read!(file2)

      assert contents =~
               ~S|drop_if_exists unique_index(:posts, [:title], name: "posts_title_index")|

      assert contents =~
               ~S|create unique_index(:posts, [:title], name: "titles_r_unique_dawg")|
    end

    test "when adding a field, it adds the field", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        identities do
          identity(:title, [:title])
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :name, :text, null: false]
    end

    test "when renaming a field, it asks if you are renaming it, and renames it if you are", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, true})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~ ~S[rename table(:posts), :title, to: :name]
    end

    test "when renaming a field, it asks if you are renaming it, and adds it if you aren't", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, false})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :name, :text, null: false]
    end

    test "when renaming a field, it asks which field you are renaming it to, and renames it if you are",
         %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
          attribute(:subject, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, true})
      send(self(), {:mix_shell_input, :prompt, "subject"})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      # Up migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :title, to: :subject]

      # Down migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :subject, to: :title]
    end

    test "when renaming a field, it asks which field you are renaming it to, and adds it if you arent",
         %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
          attribute(:subject, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, false})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :subject, :text, null: false]
    end

    test "when an attribute exists only on some of the resources that use the same table, it isn't marked as null: false",
         %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:example, :string, allow_nil?: false)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :example, :text] <> "\n"

      refute File.read!(file2) =~ ~S[null: false]
    end
  end

  describe "auto incrementing integer, when generated" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          attribute(:id, :integer, generated?: true, allow_nil?: false, primary_key?: true)
          attribute(:views, :integer)
        end
      end

      defdomain([Post])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "when an integer is generated and default nil, it is a bigserial", %{
      migration_path: migration_path
    } do
      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[add :id, :bigserial, null: false, primary_key: true]

      assert File.read!(file) =~
               ~S[add :views, :bigint]
    end
  end

  describe "--check option" do
    setup do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defdomain([Post])

      [domain: Domain]
    end

    test "raises an error on pending codegen", %{
      domain: domain,
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      assert_raise Ash.Error.Framework.PendingCodegen, fn ->
        AshSqlite.MigrationGenerator.generate(domain,
          snapshot_path: snapshot_path,
          migration_path: migration_path,
          check: true,
          auto_name: true
        )
      end

      refute File.exists?(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))
      refute File.exists?(Path.wildcard("#{snapshot_path}/test_repo/posts/*.json"))
    end
  end

  describe "references" do
    setup do: :ok

    test "references are inferred automatically", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:foobar, :string)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:posts, column: :id, name: "posts_post_id_fkey", type: :uuid)]
    end

    test "references are inferred automatically if the attribute has a different type", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          attribute(:id, :string, primary_key?: true, allow_nil?: false)
          attribute(:title, :string)
          attribute(:foobar, :string)
        end
      end

      defposts Post2 do
        attributes do
          attribute(:id, :string, primary_key?: true, allow_nil?: false)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post, attribute_type: :string)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:posts, column: :id, name: "posts_post_id_fkey", type: :text)]
    end

    test "when modified, the foreign key is dropped before modification", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:foobar, :string)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      defposts Post2 do
        sqlite do
          references do
            reference(:post, name: "special_post_fkey", on_delete: :delete, on_update: :update)
          end
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert file =
               "#{migration_path}/**/*_migrate_resources*.exs"
               |> Path.wildcard()
               |> Enum.sort()
               |> Enum.at(1)
               |> File.read!()

      assert file =~
               ~S[references(:posts, column: :id, name: "special_post_fkey", type: :uuid, on_delete: :delete_all, on_update: :update_all)]

      assert file =~ ~S[raise "SQLite does not support dropping foreign key constraints.]
      assert file =~ ~S[posts_post_id_fkey]

      assert [_, down_code] = String.split(file, "def down do")

      assert down_code =~ ~S[raise "SQLite does not support dropping foreign key constraints.]
      assert down_code =~ ~S[special_post_fkey]
      assert down_code =~ ~S[references(:posts]
    end

    test "dropping foreign keys raises with guidance since SQLite doesn't support it", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defposts Post2 do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Post2])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      # Modify the reference to trigger constraint modification
      defposts Post2 do
        sqlite do
          references do
            reference(:post, name: "new_post_fkey", on_delete: :delete)
          end
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file_contents = File.read!(file2)

      # Up migration should raise with helpful message
      assert file_contents =~ ~S[raise "SQLite does not support dropping foreign key constraints.]
      assert file_contents =~ ~S[posts_post_id_fkey]
      assert file_contents =~ ~S[https://www.techonthenet.com/sqlite/foreign_keys/drop.php]

      # Down migration should also raise
      [_, down_code] = String.split(file_contents, "def down do")

      assert down_code =~ ~S[raise "SQLite does not support dropping foreign key constraints.]
      assert down_code =~ ~S[new_post_fkey]
    end
  end

  describe "multitenant references" do
    setup do: :ok

    test "references to the primary key do not include the tenant attribute by default", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defresource Org, "orgs" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:id)
        end
      end

      defresource User, "users" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end
        end
      end

      defresource UserThing, "user_things" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end

          belongs_to(:user, User) do
            public?(true)
          end
        end
      end

      defdomain([Org, User, UserThing])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      contents = File.read!(file)

      assert contents =~
               ~S{references(:users, column: :id, name: "user_things_user_id_fkey", type: :uuid)}

      refute contents =~ ~S{with: [org_id: :org_id]}
    end

    test "match_tenant? includes the tenant attribute when the destination has a matching unique index",
         %{
           snapshot_path: snapshot_path,
           migration_path: migration_path
         } do
      defresource Org, "orgs" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:id)
        end
      end

      defresource User, "users" do
        sqlite do
          custom_indexes do
            index([:id, :org_id], unique: true)
          end
        end

        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end
        end
      end

      defresource UserThing, "user_things" do
        sqlite do
          references do
            reference(:user, match_tenant?: true)
          end
        end

        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end

          belongs_to(:user, User) do
            public?(true)
          end
        end
      end

      defdomain([Org, User, UserThing])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S{references(:users, column: :id, with: [org_id: :org_id], match: :full, name: "user_things_user_id_fkey", type: :uuid)}
    end

    test "match_tenant? without a matching unique index on the destination raises", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defresource Org, "orgs" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:id)
        end
      end

      defresource User, "users" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end
        end
      end

      defresource UserThing, "user_things" do
        sqlite do
          references do
            reference(:user, match_tenant?: true)
          end
        end

        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end

          belongs_to(:user, User) do
            public?(true)
          end
        end
      end

      defdomain([Org, User, UserThing])

      assert_raise RuntimeError, ~r/UNIQUE index/, fn ->
        AshSqlite.MigrationGenerator.generate(Domain,
          snapshot_path: snapshot_path,
          migration_path: migration_path,
          quiet: true,
          format: false,
          auto_name: true
        )
      end
    end

    test "references to a non-primary-key attribute include the tenant attribute when covered by an identity",
         %{
           snapshot_path: snapshot_path,
           migration_path: migration_path
         } do
      defresource Org, "orgs" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:id)
        end
      end

      defresource User, "users" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:key, :uuid, allow_nil?: false, public?: true)
        end

        identities do
          identity(:key, [:key])
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end
        end
      end

      defresource UserThing, "user_things" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end

          belongs_to(:user, User) do
            public?(true)
            destination_attribute(:key)
          end
        end
      end

      defdomain([Org, User, UserThing])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S{references(:users, column: :key, with: [org_id: :org_id], match: :full, name: "user_things_user_id_fkey", type: :uuid)}
    end

    test "references to a non-primary-key attribute raise without a covering unique index", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defresource Org, "orgs" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:id)
        end
      end

      defresource User, "users" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:key, :uuid, allow_nil?: false, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end
        end
      end

      defresource UserThing, "user_things" do
        attributes do
          uuid_primary_key(:id, writable?: true)
          attribute(:name, :string, public?: true)
        end

        multitenancy do
          strategy(:attribute)
          attribute(:org_id)
        end

        relationships do
          belongs_to(:org, Org) do
            public?(true)
          end

          belongs_to(:user, User) do
            public?(true)
            destination_attribute(:key)
          end
        end
      end

      defdomain([Org, User, UserThing])

      assert_raise RuntimeError, ~r/UNIQUE index/, fn ->
        AshSqlite.MigrationGenerator.generate(Domain,
          snapshot_path: snapshot_path,
          migration_path: migration_path,
          quiet: true,
          format: false,
          auto_name: true
        )
      end
    end
  end

  describe "polymorphic resources" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defmodule Comment do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          polymorphic?(true)
          repo(AshSqlite.TestRepo)
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:resource_id, :uuid)
        end

        actions do
          defaults([:create, :read, :update, :destroy])
        end
      end

      defmodule Post do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "posts"
          repo(AshSqlite.TestRepo)
        end

        actions do
          defaults([:create, :read, :update, :destroy])
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          has_many(:comments, Comment,
            destination_attribute: :resource_id,
            relationship_context: %{data_layer: %{table: "post_comments"}}
          )

          belongs_to(:best_comment, Comment,
            destination_attribute: :id,
            relationship_context: %{data_layer: %{table: "post_comments"}}
          )
        end
      end

      defdomain([Post, Comment])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      [domain: Domain]
    end

    test "it uses the relationship's table context if it is set", %{
      migration_path: migration_path
    } do
      assert [file] = Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:post_comments, column: :id, name: "posts_best_comment_id_fkey", type: :uuid)]
    end
  end

  describe "default values" do
    setup do: :ok

    test "when default value is specified that has no impl", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:product_code, :term, default: {"xyz"})
        end
      end

      defdomain([Post])

      capture_log(fn ->
        AshSqlite.MigrationGenerator.generate(Domain,
          snapshot_path: snapshot_path,
          migration_path: migration_path,
          quiet: true,
          format: false,
          auto_name: true
        )
      end)

      assert [file1] = Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file = File.read!(file1)

      assert file =~
               ~S[add :product_code, :binary]
    end
  end

  describe "follow up with references" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
        end
      end

      defmodule Comment do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "comments"
          repo AshSqlite.TestRepo
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Comment])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "when changing the primary key, it changes properly", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          attribute(:id, :uuid, primary_key?: false, default: &Ecto.UUID.generate/0)
          uuid_primary_key(:guid)
          attribute(:title, :string)
        end
      end

      defmodule Comment do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table "comments"
          repo AshSqlite.TestRepo
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:post, Post)
        end
      end

      defdomain([Post, Comment])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      file = File.read!(file2)

      assert [before_index_drop, after_index_drop] =
               String.split(file, ~S[drop constraint("posts", "posts_pkey")], parts: 2)

      assert before_index_drop =~
               ~S[raise "SQLite does not support dropping foreign key constraints.]

      assert before_index_drop =~ ~S[comments_post_id_fkey]

      assert after_index_drop =~ ~S[modify :id, :uuid, null: true, primary_key: false]

      assert after_index_drop =~
               ~S[modify :post_id, references(:posts, column: :id, name: "comments_post_id_fkey", type: :uuid)]
    end
  end

  describe "renaming multiple relationships" do
    setup %{snapshot_path: snapshot_path, migration_path: migration_path} do
      defposts do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:creator, AshSqlite.Test.User)
          belongs_to(:contributer, AshSqlite.Test.User)
        end
      end

      defdomain([Post, AshSqlite.Test.User])

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      :ok
    end

    test "renames columns without adding duplicate columns", %{
      snapshot_path: snapshot_path,
      migration_path: migration_path
    } do
      defposts do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:creator2, AshSqlite.Test.User)
          belongs_to(:contributer2, AshSqlite.Test.User)
        end
      end

      defdomain([Post, AshSqlite.Test.User])

      send(self(), {:mix_shell_input, :yes?, true})
      send(self(), {:mix_shell_input, :prompt, "creator2_id"})
      send(self(), {:mix_shell_input, :yes?, true})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: snapshot_path,
        migration_path: migration_path,
        quiet: true,
        format: false,
        auto_name: true
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("#{migration_path}/**/*_migrate_resources*.exs"))

      # Up migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :creator_id, to: :creator2_id]
      assert File.read!(file2) =~ ~S[rename table(:posts), :contributer_id, to: :contributer2_id]

      refute File.read!(file2) =~ ~S[alter table(:posts)]

      # Down migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :creator2_id, to: :creator_id]
      assert File.read!(file2) =~ ~S[rename table(:posts), :contributer2_id, to: :contributer_id]
    end
  end

  describe "rebuilding tables" do
    defmacrop defitem(do: body) do
      quote do
        defresource Item, "items" do
          unquote(body)
        end
      end
    end

    defmacrop defparent_and_child do
      quote do
        defresource Parent, "parents" do
          attributes do
            uuid_primary_key(:id)
          end
        end

        defresource Child, "children" do
          attributes do
            uuid_primary_key(:id)
          end

          relationships do
            belongs_to(:parent, Parent)
          end
        end
      end
    end

    # `name` was required and is now optional, which SQLite cannot do in place
    defp name_required_then_optional(ctx) do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Item])
      generate(Domain, ctx, rebuild_tables: nil)

      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      # the alias made by `defdomain` only lives in this function
      Domain
    end

    test "without the option, a change SQLite cannot make is written as it always was", ctx do
      domain = name_required_then_optional(ctx)
      generate(domain, ctx, rebuild_tables: nil, quiet: false)

      migration = last_migration(ctx)
      assert migration =~ "modify :name, :text, null: true"
      refute migration =~ "rebuild_table"
      refute migration =~ "AshSqlite.Migration"

      assert_received {:mix_shell, :info,
                       ["SQLite cannot make these changes to `items`" <> _ = hint]}

      assert hint =~ "  - modify :name, :text, null: true  (fails when the migration runs)"
      assert hint =~ "--rebuild-tables"
      assert hint =~ "rebuild_tables: true"
    end

    test "without the option, the hint's advice depends on the run", ctx do
      domain = name_required_then_optional(ctx)

      generate(domain, ctx, rebuild_tables: nil, quiet: false, dry_run: true)
      assert_received {:mix_shell, :info, ["SQLite cannot make" <> _ = hint]}
      assert hint =~ "run again with `--rebuild-tables`."

      # the dev migration may have been run: the final run takes care of it
      generate(domain, ctx, rebuild_tables: nil, quiet: false, dev: true)
      assert_received {:mix_shell, :info, ["SQLite cannot make" <> _ = hint]}
      assert hint =~ "make the final run"

      generate(domain, ctx, rebuild_tables: nil, quiet: false)
      assert_received {:mix_shell, :info, ["SQLite cannot make" <> _ = hint]}
      assert hint =~ "undo this run"
    end

    test "without the option, a dropped foreign key still raises with guidance", ctx do
      defparent_and_child()
      defdomain([Parent, Child])
      generate(Domain, ctx, rebuild_tables: nil)

      defresource Child, "children" do
        attributes do
          uuid_primary_key(:id)
          attribute(:parent_id, :uuid)
        end
      end

      defdomain([Parent, Child])
      generate(Domain, ctx, rebuild_tables: nil)

      migration = last_migration(ctx)
      assert migration =~ "SQLite does not support dropping foreign key constraints."
      refute migration =~ "rebuild_table"
    end

    test "without the option, the hint says that a new required column is refused", ctx do
      defitem do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defdomain([Item])
      generate(Domain, ctx, rebuild_tables: nil)

      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:code, :string, allow_nil?: false)
        end
      end

      generate(Domain, ctx, rebuild_tables: nil, quiet: false)

      assert_received {:mix_shell, :info,
                       ["SQLite cannot make these changes to `items`" <> _ = hint]}

      assert hint =~ "  - add :code as NOT NULL without a default, which SQLite refuses"
    end

    test "without the option, a new foreign key column says that rolling back is blocked", ctx do
      defresource Owner, "owners" do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defresource Pet, "pets" do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defdomain([Owner, Pet])
      generate(Domain, ctx, rebuild_tables: nil)

      defresource Pet, "pets" do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:owner, Owner)
        end
      end

      generate(Domain, ctx, rebuild_tables: nil, quiet: false)

      # the way up works, as it always did
      migration = last_migration(ctx)
      assert migration =~ "add :owner_id, references(:owners"
      refute migration =~ "rebuild_table"

      assert_received {:mix_shell, :info,
                       ["SQLite cannot make these changes to `pets`" <> _ = hint]}

      assert hint =~
               "  - dropping the foreign key pets_owner_id_fkey when rolling back  (fails when rolled back)"

      refute hint =~ "fails when the migration runs"
    end

    test "with the option, a new foreign key column is rebuilt, so that it can be rolled back",
         ctx do
      defresource Owner, "owners" do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defresource Pet, "pets" do
        attributes do
          uuid_primary_key(:id)
        end
      end

      defdomain([Owner, Pet])
      generate(Domain, ctx)

      defresource Pet, "pets" do
        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:owner, Owner)
        end
      end

      generate(Domain, ctx)

      [up, down] = String.split(last_migration(ctx), "def down do")
      assert up =~ "# - dropping the foreign key pets_owner_id_fkey when rolling back"
      assert up =~ "rebuild_table :pets"
      assert down =~ "rebuild_table :pets"
    end

    test "with the option, there is no hint and the table is rebuilt", ctx do
      domain = name_required_then_optional(ctx)
      generate(domain, ctx, rebuild_tables: true, quiet: false)

      refute_received {:mix_shell, :info, ["SQLite cannot make these changes" <> _]}
      assert last_migration(ctx) =~ "rebuild_table :items"
    end

    test "the copy is not written when every column is simply copied", ctx do
      domain = name_required_then_optional(ctx)
      generate(domain, ctx)

      refute last_migration(ctx) =~ "copy:"
      refute last_migration(ctx) =~ "REVIEW"
    end

    test "the copy lists only the rename", ctx do
      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:title, :string)
          attribute(:body, :string)
        end
      end

      defdomain([Item])
      generate(Domain, ctx)

      defitem do
        attributes do
          uuid_primary_key(:id)
          attribute(:subject, :string)
          attribute(:body, :string, allow_nil?: false)
        end
      end

      send(self(), {:mix_shell_input, :yes?, true})
      send(self(), {:mix_shell_input, :prompt, "subject"})
      generate(Domain, ctx)
      assert last_migration(ctx) =~ "rebuild_table :items, copy: [subject: :title] do"
    end

    test "a default fills the rows of a required column, so there is no REVIEW", ctx do
      defitem do
        sqlite do
          migration_defaults(name: "\"unnamed\"")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string)
        end
      end

      defdomain([Item])
      generate(Domain, ctx)

      defitem do
        sqlite do
          migration_defaults(name: "\"unnamed\"")
        end

        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      generate(Domain, ctx)
      refute last_migration(ctx) =~ "REVIEW"
      assert last_migration(ctx) =~ "COALESCE"
    end

    test "the comment says once that a foreign key is dropped", ctx do
      defparent_and_child()
      defdomain([Parent, Child])
      generate(Domain, ctx)

      defresource Child, "children" do
        attributes do
          uuid_primary_key(:id)
          attribute(:parent_id, :uuid)
        end
      end

      defdomain([Parent, Child])
      generate(Domain, ctx)

      [up, _down] = String.split(last_migration(ctx), "def down do")
      assert up =~ "# - dropping the foreign key children_parent_id_fkey"
      refute up =~ "modify :parent_id"
    end

    test "the comment says once that a foreign key is changed", ctx do
      defparent_and_child()
      defdomain([Parent, Child])
      generate(Domain, ctx)

      defresource Child, "children" do
        sqlite do
          references do
            reference(:parent, on_delete: :delete)
          end
        end

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          belongs_to(:parent, Parent)
        end
      end

      defdomain([Parent, Child])
      generate(Domain, ctx)

      [up, _down] = String.split(last_migration(ctx), "def down do")
      assert up =~ "# - modify :parent_id, references(:parents"
      refute up =~ "dropping the foreign key"
    end
  end
end
