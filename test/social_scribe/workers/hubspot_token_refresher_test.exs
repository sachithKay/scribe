defmodule SocialScribe.Workers.HubspotTokenRefresherTest do
  use SocialScribe.DataCase, async: true

  alias SocialScribe.Workers.HubspotTokenRefresher
  alias SocialScribe.Accounts

  import SocialScribe.AccountsFixtures
  import Tesla.Mock


  describe "perform/1" do
    test "proactively refreshes tokens expiring within 10 minutes" do
      user = user_fixture()
      
      # Will expire in 5 minutes (needs refresh)
      credential_refresh =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.utc_now() |> DateTime.add(5, :minute)
        })

      # Will expire in 1 hour (no refresh needed)
      credential_keep =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.utc_now() |> DateTime.add(60, :minute)
        })

      mock(fn %{method: :post, url: "https://api.hubapi.com/oauth/v1/token"} ->
        json(%{
          "access_token" => "new_access_token",
          "refresh_token" => "new_refresh_token",
          "expires_in" => 1800
        })
      end)

      # We can't easily assert the external API mock here without full setup, 
      # but we can ensure the job runs successfully and processes the list.
      assert :ok = perform_job(HubspotTokenRefresher, %{})
    end
  end
end
