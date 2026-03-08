defmodule SocialScribe.Ueberauth.Strategy.LinkedIn.OAuth do
  @moduledoc """
  OAuth2 for LinkedIn.

  Note: This custom OAuth client was created to address a security flaw in the 
  default `ueberauth_linkedin` library, which hardcoded the `client_secret` 
  into GET requests (causing the requests to be blocked by modern firewalls 
  and LinkedIn's security policies). This version safely exchanges tokens
  without leaking secrets in URLs.
  """
  use OAuth2.Strategy

  @defaults [
    strategy: __MODULE__,
    site: "https://www.linkedin.com",
    authorize_url: "https://www.linkedin.com/oauth/v2/authorization",
    token_url: "https://www.linkedin.com/oauth/v2/accessToken"
  ]

  @doc """
  Construct a client for requests to LinkedIn.
  """
  def client(opts \\ []) do
    config =
      :ueberauth
      |> Application.fetch_env!(SocialScribe.Ueberauth.Strategy.LinkedIn.OAuth)
      |> check_credential(:client_id)
      |> check_credential(:client_secret)

    @defaults
    |> Keyword.merge(config)
    |> Keyword.merge(opts)
    |> OAuth2.Client.new()
    |> OAuth2.Client.put_serializer("application/json", Ueberauth.json_library())
  end

  @doc """
  Provides the authorized url for the request phase of Ueberauth.
  """
  def authorize_url!(params \\ [], opts \\ []) do
    opts
    |> client
    |> OAuth2.Client.authorize_url!(params)
  end

  # Security Fix: Don't append 'client_secret' to GET requests.
  # LinkedIn (and modern firewalls) reject GET requests with secrets in the query string.
  def get(token, url, headers \\ [], opts \\ []) do
    [token: token]
    |> client
    |> OAuth2.Client.get(url, headers, opts)
  end

  def get_token!(params \\ [], options \\ []) do
    headers = Keyword.get(options, :headers, [])
    options = Keyword.get(options, :options, [])
    client_options = Keyword.get(options, :client_options, [])
    client = OAuth2.Client.get_token!(client(client_options), params, headers, options)
    client.token
  end

  # Strategy Callbacks

  def authorize_url(client, params) do
    OAuth2.Strategy.AuthCode.authorize_url(client, params)
  end

  def get_token(client, params, headers) do
    client
    |> put_param("client_secret", client.client_secret)
    |> put_header("Accept", "application/json")
    |> OAuth2.Strategy.AuthCode.get_token(params, headers)
  end

  defp check_credential(config, key) do
    check_config_key_exists(config, key)

    case Keyword.get(config, key) do
      value when is_binary(value) ->
        config

      nil ->
        raise "#{inspect(key)} is missing or nil in config"
    end
  end

  defp check_config_key_exists(config, key) when is_list(config) do
    unless Keyword.has_key?(config, key) do
      raise "#{inspect(key)} missing from config"
    end

    config
  end

  defp check_config_key_exists(_, _) do
    raise "Config is not a keyword list"
  end
end
