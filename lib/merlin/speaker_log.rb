# frozen_string_literal: true

require "date"
require "fileutils"

module Merlin
  # Timestamped trace of the speaker TCP protocol (commands, replies, timings,
  # reconnects), one file per day next to the HTTP log. Usable directly as a
  # Speaker logger (responds to #call). Thread-safe.
  class SpeakerLog
    def initialize(dir:, echo: nil, keep_days: 14)
      @dir = dir
      @echo = echo
      @mutex = Mutex.new
      FileUtils.mkdir_p(dir, mode: 0o700)
      Dir.glob(File.join(dir, "speaker-*.log")).each do |f|
        date = Date.iso8601(File.basename(f)[/\d{4}-\d{2}-\d{2}/]) rescue next
        File.delete(f) if date < Date.today - keep_days
      end
    end

    def path = File.join(@dir, "speaker-#{Date.today.iso8601}.log")

    def call(msg)
      line = "#{Time.now.strftime('%H:%M:%S.%L')} #{msg}"
      @mutex.synchronize do
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |f| f.puts(line) }
      end
      @echo&.call(msg)
    rescue SystemCallError, IOError
      nil
    end
  end
end
