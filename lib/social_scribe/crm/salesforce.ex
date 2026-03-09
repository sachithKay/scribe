defmodule SocialScribe.CRM.Salesforce do
  @moduledoc """
  Salesforce CRM API client for contacts operations.
  Implements the SocialScribe.CRM behaviour.
  Uses the instance_url obtained during OAuth.
  """

  @behaviour SocialScribe.CRM

  alias SocialScribe.Accounts.UserCredential
  require Logger

  @impl true
  def provider_name, do: :salesforce

  # Default token lifetime to assume when Salesforce doesn't return expires_in
  @default_token_expiry_seconds 7200

  # Adjust properties as per standard Salesforce Contact object
  @contact_properties [
    "Id",
    "FirstName",
    "LastName",
    "Email",
    "Phone",
    "MobilePhone",
    "Title",
    "MailingStreet",
    "MailingCity",
    "MailingState",
    "MailingPostalCode",
    "MailingCountry",
    "Name"
  ]

  defp client(access_token, instance_url) do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, instance_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Bearer #{access_token}"},
         {"Content-Type", "application/json"}
       ]}
    ])
  end

  defp token_client do
    Tesla.client([
      {Tesla.Middleware.FormUrlencoded, encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
      Tesla.Middleware.JSON
    ])
  end

  @doc """
  Searches for contacts by query string using SOSL or SOQL.
  We use SOQL to find contacts matching the query by name or email.
  """
  @impl true
  def search_contacts(%UserCredential{} = credential, query) when is_binary(query) do
    with_token_refresh(credential, fn cred ->
      # Simple SOQL search using LIKE
      # Escape single quotes to prevent SOQL injection
      escaped_query = String.replace(query, "'", "\\'")
      fields = Enum.join(@contact_properties, ", ")
      soql = "SELECT #{fields} FROM Contact WHERE Name LIKE '%#{escaped_query}%' OR Email LIKE '%#{escaped_query}%' LIMIT 10"
      
      url = "/services/data/v60.0/query?q=" <> URI.encode(soql)

      case Tesla.get(client(cred.token, cred.instance_url || "https://login.salesforce.com"), url) do
        {:ok, %Tesla.Env{status: 200, body: %{"records" => records}}} ->
          contacts = Enum.map(records, &format_contact/1)
          {:ok, contacts}

        {:ok, %Tesla.Env{status: status, body: body}} ->

          {:error, {:api_error, status, body}}

        {:error, reason} ->

          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Gets a single contact by ID.
  """
  @impl true
  def get_contact(%UserCredential{} = credential, contact_id) do
    with_token_refresh(credential, fn cred ->
      fields = Enum.join(@contact_properties, ",")
      url = "/services/data/v60.0/sobjects/Contact/#{contact_id}?fields=#{fields}"

      case Tesla.get(client(cred.token, cred.instance_url || "https://login.salesforce.com"), url) do
        {:ok, %Tesla.Env{status: 200, body: body}} ->
          {:ok, format_contact(body)}

        {:ok, %Tesla.Env{status: 404, body: _body}} ->
          {:error, :not_found}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Updates a contact's properties.
  """
  @impl true
  def update_contact(%UserCredential{} = credential, contact_id, updates)
      when is_map(updates) do
    # Map from our normalized keys back to Salesforce SObject fields
    sf_updates =
      updates
      |> Enum.map(fn {k, v} ->
        sf_key =
          case to_string(k) do
            "firstname" -> "FirstName"
            "lastname" -> "LastName"
            "email" -> "Email"
            "phone" -> "Phone"
            "mobilephone" -> "MobilePhone"
            "jobtitle" -> "Title"
            "address" -> "MailingStreet"
            "city" -> "MailingCity"
            "state" -> "MailingState"
            "zip" -> "MailingPostalCode"
            "country" -> "MailingCountry"
            other -> other
          end

        {sf_key, v}
      end)
      |> Enum.into(%{})

    # Strip out fields that Salesforce Contacts strictly don't have (website/company)
    # AND strip out State/Country to avoid FIELD_INTEGRITY_EXCEPTION from Org Picklist Validation rules.
    # The safest best-practice approach for broad Integrations without Org Metadata access is to
    # omit state/country fields or require the user to manually configure state mapping.
    sf_updates_clean = Map.drop(sf_updates, [
      "website", 
      "company", 
      "linkedin_url", 
      "twitter_handle",
      "MailingState",
      "MailingCountry"
    ])

    with_token_refresh(credential, fn cred ->
      url = "/services/data/v60.0/sobjects/Contact/#{contact_id}"
      case Tesla.patch(client(cred.token, cred.instance_url || "https://login.salesforce.com"), url, sf_updates_clean) do
        {:ok, %Tesla.Env{status: status}} when status in [200, 204] ->
          # fetch again to return the full object, since patch is 204 No Content
          get_contact(credential, contact_id)

        {:ok, %Tesla.Env{status: 404, body: _body}} ->
          {:error, :not_found}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Batch updates multiple properties on a contact.
  """
  @impl true
  def apply_updates(%UserCredential{} = credential, contact_id, updates_list)
      when is_list(updates_list) do
    updates_map =
      updates_list
      |> Enum.filter(fn update -> update[:apply] == true end)
      |> Enum.reduce(%{}, fn update, acc ->
        Map.put(acc, update.field, update.new_value)
      end)

    if map_size(updates_map) > 0 do
      update_contact(credential, contact_id, updates_map)
    else
      {:ok, :no_updates}
    end
  end

  # Format a Salesforce contact response into the generic structure used by SocialScribe modals
  defp format_contact(properties) when is_map(properties) do
    %{
      id: properties["Id"],
      firstname: properties["FirstName"],
      lastname: properties["LastName"],
      email: properties["Email"],
      phone: properties["Phone"],
      mobilephone: properties["MobilePhone"],
      company: nil, # Account handles company in SF out of standard Contact
      jobtitle: properties["Title"],
      address: properties["MailingStreet"],
      city: properties["MailingCity"],
      state: properties["MailingState"],
      zip: properties["MailingPostalCode"],
      country: properties["MailingCountry"],
      website: nil, 
      linkedin_url: nil,
      twitter_handle: nil,
      display_name: properties["Name"] || "#{properties["FirstName"]} #{properties["LastName"]}"
    }
  end
  defp format_contact(_), do: nil

  # Wrapper that handles token refresh on auth errors
  defp with_token_refresh(%UserCredential{} = credential, api_call) do
    case ensure_valid_token(credential) do
      {:ok, valid_cred} ->
        case api_call.(valid_cred) do
          {:error, {:api_error, 401, _body}} ->

            retry_with_fresh_token(valid_cred, api_call)
          other ->
            other
        end
      {:error, reason} ->
        {:error, {:token_refresh_failed, reason}}
    end
  end

  defp retry_with_fresh_token(credential, api_call) do
    case refresh_credential(credential) do
      {:ok, refreshed_credential} ->
        # Retry the call
        api_call.(refreshed_credential)
      {:error, refresh_error} ->
        {:error, {:token_refresh_failed, refresh_error}}
    end
  end

  defp ensure_valid_token(credential) do
    buffer_seconds = 300
    if DateTime.compare(
         credential.expires_at,
         DateTime.add(DateTime.utc_now(), buffer_seconds, :second)
       ) == :lt do
      refresh_credential(credential)
    else
      {:ok, credential}
    end
  end

  defp refresh_credential(credential) do
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [])
    client_id = config[:client_id]
    client_secret = config[:client_secret]

    # Diagnostic: Check for missing config
    if is_nil(client_id) || is_nil(client_secret) do
      {:error, :missing_config}
    else
      # Determine the auth host. Standard is login.salesforce.com. 
      # Sandboxes and some Orgs require test.salesforce.com.
      auth_host = 
        if String.contains?(credential.instance_url || "", ["sandbox", "--"]) do
          "test.salesforce.com"
        else
          "login.salesforce.com"
        end

      body = %{
        grant_type: "refresh_token",
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: credential.refresh_token
      }

      url = "https://#{auth_host}/services/oauth2/token"

      case Tesla.post(token_client(), url, body) do
        {:ok, %Tesla.Env{status: 200, body: response}} ->
          # Use expires_in from response if available, otherwise fallback to default
          expires_in = response["expires_in"] || @default_token_expiry_seconds
          
          attrs = %{
            token: response["access_token"],
            expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second)
          }

          # The refresh_token might not be returned again via SF if existing is good
          attrs = if response["refresh_token"], do: Map.put(attrs, :refresh_token, response["refresh_token"]), else: attrs
          # Ensure instance_url is preserved
          attrs = if response["instance_url"], do: Map.put(attrs, :instance_url, response["instance_url"]), else: attrs

          SocialScribe.Accounts.update_user_credential(credential, attrs)

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
