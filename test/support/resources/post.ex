# SPDX-FileCopyrightText: 2023 ash_sqlite contributors <https://github.com/ash-project/ash_sqlite/graphs/contributors>
#
# SPDX-License-Identifier: MIT

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
    defaults([:read, :update, :destroy])

    read :paginated do
      pagination(offset?: true, required?: true)
    end

    read :public do
      filter(expr(public == true))
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

    update :update_only_freds do
      change(filter(expr(title == "fred")))
    end

    update :update_stuff do
      accept([:stuff])
    end

    update :update_decimal do
      accept([:decimal])
    end

    destroy :destroy_only_freds do
      change(filter(expr(title == "fred")))
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

    has_many :posts_with_matching_title, __MODULE__ do
      public?(true)
      no_attributes?(true)
      filter(expr(title == parent(title) and id != parent(id)))
    end
  end

  validations do
    validate(attribute_does_not_equal(:title, "not allowed"))
  end

  aggregates do
    count(:count_of_comments, :comments)
    count(:count_of_popular_comments, :popular_comments)
    count(:count_of_linked_posts, :linked_posts)
    count(:count_of_comments_through_linked_posts, [:linked_posts, :comments])
    count(:count_of_liked_comments, :comments, read_action: :liked)
    count(:count_of_comment_ratings, [:comments, :ratings])
    sum(:sum_of_comment_likes, :comments, :likes)
    sum(:sum_of_comment_likes_called_match, :comments, :likes, filter: expr(title == "match"))

    sum(:sum_of_comment_likes_with_popular_ratings, :comments, :likes) do
      filter(expr(not is_nil(popular_ratings.id)))
    end

    sum(:sum_of_comment_likes_with_popular_ratings_exists, :comments, :likes) do
      filter(expr(exists(popular_ratings, score > 5)))
    end

    sum(:sum_of_linked_post_scores, :linked_posts, :score)
    avg(:avg_comment_likes, :comments, :likes)

    avg(:avg_comment_likes_with_popular_ratings, :comments, :likes) do
      filter(expr(not is_nil(popular_ratings.id)))
    end

    avg(:avg_linked_post_score, :linked_posts, :score)
    min(:min_comment_likes, :comments, :likes)
    min(:min_linked_post_score, :linked_posts, :score)
    max(:max_comment_likes, :comments, :likes)
    max(:max_linked_post_score, :linked_posts, :score)

    first :first_comment, :comments, :title do
      sort(title: :asc_nils_last)
    end

    first :first_comment_nils_first, :comments, :title do
      sort(title: :asc_nils_first)
    end

    first :first_comment_nils_first_called_stuff, :comments, :title do
      sort(title: :asc_nils_first)
      filter(expr(title == "stuff"))
    end

    first :first_comment_nils_first_include_nil, :comments, :title do
      include_nil?(true)
      sort(title: :asc_nils_first)
    end

    first :last_comment, :comments, :title do
      sort(title: :desc)
    end

    first :latest_comment_created_at, :comments, :created_at do
      sort(created_at: :desc)
    end

    first :highest_rating, [:comments, :ratings], :score do
      sort(score: :desc)
    end

    first(:author_first_name, :author, :first_name)

    first :first_linked_post_title, :linked_posts, :title do
      sort(title: :asc_nils_last)
    end

    first :first_linked_post_title_with_author, :linked_posts, :title do
      sort(title: :asc_nils_last)
      filter(expr(not is_nil(author.id)))
    end

    first :first_linked_post_title_with_author_join_filter, :linked_posts, :title do
      sort(title: :asc_nils_last)
      join_filter(:linked_posts, expr(not is_nil(author.id)))
    end

    list :comment_titles, :comments, :title do
      sort(title: :asc_nils_last)
    end

    list :comment_titles_with_nils, :comments, :title do
      sort(title: :asc_nils_last)
      include_nil?(true)
    end

    list :uniq_comment_titles, :comments, :title do
      uniq?(true)
      sort(title: :asc_nils_last)
    end

    list :comment_titles_with_5_likes, :comments, :title do
      sort(title: :asc_nils_last)
      filter(expr(likes >= 5))
    end

    list :comment_titles_with_popular_ratings, :comments, :title do
      sort(title: :asc_nils_last)
      filter(expr(not is_nil(popular_ratings.id)))
    end

    list(:comment_ids, :comments, :id)

    list :linked_post_titles, :linked_posts, :title do
      sort(title: :asc_nils_last)
    end

    list :linked_post_titles_with_author, :linked_posts, :title do
      sort(title: :asc_nils_last)
      filter(expr(not is_nil(author.id)))
    end

    list :linked_post_titles_with_author_join_filter, :linked_posts, :title do
      sort(title: :asc_nils_last)
      join_filter(:linked_posts, expr(not is_nil(author.id)))
    end

    custom(:comment_titles_joined, :comments, :string) do
      implementation({AshSqlite.Test.StringAgg, field: :title, delimiter: ","})
    end

    custom(:total_comment_likes_custom, :comments, :float) do
      implementation({AshSqlite.Test.TotalAgg, field: :likes})
    end

    custom(:comment_titles_joined_with_popular_ratings, :comments, :string) do
      filter(expr(not is_nil(popular_ratings.id)))
      implementation({AshSqlite.Test.StringAgg, field: :title, delimiter: ","})
    end

    custom(:linked_post_titles_joined, :linked_posts, :string) do
      implementation({AshSqlite.Test.StringAgg, field: :title, delimiter: ","})
    end

    count :count_of_comments_called_match, :comments do
      filter(expr(title == "match"))
    end

    count :count_of_comments_with_join_filter, :comments do
      join_filter(:comments, expr(title == "match"))
    end

    count :count_of_comments_with_related_filter, :comments do
      filter(expr(not is_nil(post.id)))
    end

    count :count_of_comments_with_related_exists_filter, :comments do
      filter(expr(exists(post, not is_nil(id))))
    end

    count :count_of_comments_with_popular_ratings, :comments do
      filter(expr(not is_nil(popular_ratings.id)))
    end

    count :count_comment_titles_with_popular_ratings, :comments do
      field(:title)
      filter(expr(not is_nil(popular_ratings.id)))
    end

    count :count_of_comments_with_aggregate_filter, :comments do
      filter(expr(count_of_ratings > 0))
    end

    count :count_of_comments_matching_post_title, :comments do
      filter(expr(title == parent(title)))
    end

    count :count_of_comments_with_parent_join_filter, :comments do
      join_filter(:comments, expr(title == parent(title)))
    end

    exists :has_comment_called_match, :comments do
      filter(expr(title == "match"))
    end

    exists :has_linked_post_called_match, :linked_posts do
      filter(expr(title == "match"))
    end

    count :count_of_linked_posts_with_join_filter, :linked_posts do
      join_filter(:linked_posts, expr(title == "match"))
    end

    count :count_of_linked_posts_with_author, :linked_posts do
      filter(expr(not is_nil(author.id)))
    end
  end

  calculations do
    calculate(:score_after_winning, :integer, expr((score || 0) + 1))
    calculate(:negative_score, :integer, expr(-score))
    calculate(:has_comments, :boolean, expr(count_of_comments > 0))

    calculate(
      :comment_likes_with_score,
      :integer,
      expr((sum_of_comment_likes || 0) + (score || 0))
    )

    calculate(
      :linked_post_score_with_score,
      :integer,
      expr((sum_of_linked_post_scores || 0) + (score || 0))
    )

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
