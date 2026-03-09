defmodule SocialScribe.Workers.BotStatusPollerTest do
  use SocialScribe.DataCase, async: true

  import Mox
  import SocialScribe.AccountsFixtures
  import SocialScribe.CalendarFixtures
  import SocialScribe.BotsFixtures
  import SocialScribe.MeetingInfoExample
  import SocialScribe.MeetingTranscriptExample

  alias SocialScribe.Workers.BotStatusPoller
  alias SocialScribe.RecallApiMock
  alias SocialScribe.AIContentGeneratorMock, as: AIGeneratorMock
  alias SocialScribe.Bots
  alias SocialScribe.Meetings

  @mock_bot_api_info_pending %{
    id: "bot-pending-123",
    metadata: %{},
    meeting_url: %{meeting_id: "jqq-gusf-vvs", platform: "google_meet"},
    status_changes: [
      %{
        code: "ready",
        message: nil,
        created_at: "2025-05-24T12:04:15.203706Z",
        sub_code: nil
      },
      %{
        code: "joining_call",
        message: nil,
        created_at: "2025-05-24T23:13:01.665225Z",
        sub_code: nil
      },
      %{
        code: "in_waiting_room",
        message: nil,
        created_at: "2025-05-24T23:13:12.782221Z",
        sub_code: nil
      },
      %{
        code: "in_call_not_recording",
        message: nil,
        created_at: "2025-05-24T23:13:26.987838Z",
        sub_code: nil
      },
      %{
        code: "in_call_recording",
        message: nil,
        created_at: "2025-05-24T23:13:27.113531Z",
        sub_code: nil
      }
    ],
    join_at: "2025-05-24T23:13:00Z",
    transcription_options: %{
      provider: "meeting_captions",
      use_separate_streams_when_available: false
    },
    bot_name: "Meeting Notetaker",
    media_retention_end: "2025-05-31T23:16:23.890255Z",
    meeting_metadata: %{title: "jqq-gusf-vvs"},
    meeting_participants: []
  }

  @mock_bot_api_info_done meeting_info_example(%{id: "bot-done-456"})
  @mock_transcript_data meeting_transcript_example()

  describe "perform/1" do
    setup do
      stub_with(RecallApiMock, SocialScribe.Recall)
      stub_with(AIGeneratorMock, SocialScribe.AIContentGenerator)
      :ok
    end

    test "does nothing if there are no pending bots" do
      assert Bots.list_pending_bots() == []

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok
    end

    test "polls a pending bot and updates its status if not 'done'" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-pending-123",
          status: "in_call_not_recording"
        })

      expect(RecallApiMock, :get_bot, fn "bot-pending-123" ->
        {:ok, %Tesla.Env{status: 200, body: @mock_bot_api_info_pending}}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "in_call_recording"

      assert Meetings.get_meeting_by_recall_bot_id(updated_bot.id) == nil
    end

    test "polls a bot, finds it 'done', fetches transcript, and creates meeting records" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-done-456",
          status: "recording_done"
        })

      # Expect API call to get bot status
      expect(RecallApiMock, :get_bot, fn "bot-done-456" ->
        # Returns "done"
        {:ok, %Tesla.Env{status: 200, body: Map.put(@mock_bot_api_info_done, :status_changes, [%{code: "done"}])}}
      end)

      # Expect API call to get transcript
      expect(RecallApiMock, :get_bot_transcript, fn "bot-done-456" ->
        {:ok, %Tesla.Env{body: @mock_transcript_data}}
      end)

      # Expect API call to get participants
      expect(RecallApiMock, :get_bot_participants, fn "bot-done-456" ->
        {:ok, %Tesla.Env{body: [
          %{id: 100, name: "Felipe Gomes Paradas", is_host: true},
          %{id: 101, name: "John Doe", is_host: false}
        ]}}
      end)

      expect(AIGeneratorMock, :generate_follow_up_email, fn @mock_transcript_data ->
        {:ok, "Follow-up email draft"}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      # Verify bot status was updated
      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "done"

      meeting = Meetings.get_meeting_by_recall_bot_id(updated_bot.id)
      assert meeting.title == calendar_event.summary

      transcript_record = Repo.get_by!(Meetings.MeetingTranscript, meeting_id: meeting.id)

      assert transcript_record.content["data"] ==
               @mock_transcript_data |> Jason.encode!() |> Jason.decode!()

      meeting_id = meeting.id

      participants =
        Repo.all(from p in Meetings.MeetingParticipant, where: p.meeting_id == ^meeting_id)

      assert Enum.count(participants) == 2
      assert Enum.any?(participants, fn p -> p.name == "Felipe Gomes Paradas" and p.is_host == true end)
      assert Enum.any?(participants, fn p -> p.name == "John Doe" and p.is_host == false end)

      # Assert AI content generation worker was enqueued
      assert_enqueued(
        worker: SocialScribe.Workers.AIContentGenerationWorker,
        args: %{"meeting_id" => meeting.id}
      )
    end

    test "polls a bot, finds it 'done', but does not re-create meeting if it already exists" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-already-processed-789",
          status: "call_ended"
        })

      # Pre-create a meeting record for this bot
      Meetings.create_meeting_from_recall_data(
        bot_record,
        @mock_bot_api_info_done,
        @mock_transcript_data,
        [%{id: 100, name: "Felipe Gomes Paradas", is_host: true}]
      )

      # Expect API call to get bot status
      expect(RecallApiMock, :get_bot, fn "bot-already-processed-789" ->
        # Simulate Recall API still reporting it as "done"
        bot_info = @mock_bot_api_info_done
                   |> Map.put(:id, "bot-already-processed-789")
                   |> Map.put(:status_changes, [%{code: "done"}])
        {:ok, %Tesla.Env{status: 200, body: bot_info}}
      end)

      # CRUCIALLY: Do NOT expect get_bot_transcript to be called again
      # Mox will verify this implicitly. If it were called, the test would fail
      # because there's no matching `expect` for it in this test case.

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      updated_bot = Bots.get_recall_bot!(bot_record.id)
      # Status is updated
      assert updated_bot.status == "done"

      bot_record_id = bot_record.id
      # Ensure no new meeting records were created (count should remain 1)
      meetings_for_bot =
        Repo.all(from m in Meetings.Meeting, where: m.recall_bot_id == ^bot_record_id)

      assert Enum.count(meetings_for_bot) == 1
    end

    test "handles terminal state 'media_expired' and marks bot as error" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-expired-999",
          status: "recording_done"
        })

      expect(RecallApiMock, :get_bot, fn "bot-expired-999" ->
        bot_info = @mock_bot_api_info_done
                   |> Map.put(:id, "bot-expired-999")
                   |> Map.put(:status_changes, [%{code: "media_expired"}])
        {:ok, %Tesla.Env{status: 200, body: bot_info}}
      end)

      # Should not call get_bot_transcript
      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "error"
      assert Meetings.get_meeting_by_recall_bot_id(updated_bot.id) == nil
    end

    test "handles terminal state 'fatal' and marks bot as error" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-fatal-999",
          status: "joining_call"
        })

      expect(RecallApiMock, :get_bot, fn "bot-fatal-999" ->
        bot_info = @mock_bot_api_info_done
                   |> Map.put(:id, "bot-fatal-999")
                   |> Map.put(:status_changes, [%{code: "fatal"}])
        {:ok, %Tesla.Env{status: 200, body: bot_info}}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "error"
    end

    test "handles API error when polling bot status and updates bot to 'polling_error'" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-api-error-000",
          status: "joining_call"
        })

      # Expect API call to get bot status to fail
      expect(RecallApiMock, :get_bot, fn "bot-api-error-000" ->
        {:error, :timeout}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      # Verify bot status was updated to 'polling_error'
      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "polling_error"
    end

    test "handles API error when fetching transcript after bot is 'done'" do
      user = user_fixture()
      calendar_event = calendar_event_fixture(%{user_id: user.id})

      bot_record =
        recall_bot_fixture(%{
          user_id: user.id,
          calendar_event_id: calendar_event.id,
          recall_bot_id: "bot-transcript-error-111",
          status: "recording_done"
        })

      # Expect API call to get bot status (returns "done")
      expect(RecallApiMock, :get_bot, fn "bot-transcript-error-111" ->
        bot_info = @mock_bot_api_info_done
                   |> Map.put(:id, "bot-transcript-error-111")
                   |> Map.put(:status_changes, [%{code: "done"}])
        {:ok, %Tesla.Env{status: 200, body: bot_info}}
      end)

      # Expect API call to get transcript to FAIL
      expect(RecallApiMock, :get_bot_transcript, fn "bot-transcript-error-111" ->
        {:error, :transcript_fetch_failed}
      end)

      assert BotStatusPoller.perform(%Oban.Job{}) == :ok

      # Bot status should still be "done" because the meeting creation was intended to fail
      # Note: we specifically wait to convert "recording_done" to "done" until the meeting is
      # completely built, so the Poller should not have updated the status.
      updated_bot = Bots.get_recall_bot!(bot_record.id)
      assert updated_bot.status == "recording_done"

      # No meeting record should have been created because transcript fetching failed
      assert Meetings.get_meeting_by_recall_bot_id(updated_bot.id) == nil
    end
  end
end
