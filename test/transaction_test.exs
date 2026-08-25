# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TransactionTest do
  @moduledoc """
  Write transactions are off by default, and roll back when the repo turns them on.

  `AshSqlite.Test.Account` and `AshSqlite.Test.TransactionalAccount` share the
  `accounts` table and differ only in the repo they name, which is what makes the
  pair worth testing together: the contrast is the feature.
  """
  use AshSqlite.RepoCase, async: false

  alias AshSqlite.Test.{Account, InlineFnRepoAccount, NamedFnRepoAccount, TransactionalAccount}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AshSqlite.TransactionTestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(AshSqlite.TransactionTestRepo, {:shared, self()})
    :ok
  end

  test "the flag is a repo callback, and defaults to off" do
    refute AshSqlite.TestRepo.write_transactions?()
    assert AshSqlite.TransactionTestRepo.write_transactions?()
  end

  test "transactions are off unless the repo asks for them" do
    refute Ash.DataLayer.data_layer_can?(Account, :transact)
    assert Ash.DataLayer.data_layer_can?(TransactionalAccount, :transact)
  end

  test "a functional repo is asked about :mutate" do
    assert Ash.DataLayer.data_layer_can?(NamedFnRepoAccount, :transact) ==
             AshSqlite.TestRepo.write_transactions?()
  end

  test "an inline fn repo is assumed to transact until it can be asked" do
    # Spark hoists the `fn` onto the resource, so it cannot be called while the
    # resource compiles, which is when `SetActionTransactions` asks. Saying `false`
    # there would clear `transaction?` and disable transactions for good, so the
    # compile-time answer is optimistic and the runtime one is real.
    assert Ash.Resource.Info.action(InlineFnRepoAccount, :create).transaction?
    refute Ash.DataLayer.data_layer_can?(InlineFnRepoAccount, :transact)
  end

  test "capturing a named function resolves at compile time instead" do
    refute Ash.Resource.Info.action(NamedFnRepoAccount, :create).transaction?
    refute Ash.DataLayer.data_layer_can?(NamedFnRepoAccount, :transact)
  end

  test "a mutation action reports the transaction it will actually get" do
    # Ash derives `transaction? true` on mutations, then clears it again when the
    # data layer cannot transact — neither resource says anything about it.
    refute Ash.Resource.Info.action(Account, :create).transaction?
    assert Ash.Resource.Info.action(TransactionalAccount, :create).transaction?
  end

  test "a failing multi-step action rolls back" do
    assert {:error, _} =
             TransactionalAccount
             |> Ash.Changeset.for_create(:create_then_fail, %{is_active: true})
             |> Ash.create()

    assert [] = Ash.read!(TransactionalAccount)
  end

  test "a succeeding action still commits" do
    assert {:ok, account} =
             TransactionalAccount
             |> Ash.Changeset.for_create(:create, %{is_active: true})
             |> Ash.create()

    assert [%{id: id}] = Ash.read!(TransactionalAccount)
    assert id == account.id
  end

  test "without transactions the same failure leaves the row behind" do
    assert {:error, _} =
             Account
             |> Ash.Changeset.for_create(:create, %{is_active: true})
             |> Ash.Changeset.after_action(fn _changeset, _record ->
               {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :is_active)}
             end)
             |> Ash.create()

    assert [_] = Ash.read!(Account)
  end

  test "in_transaction?/1 answers rather than raising when no repo is bound" do
    refute AshSqlite.DataLayer.in_transaction?(TransactionalAccount)
  end

  test "reports being in a transaction from inside one" do
    assert {:ok, true} =
             AshSqlite.TransactionTestRepo.transaction(fn ->
               AshSqlite.DataLayer.in_transaction?(TransactionalAccount)
             end)
  end
end
