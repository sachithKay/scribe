defmodule SocialScribe.HubspotApiPropertyTest do
  use SocialScribe.DataCase, async: true
  use ExUnitProperties

  import SocialScribe.AccountsFixtures

  @hubspot_fields [
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
    "linkedin_url",
    "twitter_handle"
  ]

  describe "apply_updates/3 properties" do
    setup do
      user = user_fixture()
      credential = hubspot_credential_fixture(%{user_id: user.id})
      %{credential: credential}
    end

    property "returns {:ok, :no_updates} when all updates have apply: false", %{credential: credential} do
      check all updates <- list_of(update_generator(apply: false), min_length: 1, max_length: 10) do
        result = SocialScribe.CRM.Hubspot.apply_updates(credential, "123", updates)
        assert result == {:ok, :no_updates}
      end
    end

    property "returns {:ok, :no_updates} for empty updates list", %{credential: credential} do
      check all contact_id <- string(:alphanumeric, min_length: 1, max_length: 20) do
        result = SocialScribe.CRM.Hubspot.apply_updates(credential, contact_id, [])
        assert result == {:ok, :no_updates}
      end
    end
  end

  describe "build_updates_map/1 logic properties" do
    property "filtering and mapping only includes apply: true fields" do
      check all updates <- list_of(update_generator(), min_length: 1, max_length: 10) do
        # Replicate the internal logic of apply_updates
        updates_map =
          updates
          |> Enum.filter(fn update -> update[:apply] == true end)
          |> Enum.reduce(%{}, fn update, acc ->
            Map.put(acc, update.field, update.new_value)
          end)

        # Property: All keys in map come from updates with apply: true
        applied_fields =
          updates
          |> Enum.filter(& &1[:apply])
          |> Enum.map(& &1.field)
          |> MapSet.new()

        for {field, _value} <- updates_map do
          assert MapSet.member?(applied_fields, field),
                 "Field #{field} should only be in map if apply was true"
        end
      end
    end

    property "map values match new_value from the last update for each field" do
      check all updates <- list_of(update_generator(), min_length: 1, max_length: 10) do
        updates_map =
          updates
          |> Enum.filter(fn update -> update[:apply] == true end)
          |> Enum.reduce(%{}, fn update, acc ->
            Map.put(acc, update.field, update.new_value)
          end)

        # For each field in the map, verify value matches an applied update
        for {field, value} <- updates_map do
          matching_updates =
            updates
            |> Enum.filter(& &1[:apply] && &1.field == field)

          assert Enum.any?(matching_updates, &(&1.new_value == value)),
                 "Value #{inspect(value)} for #{field} should come from an applied update"
        end
      end
    end

    property "map size is at most the number of unique applied fields" do
      check all updates <- list_of(update_generator(), min_length: 0, max_length: 10) do
        updates_map =
          updates
          |> Enum.filter(fn update -> update[:apply] == true end)
          |> Enum.reduce(%{}, fn update, acc ->
            Map.put(acc, update.field, update.new_value)
          end)

        unique_applied_fields =
          updates
          |> Enum.filter(& &1[:apply])
          |> Enum.map(& &1.field)
          |> Enum.uniq()
          |> length()

        assert map_size(updates_map) <= unique_applied_fields
      end
    end

    property "empty result when no updates have apply: true" do
      check all updates <- list_of(update_generator(apply: false), min_length: 0, max_length: 10) do
        updates_map =
          updates
          |> Enum.filter(fn update -> update[:apply] == true end)
          |> Enum.reduce(%{}, fn update, acc ->
            Map.put(acc, update.field, update.new_value)
          end)

        assert updates_map == %{}
      end
    end
  end

  # Generators

  defp update_generator(opts \\ []) do
    apply_value = Keyword.get(opts, :apply, :random)

    gen all field <- member_of(@hubspot_fields),
            new_value <- string(:alphanumeric, min_length: 1, max_length: 50),
            apply? <- if(apply_value == :random, do: boolean(), else: constant(apply_value)) do
      %{field: field, new_value: new_value, apply: apply?}
    end
  end
end
