defmodule AshSqlite.Test.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshSqlite.Test.Domain,
    data_layer: AshSqlite.DataLayer,
    authorizers: [
      Ash.Policy.Authorizer
    ]

  policies do
    bypass action_type(:read) do
      # Check that the post is in the same org as actor
      authorize_if(relates_to_actor_via([:organization, :users]))
    end
  end

  sqlite do
    table("posts")
    repo(AshSqlite.TestRepo)
    base_filter_sql("type = 'sponsored'")

    custom_indexes do
      index([:uniq_custom_one, :uniq_custom_two],
        unique: true,
        message: "dude what the heck"
      )
    end
  end

  resource do
    base_filter(expr(type == type(:sponsored, ^Ash.Type.Atom)))
  end

  actions do
    default_accept(:*)
    defaults([:update, :destroy])

    read :read do
      primary?(true)
    end

    read :paginated do
      pagination(offset?: true, required?: true)
    end

    create :create do
      primary?(true)
      argument(:rating, :map)

      change(
        manage_relationship(:rating, :ratings,
          on_missing: :ignore,
          on_no_match: :create,
          on_match: :create
        )
      )
    end

    update :increment_score do
      argument(:amount, :integer, default: 1)
      change(atomic_update(:score, expr((score || 0) + ^arg(:amount))))
    end
  end

  identities do
    identity(:uniq_one_and_two, [:uniq_one, :uniq_two])
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:title, :string, public?: true)
    attribute(:score, :integer, public?: true)
    attribute(:public, :boolean, public?: true)
    attribute(:category, :ci_string, public?: true)
    attribute(:type, :atom, default: :sponsored, writable?: false)
    attribute(:price, :integer, public?: true)
    attribute(:decimal, :decimal, default: Decimal.new(0), public?: true)
    attribute(:status, AshSqlite.Test.Types.Status, public?: true)
    attribute(:status_enum, AshSqlite.Test.Types.StatusEnum, public?: true)

    attribute(:status_enum_no_cast, AshSqlite.Test.Types.StatusEnumNoCast,
      source: :status_enum,
      public?: true
    )

    attribute(:stuff, :map, public?: true)
    attribute(:uniq_one, :string, public?: true)
    attribute(:uniq_two, :string, public?: true)
    attribute(:uniq_custom_one, :string, public?: true)
    attribute(:uniq_custom_two, :string, public?: true)
    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  code_interface do
    define(:get_by_id, action: :read, get_by: [:id])
    define(:increment_score, args: [{:optional, :amount}])
  end

  relationships do
    belongs_to :organization, AshSqlite.Test.Organization do
      public?(true)
      attribute_writable?(true)
    end

    belongs_to(:author, AshSqlite.Test.Author, public?: true)

    has_many(:comments, AshSqlite.Test.Comment, destination_attribute: :post_id, public?: true)

    has_many :comments_matching_post_title, AshSqlite.Test.Comment do
      public?(true)
      filter(expr(title == parent_expr(title)))
    end

    has_many :popular_comments, AshSqlite.Test.Comment do
      public?(true)
      destination_attribute(:post_id)
      filter(expr(likes > 10))
    end

    has_many :comments_containing_title, AshSqlite.Test.Comment do
      public?(true)
      manual(AshSqlite.Test.Post.CommentsContainingTitle)
    end

    has_many(:ratings, AshSqlite.Test.Rating,
      public?: true,
      destination_attribute: :resource_id,
      relationship_context: %{data_layer: %{table: "post_ratings"}}
    )

    has_many(:post_links, AshSqlite.Test.PostLink,
      public?: true,
      destination_attribute: :source_post_id,
      filter: [state: :active]
    )

    many_to_many(:linked_posts, __MODULE__,
      public?: true,
      through: AshSqlite.Test.PostLink,
      join_relationship: :post_links,
      source_attribute_on_join_resource: :source_post_id,
      destination_attribute_on_join_resource: :destination_post_id
    )

    has_many(:views, AshSqlite.Test.PostView, public?: true)
  end

  validations do
    validate(attribute_does_not_equal(:title, "not allowed"))
  end

  calculations do
    calculate(:score_after_winning, :integer, expr((score || 0) + 1))
    calculate(:negative_score, :integer, expr(-score))
    calculate(:category_label, :string, expr("(" <> category <> ")"))
    calculate(:score_with_score, :string, expr(score <> score))
    calculate(:foo_bar_from_stuff, :string, expr(stuff[:foo][:bar]))

    calculate(
      :score_map,
      :map,
      expr(%{
        negative_score: %{foo: negative_score, bar: negative_score}
      })
    )

    calculate(
      :calc_returning_json,
      AshSqlite.Test.Money,
      expr(
        fragment("""
        '{"amount":100, "currency": "usd"}'
        """)
      )
    )

    calculate(
      :was_created_in_the_last_month,
      :boolean,
      expr(
        # This is written in a silly way on purpose, to test a regression
        if(
          fragment("(? <= (DATE(? - '+1 month')))", now(), created_at),
          true,
          false
        )
      )
    )

    calculate(
      :price_string,
      :string,
      CalculatePostPriceString
    )

    calculate(
      :price_string_with_currency_sign,
      :string,
      CalculatePostPriceStringWithSymbol
    )
  end
end

defmodule CalculatePostPriceString do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_, _, _), do: [:price]

  @impl true
  def calculate(records, _, _) do
    Enum.map(records, fn %{price: price} ->
      dollars = div(price, 100)
      cents = rem(price, 100)
      "#{dollars}.#{cents}"
    end)
  end
end

defmodule CalculatePostPriceStringWithSymbol do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_, _, _), do: [:price_string]

  @impl true
  def calculate(records, _, _) do
    Enum.map(records, fn %{price_string: price_string} ->
      "#{price_string}$"
    end)
  end
end
