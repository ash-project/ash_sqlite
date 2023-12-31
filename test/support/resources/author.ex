defmodule AshSqlite.Test.Author do
  @moduledoc false
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table("authors")
    repo(AshSqlite.TestRepo)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:first_name, :string)
    attribute(:last_name, :string)
    attribute(:bio, AshSqlite.Test.Bio)
    attribute(:badges, {:array, :atom})
  end

  actions do
    defaults([:create, :read, :update, :destroy])
  end

  relationships do
    has_one(:profile, AshSqlite.Test.Profile)
    has_many(:posts, AshSqlite.Test.Post)
  end

  calculations do
    calculate(:title, :string, expr(bio[:title]))
    calculate(:full_name, :string, expr(first_name <> " " <> last_name))
    # calculate(:full_name_with_nils, :string, expr(string_join([first_name, last_name], " ")))
    # calculate(:full_name_with_nils_no_joiner, :string, expr(string_join([first_name, last_name])))
    # calculate(:split_full_name, {:array, :string}, expr(string_split(full_name)))

    calculate(:first_name_or_bob, :string, expr(first_name || "bob"))
    calculate(:first_name_and_bob, :string, expr(first_name && "bob"))

    calculate(
      :conditional_full_name,
      :string,
      expr(
        if(
          is_nil(first_name) or is_nil(last_name),
          "(none)",
          first_name <> " " <> last_name
        )
      )
    )

    calculate(
      :nested_conditional,
      :string,
      expr(
        if(
          is_nil(first_name),
          "No First Name",
          if(
            is_nil(last_name),
            "No Last Name",
            first_name <> " " <> last_name
          )
        )
      )
    )

    calculate :param_full_name,
              :string,
              {AshSqlite.Test.Concat, keys: [:first_name, :last_name]} do
      argument(:separator, :string, default: " ", constraints: [allow_empty?: true, trim?: false])
    end
  end
end
