defmodule AshSqlite.MigrationGeneratorTest do
  use AshSqlite.RepoCase, async: false
  @moduletag :migration

  import ExUnit.CaptureLog

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
    setup do
      on_exit(fn ->
        File.rm_rf!("test_snapshots_path")
        File.rm_rf!("test_migration_path")
      end)

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

      Mix.shell(Mix.Shell.Process)

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      :ok
    end

    test "the migration sets up resources correctly" do
      # the snapshot exists and contains valid json
      assert File.read!(Path.wildcard("test_snapshots_path/test_repo/posts/*.json"))
             |> Jason.decode!(keys: :atoms!)

      assert [file] = Path.wildcard("test_migration_path/**/*_migrate_resources*.exs")

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

  describe "creating follow up migrations" do
    setup do
      on_exit(fn ->
        File.rm_rf!("test_snapshots_path")
        File.rm_rf!("test_migration_path")
      end)

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

      Mix.shell(Mix.Shell.Process)

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      :ok
    end

    test "when renaming an index, it is properly renamed" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[ALTER INDEX posts_title_index RENAME TO titles_r_unique_dawg]
    end

    test "when adding a field, it adds the field" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :name, :text, null: false]
    end

    test "when renaming a field, it asks if you are renaming it, and renames it if you are" do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, true})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~ ~S[rename table(:posts), :title, to: :name]
    end

    test "when renaming a field, it asks if you are renaming it, and adds it if you aren't" do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:name, :string, allow_nil?: false)
        end
      end

      defdomain([Post])

      send(self(), {:mix_shell_input, :yes?, false})

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :name, :text, null: false]
    end

    test "when renaming a field, it asks which field you are renaming it to, and renames it if you are" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      # Up migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :title, to: :subject]

      # Down migration
      assert File.read!(file2) =~ ~S[rename table(:posts), :subject, to: :title]
    end

    test "when renaming a field, it asks which field you are renaming it to, and adds it if you arent" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :subject, :text, null: false]
    end

    test "when an attribute exists only on some of the resources that use the same table, it isn't marked as null: false" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      assert File.read!(file2) =~
               ~S[add :example, :text] <> "\n"

      refute File.read!(file2) =~ ~S[null: false]
    end
  end

  describe "auto incrementing integer, when generated" do
    setup do
      on_exit(fn ->
        File.rm_rf!("test_snapshots_path")
        File.rm_rf!("test_migration_path")
      end)

      defposts do
        attributes do
          attribute(:id, :integer, generated?: true, allow_nil?: false, primary_key?: true)
          attribute(:views, :integer)
        end
      end

      defdomain([Post])

      Mix.shell(Mix.Shell.Process)

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      :ok
    end

    test "when an integer is generated and default nil, it is a bigserial" do
      assert [file] = Path.wildcard("test_migration_path/**/*_migrate_resources*.exs")

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

    test "returns code(1) if snapshots and resources don't fit", %{domain: domain} do
      assert catch_exit(
               AshSqlite.MigrationGenerator.generate(domain,
                 snapshot_path: "test_snapshot_path",
                 migration_path: "test_migration_path",
                 check: true
               )
             ) == {:shutdown, 1}

      refute File.exists?(Path.wildcard("test_migration_path2/**/*_migrate_resources*.exs"))
      refute File.exists?(Path.wildcard("test_snapshots_path2/test_repo/posts/*.json"))
    end
  end

  describe "references" do
    setup do
      on_exit(fn ->
        File.rm_rf!("test_snapshots_path")
        File.rm_rf!("test_migration_path")
      end)
    end

    test "references are inferred automatically" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [file] = Path.wildcard("test_migration_path/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:posts, column: :id, name: "posts_post_id_fkey", type: :uuid)]
    end

    test "references are inferred automatically if the attribute has a different type" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [file] = Path.wildcard("test_migration_path/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:posts, column: :id, name: "posts_post_id_fkey", type: :text)]
    end

    test "when modified, the foreign key is dropped before modification" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert file =
               "test_migration_path/**/*_migrate_resources*.exs"
               |> Path.wildcard()
               |> Enum.sort()
               |> Enum.at(1)
               |> File.read!()

      assert file =~
               ~S[references(:posts, column: :id, name: "special_post_fkey", type: :uuid, on_delete: :delete_all, on_update: :update_all)]

      assert file =~ ~S[drop constraint(:posts, "posts_post_id_fkey")]

      assert [_, down_code] = String.split(file, "def down do")

      assert [_, after_drop] =
               String.split(down_code, "drop constraint(:posts, \"special_post_fkey\")")

      assert after_drop =~ ~S[references(:posts]
    end
  end

  describe "polymorphic resources" do
    setup do
      on_exit(fn ->
        File.rm_rf!("test_snapshots_path")
        File.rm_rf!("test_migration_path")
      end)

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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      [domain: Domain]
    end

    test "it uses the relationship's table context if it is set" do
      assert [file] = Path.wildcard("test_migration_path/**/*_migrate_resources*.exs")

      assert File.read!(file) =~
               ~S[references(:post_comments, column: :id, name: "posts_best_comment_id_fkey", type: :uuid)]
    end
  end

  describe "default values" do
    setup do
      on_exit(fn ->
        File.rm_rf!("test_snapshots_path")
        File.rm_rf!("test_migration_path")
      end)
    end

    test "when default value is specified that has no impl" do
      defposts do
        attributes do
          uuid_primary_key(:id)
          attribute(:product_code, :term, default: {"xyz"})
        end
      end

      defdomain([Post])

      capture_log(fn ->
        AshSqlite.MigrationGenerator.generate(Domain,
          snapshot_path: "test_snapshots_path",
          migration_path: "test_migration_path",
          quiet: true,
          format: false
        )
      end)

      assert [file1] = Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      file = File.read!(file1)

      assert file =~
               ~S[add :product_code, :binary]
    end
  end

  describe "follow up with references" do
    setup do
      on_exit(fn ->
        File.rm_rf!("test_snapshots_path")
        File.rm_rf!("test_migration_path")
      end)

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

      Mix.shell(Mix.Shell.Process)

      AshSqlite.MigrationGenerator.generate(Domain,
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      :ok
    end

    test "when changing the primary key, it changes properly" do
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
        snapshot_path: "test_snapshots_path",
        migration_path: "test_migration_path",
        quiet: true,
        format: false
      )

      assert [_file1, file2] =
               Enum.sort(Path.wildcard("test_migration_path/**/*_migrate_resources*.exs"))

      file = File.read!(file2)

      assert [before_index_drop, after_index_drop] =
               String.split(file, ~S[drop constraint("posts", "posts_pkey")], parts: 2)

      assert before_index_drop =~ ~S[drop constraint(:comments, "comments_post_id_fkey")]

      assert after_index_drop =~ ~S[modify :id, :uuid, null: true, primary_key: false]

      assert after_index_drop =~
               ~S[modify :post_id, references(:posts, column: :id, name: "comments_post_id_fkey", type: :uuid)]
    end
  end
end
