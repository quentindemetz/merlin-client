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

    # on_transfer_end: optional ->(report) called once the speaker part is over
    # (success or failure), before reconnecting and reporting to Merlin.
    def initialize(backend:, cache_dir:, wifi:, speaker_opts: {}, out: $stdout, dry_run: false,
                   internet_wait: 15, on_transfer_end: nil, isolation: nil)
      @on_transfer_end = on_transfer_end
      @isolation = isolation # keeps the Mac's other traffic off the speaker (see Isolation)
      @backend = backend
      @cache_dir = cache_dir
      @wifi = wifi
      @speaker_opts = speaker_opts
      @out = out
      @dry_run = dry_run
      @internet_wait = internet_wait
      @logs = []
    end

    def run(type: "TRANSFERT")
      resend_pending_report

      say "Creating synchro on the Merlin backend..."
      plan = @backend.create_synchro(type: type)
      id = plan.fetch("id")
      save_json("last_synchro.json", plan)
      say "Synchro #{id}: #{plan.fetch('fileList', []).size} file(s) in plan"

      return prepare_files(plan) && write_playlist(plan) && plan if @dry_run

      # From here on every outcome is reported, so the synchro never stays PENDING.
      report = { type: type }
      offline = false
      begin
        files = prepare_files(plan)
        playlist = write_playlist(plan)
        # No Merlin API call may happen from here until we're back online:
        # the speaker's access point has no internet.
        offline = true
        isolate!
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
        @on_transfer_end&.call(report.dup) if offline
        unisolate! if offline
        # restore returns :skip when the user chose not to wait for internet.
        online = !offline || (@wifi.restore != :skip && wait_for_internet)
        online ? send_report(id, report) : save_pending_report(id, report)
      end
      plan
    end

    # After leaving the speaker's Wi-Fi, give the network time to come back
    # before reporting; if it doesn't, send_report saves the report for later.
    # Applied before joining: the rules only match the speaker subnet, so they
    # are harmless at home and the speaker never sees the Mac's traffic burst.
    def isolate!
      return unless @isolation

      @isolation.enable!
      log "Traffic filter on"
    end

    def unisolate!
      return unless @isolation&.active?

      @isolation.disable!
      log "Traffic filter off"
    rescue Error => e
      say "warning: could not remove the traffic filter (#{e.message}); run `merlin unisolate`"
    end

    def wait_for_internet
      return true if @backend.reachable?

      say "Waiting for internet access to send the report to Merlin..."
      deadline = Time.now + @internet_wait
      until @backend.reachable?
        return false if Time.now > deadline

        sleep 3
      end
      true
    end

    private

    def prepare_files(plan)
      dir = File.join(@cache_dir, "sync_files")
      files = plan.fetch("fileList", []).map do |f|
        path = File.join(dir, File.basename(f.fetch("filename")))
        # Like the app: reuse any non-empty cached file. Don't compare with
        # "filesize" — the API reports a placeholder (20000) for images.
        if File.size?(path).nil?
          say "  downloading #{f['type']} #{f['filename']} (#{f['title']})"
          @backend.download(f.fetch("url"), path)
        end
        f.merge("path" => path)
      end
      log "Prepare synchro content files succeed"
      files
    rescue BackendError, SystemCallError, IOError, URI::Error => e # transport errors arrive as OfflineError
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
      @link = [host, port]
      @speaker_ssid = plan["ssid"]
      @link_down = true # first connection goes through the same retry loop
      begin
        begin
          on_speaker("connect") { nil } # reconnect_speaker connects and pings
        rescue SpeakerLinkError => e
          raise Failure.new("510_FAILED_ON_SDK_ESTABLISH_CONNEXION", "speaker not reachable at #{host}:#{port}: #{e.message}")
        end
        log "Connect to speaker succeed"
        on_speaker("read speaker info") { |s| read_info(s, report) }

        images, rest = files.partition { |f| f["type"] == "image" }
        audios = rest.select { |f| f["type"] == "audio" }
        added = upload_all(images, "image") # images first, like the app
        added += upload_all(audios, "audio")
        report[:device_content_added] = audios.size if type_transfer?(report)
        say "  #{added} file(s) uploaded, #{files.size - added} already on the speaker"

        name = File.basename(playlist_path)
        on_speaker("upload #{name}") { |s| s.sync_file(name, File.binread(playlist_path)) }
        log "Upload playlist file on speaker succeed"
        say "Applying playlist (the speaker rebuilds its library; this can take a while)..."
        begin
          on_speaker("apply playlist") { |s| s.update_playlist(name) }
        rescue SpeakerLinkError
          raise
        rescue SpeakerError => e
          code = case e.message
                 when /IMAGE_NOT_FOUND/ then "601_FAILED_ON_SDK_PLAYLIST_UPDATE_IMAGE_NOT_FOUND"
                 when /MUSIC_NOT_FOUND/ then "602_FAILED_ON_SDK_PLAYLIST_UPDATE_AUDIO_NOT_FOUND"
                 else "503_FAILED_ON_SDK_PLAYLIST_UPDATE"
                 end
          raise Failure.new(code, "updatePlaylist: #{e.message}")
        end
        log "Update playlist on speaker succeed"

        best_effort("Set time on speaker") { |s| s.set_date(Time.now) }
        if (slot = plan["time_slot"])
          best_effort("Set enabling hours on speaker") { |s| s.set_enabling_hours(*enabling_hours(slot)) }
        end
        pending_ssid = plan["pendingSsid"].to_s.strip
        unless pending_ssid.empty?
          best_effort("Set Wifi configuration on speaker") { |s| s.set_wifi(pending_ssid, plan["pendingPassword"].to_s) }
        end
        best_effort("End synchronization") { |s| s.end_synchronization }
      ensure
        @speaker&.close
      end
    rescue SpeakerTimeout => e
      raise Failure.new("508_FAILED_ON_SDK_TIMEOUT", e.message)
    rescue SpeakerLinkError => e
      raise Failure.new("509_FAILED_ON_SDK_CONNEXION_LOST", e.message)
    rescue SpeakerError => e
      raise Failure.new("502_FAILED_ON_SDK_UPLOAD_FILE", e.message)
    end

    # Many short attempts, spaced out: after a drop the speaker typically
    # accepts-and-resets connections for 40-80 s (as if its transfer service
    # restarts), and those attempts fail instantly — so spacing, not the
    # per-attempt LINK_WINDOW, is what makes the retries span the outage.
    LINK_RETRIES = 8
    LINK_WINDOW = 15
    BACKOFF = [2, 4, 8, 15, 15, 15, 15, 15].freeze # seconds before each retry (~1.5 min total)

    # Runs a speaker operation; if the link fails (timeout, socket closed, TCP
    # error) reconnects and tries again — the app does the same ("Rescue").
    # A failed reconnect counts as one attempt. Answers from the speaker
    # (e.g. NOT_ENOUGH_SPACE) are not retried.
    def on_speaker(what)
      attempt = 0
      begin
        reconnect_speaker if @link_down
        yield @speaker
      rescue SpeakerLinkError => e
        attempt += 1
        raise if attempt > LINK_RETRIES

        note_link_problem(what, e, attempt)
        @link_down = true
        pause(BACKOFF.fetch(attempt - 1, BACKOFF.last))
        retry
      end
    end

    def note_link_problem(what, error, attempt)
      if @connected_once
        say "  speaker didn't respond during #{what} (#{error.message}); reconnecting in " \
            "#{BACKOFF.fetch(attempt - 1, BACKOFF.last)}s (retry #{attempt}/#{LINK_RETRIES})..."
        say "  (if this Mac left the speaker's Wi-Fi, rejoin #{@speaker_ssid})" if @speaker_ssid && attempt == 1
      else
        say "  speaker not reachable yet (#{error.message}); retrying (#{attempt}/#{LINK_RETRIES})..."
      end
      speaker_trace("!! link problem during #{what}: #{error.message} — #{network_snapshot}")
    end

    # One reconnect attempt, bounded by LINK_WINDOW: connect, then make sure the
    # speaker actually answers (a just-rebooted speaker can accept TCP before
    # it handles commands). In auto Wi-Fi mode, first rejoin its access point.
    def reconnect_speaker
      if @connected_once
        @speaker&.close
        @wifi.rejoin_speaker if @wifi.respond_to?(:rejoin_speaker)
      end
      @speaker = connect_with_retry(*@link, timeout: LINK_WINDOW)
      @speaker.ping(timeout: [@speaker_opts.fetch(:ack_timeout, 3), 3].min)
      if @connected_once
        log "Reconnected to the speaker"
        speaker_trace("reconnected — #{network_snapshot}")
      end
      @connected_once = true
      @link_down = false
    rescue SpeakerLinkError => e
      @speaker&.close
      speaker_trace("reconnect attempt failed: #{e.message} — #{network_snapshot}") if @connected_once
      raise
    end

    def speaker_trace(msg) = @speaker_opts[:logger]&.call(msg)

    # Which network the Mac is on right now (speaker AP is 192.168.4.x).
    def network_snapshot
      ip = `ipconfig getifaddr en0 2>/dev/null`.strip
      gw = `route -n get default 2>/dev/null`[/gateway: (\S+)/, 1]
      "mac wifi ip=#{ip.empty? ? 'none' : ip} default gw=#{gw || 'none'}"
    rescue SystemCallError
      "network state unknown"
    end

    def pause(seconds) = sleep(seconds)

    def connect_with_retry(host, port, timeout:)
      deadline = Time.now + timeout
      begin
        Speaker.new(**@speaker_opts).connect
      rescue SpeakerError => e
        raise SpeakerLinkError, "speaker not reachable at #{host}:#{port}: #{e.message}" if Time.now > deadline

        pause(2)
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

    def upload_all(files, kind)
      added = 0
      files.each_with_index do |f, i|
        label = "  [#{kind} #{i + 1}/#{files.size}] #{f['filename']}"
        data = File.binread(f["path"])
        result = on_speaker("#{kind} #{i + 1}/#{files.size} #{f['filename']}") do |s|
          s.sync_file(File.basename(f["filename"]), data) do |sent, total|
            @out.print "\r#{label} #{(sent * 100 / [total, 1].max)}%"
          end
        end
        outcome = result == :uploaded ? "uploaded" : "already present"
        @out.print "\r#{label} #{outcome}\n"
        log "#{label.strip} (#{data.bytesize} B) #{outcome}" # lands in the report: shows where a sync stopped
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

    # Optional steps: retried on link errors, otherwise failures are only logged.
    def best_effort(what, &)
      on_speaker(what.downcase, &)
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
      save_pending_report(id, report, reason: @last_report_error&.message)
    end

    def save_pending_report(id, report, reason: "still offline")
      save_json("pending_report.json", { "id" => id, "body" => report.merge(logs: @logs.last(200)) })
      say "Report not sent (#{reason}); it will be sent at the next sync."
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
