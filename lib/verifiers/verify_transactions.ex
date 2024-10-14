defmodule AshSqlite.Verifiers.VerifyTransactions do
  @moduledoc """
  Verify that transactions are explicitly disabled for write actions when they
  are disabled in the configuration.
  """
  alias Spark.{Dsl.Verifier, Error.DslError}
  @behaviour Spark.Dsl.Verifier

  @doc false
  @impl true
  def verify(dsl) do
    can_transact? = Ash.DataLayer.data_layer_can?(dsl, :transact)

    if can_transact? do
      :ok
    else
      verify_actions(dsl)
    end
  end

  defp verify_actions(dsl) do
    dsl
    |> Ash.Resource.Info.actions()
    |> Enum.reject(&(&1.type == :read))
    |> Enum.filter(&(&1.transaction? == true))
    |> case do
      [] ->
        :ok

      [action] ->
        module = Verifier.get_persisted(dsl, :module)

        {:error,
         DslError.exception(
           module: module,
           path: [:actions, action.name],
           message: message(module, [action])
         )}

      actions ->
        module = Verifier.get_persisted(dsl, :module)

        {:error,
         DslError.exception(
           module: module,
           path: [:actions],
           message: message(module, actions)
         )}
    end
  end

  defp message(module, actions) do
    actions =
      actions
      |> Enum.map_join("\n", fn action ->
        "  - #{action.type} `#{action.name}`"
      end)

    """
    Transactions are disabled on the `#{inspect(module)}` resource.

    Because of Sqlite3's requirement that only a single write transaction be
    occurring at any one time, AshSqlite disables all write transactions by
    default.  This is to avoid database busy errors for concurrent write
    transactions.

    There are two ways to disable this error.  Set `transaction? false` on the
    following actions:

    #{actions}

    Or set `enable_write_transactions? true` in the `sqlite` DSL block of your
    resource, and carefully manage transaction concurrency.

    See the [transaction guide][1] for more information.

    [1]: https://hexdocs.pm/ash_sqlite/transactions.html
    """
  end
end
