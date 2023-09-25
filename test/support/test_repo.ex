defmodule AshSqlite.TestRepo do
  @moduledoc false
  use AshSqlite.Repo,
    otp_app: :ash_sqlite
end
