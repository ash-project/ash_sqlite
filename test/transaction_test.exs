# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshSqlite.TransactionTest do
  @moduledoc """
  Write transactions are off by default, and roll back when turned on.

  `AshSqlite.Test.Account` and `AshSqlite.Test.TransactionalAccount` share a table
  and differ only in `write_transactions?`, which is what makes the pair worth
  testing together: the contrast is the feature.
  """
  use AshSqlite.RepoCase, async: false

  alias AshSqlite.Test.{Account, TransactionalAccount}

  require Ash.Query

  test "transactions are off unless the resource asks for them" do
    refute Ash.DataLayer.data_layer_can?(Account, :transact)
    assert Ash.DataLayer.data_layer_can?(TransactionalAccount, :transact)
  end

  test "a mutation action reports the transaction it will actually get" do
    # Ash derives `transaction? true` on mutations, then clears it on a resource
    # whose data layer cannot transact, so reflection matches runtime behaviour.
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
    # Not an endorsement, just the contrast: this is what every AshSqlite resource
    # does today, and it is why the option is worth having.
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
             AshSqlite.TestRepo.transaction(fn ->
               AshSqlite.DataLayer.in_transaction?(TransactionalAccount)
             end)
  end
end
