defmodule SocialScribe.Repo.Migrations.AddInstanceUrlToCredentials do
  use Ecto.Migration

  def change do
    alter table(:user_credentials) do
      add :instance_url, :string # For salesforce (salesforce enforces company specific tenant url for api calls)
    end
  end
end
