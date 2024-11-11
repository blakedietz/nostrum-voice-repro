defmodule App.Nostrum.Consumer do
  use Nostrum.Consumer

  alias Nostrum.Api
  alias Nostrum.Cache.GuildCache
  alias Nostrum.Voice
  alias Nostrum.Struct.Event.VoiceReady

  require Logger

  # Soundcloud link will be fed through youtube-dl
  @soundcloud_url "https://soundcloud.com/fyre-brand/level-up"
  # Audio file will be fed directly to ffmpeg
  @nut_file_url "https://brandthill.com/files/nut.wav"

  # Compile-time helper for defining Discord Application Command options
  opt = fn type, name, desc, opts ->
    %{type: type, name: name, description: desc}
    |> Map.merge(Enum.into(opts, %{}))
  end

  @play_opts [
    opt.(1, "song", "Play a song", []),
    opt.(1, "example", "Play a nut sound", []),
    opt.(1, "file", "Play a file", options: [opt.(3, "url", "File URL to play", required: true)]),
    opt.(1, "url", "Play a URL from a common service",
      options: [opt.(3, "url", "URL to play", required: true)]
    )
  ]

  @commands [
    {"summon", "Summon bot to your voice channel", []},
    {"leave", "Tell bot to leave your voice channel", []},
    {"play", "Play a sound", @play_opts},
    {"stop", "Stop the playing sound", []},
    {"pause", "Pause the playing sound", []},
    {"resume", "Resume the paused sound", []}
  ]

  def get_voice_channel_of_interaction(%{guild_id: guild_id, user: %{id: user_id}} = _interaction) do
    Logger.info("Getting voice channel for user #{user_id} in guild #{guild_id}")

    case Api.get_user!(user_id) do
      {:ok, user} ->
        Logger.info("Found user: #{inspect(user)}")

      error ->
        Logger.error("Failed to get user: #{inspect(error)}")
    end

    case GuildCache.get!(guild_id) do
      nil ->
        Logger.error("Failed to get guild from cache")
        nil

      guild ->
        Logger.info("Found guild in cache")

        voice_state =
          guild
          |> Map.get(:voice_states)
          |> Enum.find(%{}, fn v -> v.user_id == user_id end)

        Logger.info("Voice state found: #{inspect(voice_state)}")
        Map.get(voice_state, :channel_id)
    end
  end

  def create_guild_commands(guild_id) do
    Logger.info("Creating guild commands for guild #{guild_id}")

    Enum.each(@commands, fn {name, description, options} ->
      Api.create_guild_application_command(guild_id, %{
        name: name,
        description: description,
        options: options
      })
    end)
  end

  def handle_event({:READY, %{guilds: guilds} = _event, _ws_state}) do
    Logger.info("Bot ready, creating guild commands")

    guilds
    |> Enum.map(fn guild -> guild.id end)
    |> Enum.each(&create_guild_commands/1)
  end

  def handle_event({:INTERACTION_CREATE, interaction, _ws_state}) do
    Logger.info("Handling interaction: #{inspect(interaction.data.name)}")

    message =
      case do_command(interaction) do
        {:msg, msg} -> msg
        _ -> ":white_check_mark:"
      end

    Api.create_interaction_response(interaction, %{type: 4, data: %{content: message}})
  end

  def handle_event({:VOICE_READY, %VoiceReady{guild_id: guild_id} = _event, _v_ws_state}) do
    Voice.play(guild_id, "~/Downloads/music-too-loud.mp3", :url, volume: 10)
  end

  def handle_event({:VOICE_SPEAKING_UPDATE, payload, _ws_state}) do
    Logger.debug("VOICE SPEAKING UPDATE #{inspect(payload)}")
  end

  def handle_event({:VOICE_STATE_UPDATE, payload, _ws_state}) do
    Logger.debug("VOICE STATE UPDATE #{inspect(payload)}")
    :noop
  end

  def handle_event(_event) do
    :noop
  end

  def do_command(%{guild_id: guild_id, data: %{name: "summon"}} = interaction) do
    Logger.info("Handling summon command for guild #{guild_id}")

    case get_voice_channel_of_interaction(interaction) do
      nil ->
        Logger.warn("No voice channel found for user")
        {:msg, "You must be in a voice channel to summon me"}

      voice_channel_id ->
        Logger.info("Joining voice channel #{voice_channel_id}")

        case Voice.join_channel(guild_id, voice_channel_id) do
          :ok ->
            Logger.info("Successfully joined voice channel.")
            # Give more time for connection to stabilize
            Process.sleep(2000)
            {:msg, "Joined voice channel!"}

          error ->
            Logger.error("Failed to join: #{inspect(error)}")
            {:msg, "Failed to join voice channel"}
        end
    end
  end

  def do_command(%{guild_id: guild_id, data: %{name: "leave"}}) do
    Logger.info("Leaving voice channel in guild #{guild_id}")
    Voice.leave_channel(guild_id)
    {:msg, "See you later :wave:"}
  end

  def do_command(%{guild_id: guild_id, data: %{name: "pause"}}) do
    Logger.info("Pausing audio in guild #{guild_id}")
    Voice.pause(guild_id)
  end

  def do_command(%{guild_id: guild_id, data: %{name: "resume"}}) do
    Logger.info("Resuming audio in guild #{guild_id}")
    Voice.resume(guild_id)
  end

  def do_command(%{guild_id: guild_id, data: %{name: "stop"}}) do
    Logger.info("Stopping audio in guild #{guild_id}")
    Voice.stop(guild_id)
  end

  def do_command(%{guild_id: guild_id, data: %{name: "play", options: options}}) do
    Logger.info("Handling play command for guild #{guild_id}")
    Logger.info("Checking voice readiness for guild #{guild_id}")

    if Voice.ready?(guild_id) do
      Logger.info("Voice is ready for guild #{guild_id}")

      case options do
        [%{name: "song"}] ->
          Logger.info("Playing song from Soundcloud")
          Voice.play(guild_id, @soundcloud_url, :ytdl)

        [%{name: "example"}] ->
          file_path = :code.priv_dir(:app) |> Path.join("audio/music-too-loud.mp3") |> dbg()
          Logger.info("Attempting to play file: #{file_path}")

          case File.stat(file_path) do
            {:ok, stats} ->
              Logger.info("File exists with size: #{stats.size}")

              result =
                Voice.play(guild_id, file_path, :url)

              Logger.info("Play command result: #{inspect(result)}")
              result

            {:error, reason} ->
              Logger.error("File error: #{inspect(reason)}")
              {:msg, "Failed to access audio file"}
          end

        [%{name: "file", options: [%{value: url}]}] ->
          Logger.info("Playing from URL: #{url}")
          Voice.play(guild_id, url, :url)

        [%{name: "url", options: [%{value: url}]}] ->
          Logger.info("Playing from URL with ytdl: #{url}")
          Voice.play(guild_id, url, :ytdl)
      end
    else
      Logger.warn("Voice not ready for guild #{guild_id}")
      {:msg, "I must be in a voice channel before playing audio"}
    end
  end
end
