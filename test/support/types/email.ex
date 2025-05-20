defmodule Test.Support.Types.Email do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :string
end
