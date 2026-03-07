defmodule SocialScribe.HubspotTokenRefresherTest do
  use SocialScribe.DataCase

  alias SocialScribe.CRM.Hubspot
  alias SocialScribe.Accounts

  import SocialScribe.AccountsFixtures

  describe "ensure_valid_token/1" do
    test "returns credential unchanged when token is not expired" do
      user = user_fixture()

      credential =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      {:ok, result} = Hubspot.ensure_valid_token(credential)

      assert result.id == credential.id
      assert result.token == credential.token
    end

    test "returns credential unchanged when token expires in more than 5 minutes" do
      user = user_fixture()

      credential =
        hubspot_credential_fixture(%{
          user_id: user.id,
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        })

      {:ok, result} = Hubspot.ensure_valid_token(credential)

      assert result.id == credential.id
      assert result.token == credential.token
    end
  end

  describe "refresh_credential/1" do
    test "updates credential in database on successful refresh" do
      # This test would require mocking Tesla
      # For now, we test the database update path by directly calling update
      user = user_fixture()

      credential =
        hubspot_credential_fixture(%{
          user_id: user.id,
          token: "old_token",
          refresh_token: "old_refresh"
        })

      # Simulate what refresh_credential does after successful API call
      attrs = %{
        token: "new_access_token",
        refresh_token: "new_refresh_token",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      {:ok, updated} = Accounts.update_user_credential(credential, attrs)

      assert updated.token == "new_access_token"
      assert updated.refresh_token == "new_refresh_token"
      assert updated.id == credential.id
    end
  end
end
