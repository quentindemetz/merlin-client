# frozen_string_literal: true

require "json"
require "fileutils"

module Merlin
  # Local state shared by the CLI and the TUI (~/.config/merlin by default).
  class Config
    attr_reader :home

    def initialize(home = ENV.fetch("MERLIN_HOME", File.join(Dir.home, ".config", "merlin")))
      @home = home
    end

    def setting_id = settings["setting_id"]
    def setting_id=(id)
      save_settings("setting_id" => id)
    end

    def token_store = TokenStore.new(File.join(home, "tokens.json"))
    def cache_dir = File.join(home, "cache")
    def log_dir = File.join(home, "logs")

    # echo: optional ->(line) receiving a one-line summary per exchange.
    def http_log(echo: nil) = HttpLog.new(dir: log_dir, echo: echo)
    def speaker_log(echo: nil) = SpeakerLog.new(dir: log_dir, echo: echo)

    def isolation(out: $stdout, speaker_ip: Speaker::DEFAULT_HOST, port: Speaker::DEFAULT_PORT)
      Isolation.new(state_path: File.join(home, "isolation.json"), speaker_ip: speaker_ip, port: port, out: out)
    end

    def settings
      @settings ||= File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
    end

    def save_settings(values)
      @settings = settings.merge(values)
      FileUtils.mkdir_p(home)
      File.write(settings_path, JSON.pretty_generate(@settings))
    end

    private

    def settings_path = File.join(home, "config.json")
  end
end
