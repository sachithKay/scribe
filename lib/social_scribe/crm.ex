defmodule SocialScribe.CRM do
  @moduledoc """
  A generic behaviour for CRM integrations (HubSpot, Salesforce, etc.).
  """

  alias SocialScribe.Accounts.UserCredential

  @callback search_contacts(credential :: UserCredential.t(), query :: String.t()) ::
              {:ok, list(map())} | {:error, any()}

  @callback get_contact(credential :: UserCredential.t(), contact_id :: String.t()) ::
              {:ok, map()} | {:error, any()}

  @callback update_contact(
              credential :: UserCredential.t(),
              contact_id :: String.t(),
              updates :: map()
            ) ::
              {:ok, map()} | {:error, any()}

  @callback apply_updates(
              credential :: UserCredential.t(),
              contact_id :: String.t(),
              updates_list :: list(map())
            ) ::
              {:ok, map() | :no_updates} | {:error, any()}

  @callback provider_name() :: atom()

  def search_contacts(crm_module, credential, query) do
    crm_module.search_contacts(credential, query)
  end

  def get_contact(crm_module, credential, contact_id) do
    crm_module.get_contact(credential, contact_id)
  end

  def update_contact(crm_module, credential, contact_id, updates) do
    crm_module.update_contact(credential, contact_id, updates)
  end

  def apply_updates(crm_module, credential, contact_id, updates_list) do
    crm_module.apply_updates(credential, contact_id, updates_list)
  end
end
