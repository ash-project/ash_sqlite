defmodule AshSqlite.TransactionTest do
  @moduledoc false
  use AshSqlite.RepoCase, async: false

  test "transactions cannot be used by default" do
    assert_raise(Spark.Error.DslError, ~r/transaction\? false/, fn ->
      defmodule ShouldNotCompileResource do
        use Ash.Resource,
          domain: AshSqlite.Test.Domain,
          data_layer: AshSqlite.DataLayer,
          validate_domain_inclusion?: false

        sqlite do
          repo AshSqlite.TestRepo
          table "should_not_compile_resource"
        end

        attributes do
          uuid_primary_key(:id)
        end

        actions do
          create :create do
            primary?(true)
            transaction?(true)
          end
        end
      end
    end)
  end

  test "transactions can be enabled however" do
    defmodule TransactionalResource do
      use Ash.Resource,
        domain: AshSqlite.Test.Domain,
        data_layer: AshSqlite.DataLayer,
        validate_domain_inclusion?: false

      sqlite do
        repo AshSqlite.TestRepo
        table "accounts"
        enable_write_transactions? true
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:is_active, :boolean, public?: true)
      end

      actions do
        create :create do
          accept([])
          primary?(true)
          transaction?(true)

          change(fn changeset, _context ->
            transaction? = AshSqlite.TestRepo.in_transaction?() |> dbg()

            changeset
            |> Ash.Changeset.change_attribute(:is_active, transaction?)
          end)
        end
      end
    end

    record =
      TransactionalResource
      |> Ash.Changeset.for_create(:create, %{})
      |> Ash.create!()

    assert record.is_active
  end
end
