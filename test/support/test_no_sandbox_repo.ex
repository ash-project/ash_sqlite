defmodule AshSqlite.TestNoSandboxRepo do
  @moduledoc false
  use AshSqlite.Repo,
    otp_app: :ash_sqlite

  def on_transaction_begin(data) do
    send(self(), data)
  end

  def installed_extensions do
    ["ash-functions", AshSqlite.TestCustomExtension]
  end
end
