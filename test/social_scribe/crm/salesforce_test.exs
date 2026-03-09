defmodule SocialScribe.CRM.SalesforceTest do
  use SocialScribe.DataCase, async: true
  import Tesla.Mock
  import SocialScribe.AccountsFixtures

  alias SocialScribe.CRM.Salesforce

  setup do
    # Ensure config is set for tests (even if runtime.exs tried to override)
    Application.put_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [
      client_id: "test_client_id",
      client_secret: "test_client_secret"
    ])

    user = user_fixture()

    credential = salesforce_credential_fixture(%{
      user_id: user.id,
      token: "valid_sf_token",
      refresh_token: "valid_sf_refresh_token",
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second),
      instance_url: "https://my-salesforce-instance.com"
    })

    {:ok, credential: credential}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # search_contacts/2
  # ──────────────────────────────────────────────────────────────────────────

  describe "search_contacts/2" do
    test "successfully fetches and maps contacts to normalized keys", %{credential: credential} do
      mock_global(fn env ->
        if env.method == :get and String.contains?(env.url, "/services/data/v60.0/query") do
          json(%{
            "records" => [
              %{
                "Id" => "003123ABC",
                "FirstName" => "John",
                "LastName" => "Doe",
                "Email" => "john@example.com",
                "Title" => "Manager",
                "MailingState" => "CA",
                "Name" => "John Doe"
              }
            ]
          })
        end
      end)

      assert {:ok, [contact]} = Salesforce.search_contacts(credential, "John")

      assert contact.id == "003123ABC"
      assert contact.firstname == "John"
      assert contact.lastname == "Doe"
      assert contact.email == "john@example.com"
      assert contact.jobtitle == "Manager"
      assert contact.state == "CA"
      assert contact.display_name == "John Doe"
    end

    test "returns :api_error on non-200 response", %{credential: credential} do
      mock(fn env ->
        if env.method == :get and String.contains?(env.url, "/services/data/v60.0/query") do
          json(%{"message" => "Server Error"}, status: 500)
        end
      end)

      assert {:error, {:api_error, 500, %{"message" => "Server Error"}}} =
               Salesforce.search_contacts(credential, "Fail")
    end

    test "returns :http_error on Tesla transport failure", %{credential: credential} do
      mock(fn env ->
        if env.method == :get and String.contains?(env.url, "/services/data/v60.0/query") do
          {:error, :econnrefused}
        end
      end)

      assert {:error, {:http_error, :econnrefused}} =
               Salesforce.search_contacts(credential, "Unreachable")
    end

    test "refreshes an expired token before making the request", %{credential: credential} do
      expired_credential = %{credential |
        expires_at: DateTime.utc_now() |> DateTime.add(-100, :second)
      }

      mock_global(fn env ->
        cond do
          # Salesforce Token Refresh URL
          env.method == :post and String.contains?(env.url, "/services/oauth2/token") ->
            json(%{
              "access_token" => "refreshed_token",
              "instance_url" => "https://my-salesforce-instance.com",
              "expires_in" => 3600
            })

          # Salesforce Query URL
          env.method == :get and String.contains?(env.url, "/services/data/v60.0/query") ->
            # Verify that the refreshed token was used
            assert {"Authorization", "Bearer refreshed_token"} in env.headers
            json(%{"records" => []})

          true -> nil
        end
      end)

      assert {:ok, []} = Salesforce.search_contacts(expired_credential, "Alice")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # get_contact/2
  # ──────────────────────────────────────────────────────────────────────────

  describe "get_contact/2" do
    test "returns a successfully mapped contact", %{credential: credential} do
      mock(fn env ->
        if env.method == :get and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/003123ABC") do
          json(%{
            "Id" => "003123ABC",
            "FirstName" => "Alice",
            "LastName" => "Smith",
            "Email" => "alice@example.com",
            "Phone" => "555-0100",
            "MobilePhone" => "555-0101",
            "Title" => "Director",
            "MailingStreet" => "123 Main St",
            "MailingCity" => "San Francisco",
            "MailingState" => "CA",
            "MailingPostalCode" => "94101",
            "MailingCountry" => "USA",
            "Name" => "Alice Smith"
          })
        end
      end)

      assert {:ok, contact} = Salesforce.get_contact(credential, "003123ABC")
      assert contact.firstname == "Alice"
      assert contact.lastname == "Smith"
      assert contact.phone == "555-0100"
      assert contact.mobilephone == "555-0101"
      assert contact.jobtitle == "Director"
      assert contact.address == "123 Main St"
      assert contact.city == "San Francisco"
      assert contact.zip == "94101"
      assert contact.display_name == "Alice Smith"
    end

    test "returns :not_found on 404", %{credential: credential} do
      mock(fn env ->
        if env.method == :get and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/") do
          %Tesla.Env{status: 404, body: "Not Found"}
        end
      end)

      assert {:error, :not_found} = Salesforce.get_contact(credential, "invalid_id")
    end

    test "returns :api_error on non-200/404 status", %{credential: credential} do
      mock(fn env ->
        if env.method == :get and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/") do
          json(%{"errorCode" => "SERVER_ERROR"}, status: 503)
        end
      end)

      assert {:error, {:api_error, 503, _body}} = Salesforce.get_contact(credential, "some_id")
    end

    test "returns :http_error on transport failure", %{credential: credential} do
      mock(fn env ->
        if env.method == :get and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/") do
          {:error, :timeout}
        end
      end)

      assert {:error, {:http_error, :timeout}} = Salesforce.get_contact(credential, "some_id")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # update_contact/3
  # ──────────────────────────────────────────────────────────────────────────

  describe "update_contact/3" do
    test "correctly maps keys, strips state/country, and sends PATCH", %{credential: credential} do
      mock(fn env ->
        cond do
          env.method == :patch and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/003123ABC") ->
            body = Jason.decode!(env.body)

            refute Map.has_key?(body, "MailingState")
            refute Map.has_key?(body, "MailingCountry")
            assert body["Title"] == "VP of Sales"
            assert body["FirstName"] == "Bob"
            refute Map.has_key?(body, "website")
            refute Map.has_key?(body, "company")
            refute Map.has_key?(body, "linkedin_url")
            refute Map.has_key?(body, "twitter_handle")

            %Tesla.Env{status: 204}

          env.method == :get and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/003123ABC") ->
            json(%{
              "Id" => "003123ABC",
              "FirstName" => "Bob",
              "Title" => "VP of Sales"
            })
        end
      end)

      updates = %{
        "firstname" => "Bob",
        "jobtitle" => "VP of Sales",
        "state" => "NY",
        "country" => "USA",
        "website" => "example.com",
        "company" => "Example Corp",
        "linkedin_url" => "https://linkedin.com/in/bob",
        "twitter_handle" => "@bob"
      }

      assert {:ok, updated_contact} = Salesforce.update_contact(credential, "003123ABC", updates)
      assert updated_contact.firstname == "Bob"
      assert updated_contact.jobtitle == "VP of Sales"
    end

    test "returns :not_found when PATCH target doesn't exist", %{credential: credential} do
      mock(fn env ->
        if env.method == :patch and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/") do
          %Tesla.Env{status: 404, body: "Not Found"}
        end
      end)

      assert {:error, :not_found} = Salesforce.update_contact(credential, "ghost_id", %{"firstname" => "Bob"})
    end

    test "returns :api_error on PATCH failure", %{credential: credential} do
      mock(fn env ->
        if env.method == :patch and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/") do
          json(%{"errorCode" => "INVALID_FIELD"}, status: 400)
        end
      end)

      assert {:error, {:api_error, 400, _body}} = Salesforce.update_contact(credential, "003XYZ", %{"email" => "bad"})
    end

    test "returns :http_error on PATCH transport failure", %{credential: credential} do
      mock(fn env ->
        if env.method == :patch and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/") do
          {:error, :econnrefused}
        end
      end)

      assert {:error, {:http_error, :econnrefused}} =
               Salesforce.update_contact(credential, "003XYZ", %{"email" => "x@x.com"})
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # apply_updates/3  (previously untested)
  # ──────────────────────────────────────────────────────────────────────────

  describe "apply_updates/3" do
    test "sends only updates flagged as apply: true", %{credential: credential} do
      mock(fn env ->
        cond do
          env.method == :patch and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/003APPLY") ->
            body = Jason.decode!(env.body)
            # Only jobtitle should be in the patch body, not email (apply: false)
            assert Map.has_key?(body, "Title")
            refute Map.has_key?(body, "Email")
            %Tesla.Env{status: 204}

          env.method == :get and String.contains?(env.url, "/services/data/v60.0/sobjects/Contact/003APPLY") ->
            json(%{"Id" => "003APPLY", "FirstName" => "Test", "Title" => "CEO"})
        end
      end)

      updates_list = [
        %{field: "jobtitle", new_value: "CEO", apply: true},
        %{field: "email", new_value: "test@example.com", apply: false}
      ]

      assert {:ok, contact} = Salesforce.apply_updates(credential, "003APPLY", updates_list)
      assert contact.jobtitle == "CEO"
    end

    test "returns :no_updates when all updates are apply: false", %{credential: credential} do
      updates_list = [
        %{field: "jobtitle", new_value: "CEO", apply: false},
        %{field: "email", new_value: "test@example.com", apply: false}
      ]

      # No mock needed - no HTTP call should be made
      assert {:ok, :no_updates} = Salesforce.apply_updates(credential, "003NOOP", updates_list)
    end

    test "returns :no_updates for an empty update list", %{credential: credential} do
      assert {:ok, :no_updates} = Salesforce.apply_updates(credential, "003EMPTY", [])
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Token refresh retry on 401
  # ──────────────────────────────────────────────────────────────────────────

  describe "with_token_refresh retry on 401" do
    test "retries the API call with a refreshed token when the first call gets a 401", %{credential: credential} do
      # Track call count with Agent
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      mock(fn env ->
        cond do
          env.method == :post and String.contains?(env.url, "/services/oauth2/token") ->
            json(%{
              "access_token" => "brand_new_token",
              "instance_url" => "https://my-salesforce-instance.com"
            })

          env.method == :get and String.contains?(env.url, "/services/data/v60.0/query") ->
            count = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
            if count == 0 do
              # First call → 401 to trigger refresh
              %Tesla.Env{status: 401, body: %{"message" => "Session expired"}}
            else
              # Second call (after refresh) → success
              json(%{"records" => []})
            end

          true -> nil
        end
      end)

      assert {:ok, []} = Salesforce.search_contacts(credential, "Retry Test")
      assert Agent.get(counter, & &1) == 2
      Agent.stop(counter)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Fixture helper
  # ──────────────────────────────────────────────────────────────────────────

  defp salesforce_credential_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      provider: "salesforce",
      token: "dummy_token",
      email: "salesforce@example.com",
      uid: "sf_#{System.unique_integer()}"
    })
    |> SocialScribe.Accounts.create_user_credential()
    |> elem(1)
  end
end
