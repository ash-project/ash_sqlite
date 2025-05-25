defmodule AshSqlite.TransactingRepo do
  @moduledoc false
  use AshSqlite.Repo, otp_app: :ash_sqlite, transactions_enabled?: true
end
