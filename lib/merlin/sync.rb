# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"

module Merlin
  # Re-implementation of the app's content synchronisation:
  #
  #   1. POST /synchros            -> plan (files, playlist JSON, settings)
  #   2. download every file        (while still on the home network)
  #   3. join the speaker's Wi-Fi, TCP 192.168.4.1:50000
  #   4. upload images, then audio  (skipping files already on the speaker)
  #   5. upload playlist-<id>.json, ask the speaker to apply it
  #   6. set clock, enabling hours, home Wi-Fi config; end synchronisation
  #   7. back on the home network:  PUT /synchros/<id> with the report
  class Sync
    class Failure < Error
      attr_reader :code

      def initialize(code, message)
        super(message)
        @code = code
      end
    end

    def initialize(backend:, cache_dir:, wifi:, speaker_opts: {}, out: $stdout, dry_run: false)
      @backend = backend
      @cache_dir = cache_dir
      @wifi = wifi
      @speaker_opts = speaker_opts
      @out = out
      @dry_run = dry_run
      @logs = []
    end

    def run(type: "TRANSFERT")
      resend_pending_report

      say "Creating synchro on the Merlin backend..."
      plan = @backend.create_synchro(type: type)
      id = plan.fetch("id")
      save_json("last_synchro.json", plan)
      say "Synchro #{id}: #{plan.fetch('fileList', []).size} file(s) in plan"

      files = prepare_files(plan)
      playlist = write_playlist(plan)
      return plan if @dry_run

      report = { type: type }
      begin
        @wifi.join_speaker(plan["ssid"], plan["password"])
        transfer(plan, files, playlist, report)
        report.merge!(status: "SUCCESS", status_code: "100_SUCCEED")
        say "Transfer complete."
      rescue Failure => e
        fail_report(report, e.code, e.message)
        raise
      rescue Interrupt
        fail_report(report, "800_FAILED_ON_USER_ABORT", "aborted by user")
        raise
      rescue StandardError => e
        fail_report(report, "900_FAILED_ON_UNKNOW_ERROR", "#{e.class}: #{e.message}")
        raise
      ensure
        @wifi.restore
        send_report(id, report)
      end
      plan
    end

    private

    def prepare_files(plan)
      dir = File.join(@cache_dir, "sync_files")
      files = plan.fetch("fileList", []).map do |f|
        path = File.join(dir, File.basename(f.fetch("filename")))
        if File.size?(path).nil? || (f["filesize"] && File.size(path) != f["filesize"])
          say "  downloading #{f['type']} #{f['filename']} (#{f['title']})"
          @backend.download(f.fetch("url"), path)
        end
        f.merge("path" => path)
      end
      log "Prepare synchro content files succeed"
      files
    rescue BackendError, SystemCallError => e
      raise Failure.new("202_FAILED_ON_PREPARE_CONTENT_FILES", e.message)
    end

    def write_playlist(plan)
      text = plan["playlistText"]
      raise Failure.new("203_FAILED_ON_PREPARE_CONTENT_PLAYLIST", "plan has no playlistText") if text.nil?

      path = File.join(@cache_dir, "playlist-#{plan['id']}.json")
      FileUtils.mkdir_p(@cache_dir)
      File.write(path, text)
      log "Save playlist file in cache succeed"
      path
    end

    def transfer(plan, files, playlist_path, report)
      host = @speaker_opts.fetch(:host, Speaker::DEFAULT_HOST)
      port = @speaker_opts.fetch(:port, Speaker::DEFAULT_PORT)
      say "Connecting to the speaker at #{host}:#{port}..."
      speaker = connect_with_retry(host, port, timeout: 90)
      begin
        speaker.ping(timeout: 5)
        log "Connect to speaker succeed"
        read_info(speaker, report)

        images, rest = files.partition { |f| f["type"] == "image" }
        audios = rest.select { |f| f["type"] == "audio" }
        added = upload_all(speaker, images, "image") # images first, like the app
        added += upload_all(speaker, audios, "audio")
        report[:device_content_added] = audios.size if type_transfer?(report)
        say "  #{added} file(s) uploaded, #{files.size - added} already on the speaker"

        name = File.basename(playlist_path)
        speaker.sync_file(name, File.binread(playlist_path))
        log "Upload playlist file on speaker succeed"
        say "Applying playlist (the speaker rebuilds its library; this can take a while)..."
        begin
          speaker.update_playlist(name)
        rescue SpeakerError => e
          code = case e.message
                 when /IMAGE_NOT_FOUND/ then "601_FAILED_ON_SDK_PLAYLIST_UPDATE_IMAGE_NOT_FOUND"
                 when /MUSIC_NOT_FOUND/ then "602_FAILED_ON_SDK_PLAYLIST_UPDATE_AUDIO_NOT_FOUND"
                 else "503_FAILED_ON_SDK_PLAYLIST_UPDATE"
                 end
          raise Failure.new(code, "updatePlaylist: #{e.message}")
        end
        log "Update playlist on speaker succeed"

        best_effort("Set time on speaker") { speaker.set_date(Time.now) }
        if (slot = plan["time_slot"])
          best_effort("Set enabling hours on speaker") { speaker.set_enabling_hours(*enabling_hours(slot)) }
        end
        pending_ssid = plan["pendingSsid"].to_s.strip
        unless pending_ssid.empty?
          best_effort("Set Wifi configuration on speaker") { speaker.set_wifi(pending_ssid, plan["pendingPassword"].to_s) }
        end
        best_effort("End synchronization") { speaker.end_synchronization }
      ensure
        speaker.close
      end
    rescue SpeakerTimeout => e
      raise Failure.new("508_FAILED_ON_SDK_TIMEOUT", e.message)
    rescue SpeakerError => e
      raise Failure.new("502_FAILED_ON_SDK_UPLOAD_FILE", e.message)
    end

    def connect_with_retry(host, port, timeout:)
      deadline = Time.now + timeout
      begin
        Speaker.new(**@speaker_opts).connect
      rescue SpeakerError => e
        if Time.now > deadline
          raise Failure.new("510_FAILED_ON_SDK_ESTABLISH_CONNEXION", "speaker not reachable at #{host}:#{port}: #{e.message}")
        end

        sleep 2
        retry
      end
    end

    def read_info(speaker, report)
      info = speaker.info
      say "Speaker: firmware #{info[:firmware_version]}, battery #{info[:battery][:level]}%" \
          "#{' (charging)' if info[:battery][:charging]}, #{info[:available_space]}/#{info[:total_size]} free"
      report.merge!(firmware_version: info[:firmware_version], sd_size: info[:total_size],
                    available_size: info[:available_space], mac_address: info[:mac_address])
    end

    def upload_all(speaker, files, kind)
      added = 0
      files.each_with_index do |f, i|
        label = "  [#{kind} #{i + 1}/#{files.size}] #{f['filename']}"
        data = File.binread(f["path"])
        result = speaker.sync_file(File.basename(f["filename"]), data) do |sent, total|
          @out.print "\r#{label} #{(sent * 100 / [total, 1].max)}%"
        end
        @out.print "\r#{label} #{result == :uploaded ? 'uploaded' : 'already present'}\n"
        added += 1 if result == :uploaded
      end
      log "Upload #{kind} files succeed"
      added
    end

    # Weekday window then weekend window; a disabled window is sent as
    # 10:00-10:00, exactly like the app.
    def enabling_hours(slot)
      off = [[10, 0], [10, 0]]
      week = slot["weekDayActive"] ? [hm(slot["weekDayStart"]), hm(slot["weekDayStop"])] : off
      weekend = slot["weekEndActive"] ? [hm(slot["weekEndStart"]), hm(slot["weekEndStop"])] : off
      [week, weekend]
    end

    def hm(str)
      h, m = str.to_s.split(":").map(&:to_i)
      [h || 10, m || 0]
    end

    def type_transfer?(report) = report[:type] == "TRANSFERT"

    def best_effort(what)
      yield
      log "#{what} succeed"
    rescue SpeakerError => e
      log "#{what} failed, error ignored: #{e.message}"
      say "  warning: #{what.downcase} failed (#{e.message})"
    end

    def fail_report(report, code, message)
      log message
      report.merge!(status: "FAIL", status_code: code)
    end

    # --- Reporting -----------------------------------------------------------

    def send_report(id, report)
      body = report.merge(logs: @logs.last(200))
      3.times do |attempt|
        sleep attempt
        @backend.report_synchro(id, body)
        FileUtils.rm_f(pending_report_path)
        say "Report sent to the Merlin backend."
        return
      rescue BackendError, SystemCallError, SocketError, IOError => e
        @last_report_error = e
      end
      save_json("pending_report.json", { "id" => id, "body" => body })
      say "Could not send report (#{@last_report_error&.message}); it will be retried on the next sync."
    end

    def resend_pending_report
      return unless File.exist?(pending_report_path)

      pending = JSON.parse(File.read(pending_report_path))
      @backend.report_synchro(pending["id"], pending["body"].transform_keys(&:to_sym))
      FileUtils.rm_f(pending_report_path)
    rescue BackendError, JSON::ParserError
      nil
    end

    def pending_report_path = File.join(@cache_dir, "pending_report.json")

    def save_json(name, obj)
      FileUtils.mkdir_p(@cache_dir)
      File.write(File.join(@cache_dir, name), JSON.pretty_generate(obj))
    end

    def log(msg) = @logs << msg

    def say(msg)
      @out.puts msg
      log msg
    end
  end
end
