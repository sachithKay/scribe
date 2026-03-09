defmodule SocialScribe.CRM.Hubspot do
  @moduledoc """
  HubSpot CRM API client for contacts operations.
  Implements the SocialScribe.CRM behaviour.
  Implements automatic token refresh on 401/expired token errors.
  """

  @behaviour SocialScribe.CRM

  alias SocialScribe.Accounts
  alias SocialScribe.Accounts.UserCredential

  require Logger

  @base_url "https://api.hubapi.com"
  @hubspot_token_url "https://api.hubapi.com/oauth/v1/token"

  @impl true
  def provider_name, do: :hubspot

  @contact_properties [
    "firstname",
    "lastname",
    "email",
    "phone",
    "mobilephone",
    "company",
    "jobtitle",
    "address",
    "city",
    "state",
    "zip",
    "country",
    "website",
    "hs_linkedin_url",
    "twitterhandle"
  ]

  # --- API Client Setup ---

  defp client(access_token) do
    Tesla.client([
      {Tesla.Middleware.BaseUrl, @base_url},
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
      {Tesla.Middleware.FormUrlencoded,
       encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
      Tesla.Middleware.JSON
    ])
  end

  # --- CRM Behaviour Implementation ---

  @doc """
  Searches for contacts by query string.
  Returns up to 10 matching contacts with basic properties.
  """
  @impl true
  def search_contacts(%UserCredential{} = credential, query) when is_binary(query) do
    with_token_refresh(credential, fn cred ->
      body = %{
        query: query,
        limit: 10,
        properties: @contact_properties
      }

      case Tesla.post(client(cred.token), "/crm/v3/objects/contacts/search", body) do
        {:ok, %Tesla.Env{status: 200, body: %{"results" => results}}} ->
          contacts = Enum.map(results, &format_contact/1)
          {:ok, contacts}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Gets a single contact by ID with all properties.
  """
  @impl true
  def get_contact(%UserCredential{} = credential, contact_id) do
    with_token_refresh(credential, fn cred ->
      properties_param = Enum.join(@contact_properties, ",")
      url = "/crm/v3/objects/contacts/#{contact_id}?properties=#{properties_param}"

      case Tesla.get(client(cred.token), url) do
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
    with_token_refresh(credential, fn cred ->
      body = %{properties: updates}

      case Tesla.patch(client(cred.token), "/crm/v3/objects/contacts/#{contact_id}", body) do
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

  # --- Data Formatting ---

  defp format_contact(%{"id" => id, "properties" => properties}) do
    %{
      id: id,
      firstname: properties["firstname"],
      lastname: properties["lastname"],
      email: properties["email"],
      phone: properties["phone"],
      mobilephone: properties["mobilephone"],
      company: properties["company"],
      jobtitle: properties["jobtitle"],
      address: properties["address"],
      city: properties["city"],
      state: properties["state"],
      zip: properties["zip"],
      country: properties["country"],
      website: properties["website"],
      linkedin_url: properties["hs_linkedin_url"],
      twitter_handle: properties["twitterhandle"],
      display_name: format_display_name(properties)
    }
  end

  defp format_contact(_), do: nil

  defp format_display_name(properties) do
    firstname = properties["firstname"] || ""
    lastname = properties["lastname"] || ""
    email = properties["email"] || ""

    name = String.trim("#{firstname} #{lastname}")

    if name == "" do
      email
    else
      name
    end
  end

  # --- Token Refresh Logic ---

  defp with_token_refresh(%UserCredential{} = credential, api_call) do
    with {:ok, credential} <- ensure_valid_token(credential) do
      case api_call.(credential) do
        {:error, {:api_error, status, body}} when status in [401, 400] ->
          if is_token_error?(body) do
            Logger.info("HubSpot token expired, refreshing and retrying...")
            retry_with_fresh_token(credential, api_call)
          else
            Logger.error("HubSpot API error: #{status} - #{inspect(body)}")
            {:error, {:api_error, status, body}}
          end

        other ->
          other
      end
    end
  end

  defp retry_with_fresh_token(credential, api_call) do
    case refresh_credential(credential) do
      {:ok, refreshed_credential} ->
        case api_call.(refreshed_credential) do
          {:error, {:api_error, status, body}} ->
            Logger.error("HubSpot API error after refresh: #{status} - #{inspect(body)}")
            {:error, {:api_error, status, body}}

          {:error, {:http_error, reason}} ->
            Logger.error("HubSpot HTTP error after refresh: #{inspect(reason)}")
            {:error, {:http_error, reason}}

          success ->
            success
        end

      {:error, refresh_error} ->
        Logger.error("Failed to refresh HubSpot token: #{inspect(refresh_error)}")
        {:error, {:token_refresh_failed, refresh_error}}
    end
  end

  @doc """
  Public entry point for proactive token refresh by background workers.
  Returns `{:ok, updated_credential}` or `{:error, reason}`.
  """
  def refresh_token(credential), do: refresh_credential(credential)

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
    config = Application.get_env(:ueberauth, Ueberauth.Strategy.Hubspot.OAuth, [])
    
    body = %{
      grant_type: "refresh_token",
      client_id: config[:client_id],
      client_secret: config[:client_secret],
      refresh_token: credential.refresh_token
    }

    case Tesla.post(token_client(), @hubspot_token_url, body) do
      {:ok, %Tesla.Env{status: 200, body: response}} ->
        attrs = %{
          token: response["access_token"],
          refresh_token: response["refresh_token"],
          expires_at: DateTime.add(DateTime.utc_now(), response["expires_in"], :second)
        }

        Accounts.update_user_credential(credential, attrs)

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        {:error, {status, error_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp is_token_error?(%{"status" => "BAD_CLIENT_ID"}), do: true
  defp is_token_error?(%{"status" => "UNAUTHORIZED"}), do: true
  defp is_token_error?(%{"message" => msg}) when is_binary(msg) do
    String.contains?(String.downcase(msg), ["token", "expired", "unauthorized", "client id"])
  end
  defp is_token_error?(_), do: false
end
