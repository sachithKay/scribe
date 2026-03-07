defmodule SocialScribe.Accounts.UserCredential do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_credentials" do
    field :token, :string
    field :uid, :string
    field :provider, :string
    field :refresh_token, :string
    field :expires_at, :utc_datetime
    field :email, :string
    field :instance_url, :string # For salesforce (salesforce enforces company specific tenant url for api calls)

    belongs_to :user, SocialScribe.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user_credential, attrs) do
    user_credential
    |> cast(attrs, [:provider, :uid, :token, :refresh_token, :expires_at, :user_id, :email, :instance_url])
    |> validate_required([:provider, :uid, :token, :expires_at, :user_id, :email])
  end

  def linkedin_changeset(user_credential, attrs) do
    user_credential
    |> cast(attrs, [:provider, :uid, :token, :refresh_token, :expires_at, :user_id, :email])
    |> validate_required([:provider, :uid, :token, :expires_at, :user_id, :email])
  end
end
