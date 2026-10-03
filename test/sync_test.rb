# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "stringio"
require_relative "fake_speaker"

class SyncTest < Minitest::Test
  # Simulated network: while the laptop is on the speaker's access point the
  # Merlin API is unreachable, and any attempt to use it is recorded.
  class SimNet
    attr_accessor :on_speaker, :user_reconnects
    attr_reader :offline_calls

    def initialize
      @on_speaker = false
      @user_reconnects = true
      @offline_calls = []
    end
  end

  class StubBackend
    attr_reader :reports, :downloads
    attr_accessor :fail_reports

    def initialize(plan, contents, net)
      @plan = plan
      @contents = contents
      @net = net
      @reports = []
      @downloads = []
    end

    def reachable? = !@net.on_speaker

    def create_synchro(type:)
      guard!(:create_synchro)
      @plan.merge("type" => type)
    end

    def download(url, dest)
      guard!(:download)
      @downloads << url
      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, @contents.fetch(url))
    end

    def report_synchro(id, body)
      guard!(:report_synchro)
      raise Merlin::BackendError, "server error" if fail_reports

      @reports << [id, body]
    end

    private

    def guard!(call)
      return unless @net.on_speaker

      @net.offline_calls << call
      raise Merlin::OfflineError, "can't reach api.hello-merlin.com"
    end
  end

  class FakeIsolation
    def initialize(events) = (@events = events) && (@on = false)
    def active? = @on

    def enable!
      @on = true
      @events << :filter_on
    end

    def disable!
      @on = false
      @events << :filter_off
    end
  end

  class NoWifi
    def initialize(net) = @net = net
    def join_speaker(*) = @net.on_speaker = true
    def restore = @net.on_speaker = !@net.user_reconnects
  end

  PLAYLIST = '[{"uuid":"u1","title":"Contes","child":[{"uuid":"a1","title":"Le loup"}]}]'

  def setup
    @fake = FakeSpeaker.new
    @dir = Dir.mktmpdir
    @audio = Random.new(2).bytes(250_000)
    @plan = {
      "id" => "syn-42",
      "fileList" => [
        { "type" => "audio", "url" => "https://cdn/a1.mp3", "filename" => "a1.mp3", "title" => "Le loup", "filesize" => @audio.bytesize },
        { "type" => "image", "url" => "https://cdn/u1.jpg", "filename" => "u1.jpg", "title" => "Contes" }
      ],
      "playlistText" => PLAYLIST,
      "time_slot" => { "weekDayActive" => true, "weekDayStart" => "07:30", "weekDayStop" => "19:45",
                       "weekEndActive" => false, "weekEndStart" => "08:00", "weekEndStop" => "20:00" },
      "pendingSsid" => "Home", "pendingPassword" => "pw"
    }
    @net = SimNet.new
    @backend = StubBackend.new(@plan, { "https://cdn/a1.mp3" => @audio, "https://cdn/u1.jpg" => "JPEGDATA" }, @net)
  end

  def teardown
    @fake.stop
    FileUtils.rm_rf(@dir)
  end

  def run_sync(out = StringIO.new)
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net),
                     speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: out).run
  end

  def test_full_sync
    run_sync

    assert_equal @audio, @fake.files["a1.mp3"]
    assert_equal "JPEGDATA", @fake.files["u1.jpg"]
    assert_equal PLAYLIST, @fake.files["playlist-syn-42.json"]
    assert_equal ["playlist-syn-42.json"], @fake.playlist_updates
    assert_equal [7, 30, 19, 45, 10, 0, 10, 0], @fake.hours
    assert_equal %w[Home pw], @fake.wifi
    refute_nil @fake.date
    assert_includes @fake.commands, Merlin::Protocol::Cmd::END_SYNCHRONIZATION
    # images are pushed before audio
    uploads = @fake.commands.each_index.select { |i| @fake.commands[i] == Merlin::Protocol::Cmd::UPLOAD_FILE }
    assert_operator uploads.size, :>=, 3

    id, body = @backend.reports.last
    assert_equal "syn-42", id
    assert_equal "SUCCESS", body[:status]
    assert_equal "100_SUCCEED", body[:status_code]
    assert_equal "TRANSFERT", body[:type]
    assert_equal "1.4.27", body[:firmware_version]
    assert_equal 8_000_000, body[:sd_size]
  end

  # Root cause of the crashes: the Mac's other traffic reaching the speaker.
  # The filter must be on before joining its Wi-Fi and off once the speaker
  # part is over, before going back home.
  def test_traffic_filter_wraps_the_speaker_part
    events = []
    iso = FakeIsolation.new(events)
    wifi = NoWifi.new(@net)
    wifi.define_singleton_method(:join_speaker) { |*| events << :join; @net.on_speaker = true }
    wifi.define_singleton_method(:restore) { events << :restore; @net.on_speaker = false }
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: wifi, isolation: iso,
                     speaker_opts: { host: "127.0.0.1", port: @fake.port },
                     on_transfer_end: ->(_) { events << :transfer_end }, out: StringIO.new).run
    assert_equal %i[filter_on join transfer_end filter_off restore], events
    assert_equal "SUCCESS", @backend.reports.last[1][:status]
  end

  def test_sync_does_not_join_the_speaker_if_the_filter_cannot_be_applied
    joined = false
    iso = Object.new
    iso.define_singleton_method(:enable!) { raise Merlin::Error, "pfctl -E failed" }
    iso.define_singleton_method(:active?) { false }
    wifi = NoWifi.new(@net)
    wifi.define_singleton_method(:join_speaker) { |*| joined = true }
    err = assert_raises(Merlin::Error) do
      Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: wifi, isolation: iso, internet_wait: 0,
                       speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: StringIO.new).run
    end
    assert_match(/pfctl/, err.message)
    refute joined
    assert_equal "FAIL", @backend.reports.last[1][:status]
  end

  def test_no_api_call_while_on_speaker_wifi
    run_sync
    assert_empty @net.offline_calls, "Merlin API was called while on the speaker's Wi-Fi"
    assert_equal "SUCCESS", @backend.reports.last[1][:status]
  end

  def test_user_never_reconnects_report_is_kept_for_later
    @net.user_reconnects = false
    out = StringIO.new
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net), internet_wait: 0,
                     speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: out).run
    assert_empty @net.offline_calls, "no API attempt should be made while still offline"
    assert_empty @backend.reports
    assert_match(/will be sent at the next sync/, out.string)
    pending = JSON.parse(File.read(File.join(@dir, "pending_report.json")))
    assert_equal %w[syn-42 SUCCESS], [pending["id"], pending.dig("body", "status")]

    # Back home; next sync (where the user does reconnect) delivers it first.
    @net.on_speaker = false
    @net.user_reconnects = true
    run_sync
    assert_equal %w[SUCCESS SUCCESS], @backend.reports.map { |_, b| b[:status] || b["status"] }
    refute File.exist?(File.join(@dir, "pending_report.json"))
  end

  def fast_sync(out = StringIO.new)
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net), internet_wait: 0,
                     speaker_opts: { host: "127.0.0.1", port: @fake.port, ack_timeout: 0.1 }, out: out)
                .tap { |s| s.define_singleton_method(:pause) { |*| nil } }
  end

  # Verte at image 36: the speaker stops answering an upload. Like the app,
  # reconnect and carry on instead of failing the whole sync.
  def test_recovers_when_speaker_stops_answering_an_upload
    @fake.silent_uploads = [2] # the audio file (images go first)
    out = StringIO.new
    fast_sync(out).run

    assert_equal @audio, @fake.files["a1.mp3"]
    assert_equal PLAYLIST, @fake.files["playlist-syn-42.json"]
    assert_equal 2, @fake.connections
    assert_match(%r{speaker didn't respond during audio 1/1 a1\.mp3 .*reconnecting in [\d.]+s \(retry 1/8\)}, out.string)
    id, body = @backend.reports.last
    assert_equal ["syn-42", "SUCCESS"], [id, body[:status]]
    assert(body[:logs].any? { _1.include?("[audio 1/1] a1.mp3 (250000 B) uploaded") }, "per-file results are reported")
  end

  # The run that failed at audio 4/6: after the drop, TCP reconnects but the
  # speaker doesn't answer the first ping yet. Keep reconnecting, don't abort.
  def test_reconnect_survives_a_speaker_not_ready_yet
    @fake.silent_uploads = [2]
    @fake.silent_pings = [2] # 1 = initial ping, 2 = first ping after reconnecting
    traces = []
    sync = Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net), internet_wait: 0,
                            speaker_opts: { host: "127.0.0.1", port: @fake.port, ack_timeout: 0.1,
                                            logger: ->(m) { traces << m } }, out: StringIO.new)
    sync.define_singleton_method(:pause) { |*| nil }
    sync.run

    assert_equal "SUCCESS", @backend.reports.last[1][:status]
    assert_equal @audio, @fake.files["a1.mp3"]
    assert_equal 3, @fake.connections # original, reconnect with silent ping, working reconnect
    assert(traces.any? { _1.start_with?("!! link problem during audio 1/1 a1.mp3") && _1.include?("mac wifi ip=") })
    assert(traces.any? { _1.start_with?("reconnect attempt failed: timed out waiting for cmd 2") })
    assert(traces.any? { _1.start_with?("reconnected — mac wifi ip=") })
  end

  # Verte at 22:12: the speaker drops the session, then accepts-and-resets new
  # connections for a while before working again.
  def test_rides_out_speaker_resetting_new_connections
    @fake.silent_uploads = [2]
    @fake.reset_after_drop = 3
    out = StringIO.new
    fast_sync(out).run
    assert_equal "SUCCESS", @backend.reports.last[1][:status]
    assert_equal @audio, @fake.files["a1.mp3"]
    assert_equal 5, @fake.connections # working, 3 reset at once, working again
    refute_includes out.string, "setsockopt"
    assert_match(/the speaker (reset|closed) the connection|socket closed by speaker/, out.string)
  end

  def test_rides_out_several_consecutive_failures
    @fake.silent_uploads = (2..6).to_a # 5 failures in a row, then the speaker answers again
    fast_sync.run
    assert_equal "SUCCESS", @backend.reports.last[1][:status]
    assert_equal 6, @fake.connections
  end

  def test_gives_up_after_all_retries_when_speaker_stays_silent
    @fake.silent_uploads = (2..100).to_a
    sync = fast_sync
    pauses = []
    sync.define_singleton_method(:pause) { |s| pauses << s }
    err = assert_raises(Merlin::Sync::Failure) { sync.run }
    assert_equal "508_FAILED_ON_SDK_TIMEOUT", err.code
    assert_equal 1 + Merlin::Sync::LINK_RETRIES, @fake.connections # first try + one reconnect per retry
    # One short pause before each of the 8 retries.
    assert_equal Merlin::Sync.backoff, pauses
    assert_equal Merlin::Sync::LINK_RETRIES, pauses.size
    assert_equal "508_FAILED_ON_SDK_TIMEOUT", @backend.reports.last[1][:status_code]
  end

  def test_unreachable_at_first_is_retried_then_reported_as_connection_failure
    closed = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    sync = Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net), internet_wait: 0,
                            speaker_opts: { host: "127.0.0.1", port: closed }, out: out = StringIO.new)
    sync.define_singleton_method(:pause) { |*| nil }
    stub_window(0) do
      err = assert_raises(Merlin::Sync::Failure) { sync.run }
      assert_equal "510_FAILED_ON_SDK_ESTABLISH_CONNEXION", err.code
    end
    assert_equal Merlin::Sync::LINK_RETRIES, out.string.scan("speaker not reachable yet").size
  end

  def stub_window(value)
    old = Merlin::Sync.link_window
    Merlin::Sync.link_window = value
    yield
  ensure
    Merlin::Sync.link_window = old
  end
  def test_speaker_refusal_is_not_retried
    @fake.upload_refusal = 2 # NOT_ENOUGH_SPACE
    err = assert_raises(Merlin::Sync::Failure) { fast_sync.run }
    assert_equal "502_FAILED_ON_SDK_UPLOAD_FILE", err.code
    assert_match(/NOT_ENOUGH_SPACE/, err.message)
    assert_equal 1, @fake.connections
  end

  def test_speaker_log_traces_the_protocol_without_wifi_credentials
    lines = []
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net),
                     speaker_opts: { host: "127.0.0.1", port: @fake.port, logger: ->(m) { lines << m } }).run
    trace = lines.join("\n")
    assert_includes trace, "-> upload_file a1.mp3 (250000 B)"
    assert_match(/<- upload_file SHA256_VALID \[\d+ms\]/, trace)
    assert_includes trace, "-> search_file u1.jpg verify=true"
    assert_includes trace, "-> update_playlist playlist-syn-42.json"
    assert_includes trace, "-> set_wifi [REDACTED]"
    refute_includes trace, "Home"
  end

  def test_second_sync_skips_downloads_and_uploads
    run_sync
    out = StringIO.new
    run_sync(out)
    assert_equal 2, @backend.downloads.size
    assert_match(/0 file\(s\) uploaded, 2 already on the speaker/, out.string)
  end

  def test_download_failure_is_reported
    def @backend.download(*) = raise(URI::InvalidURIError, "bad URI")
    err = assert_raises(Merlin::Sync::Failure) { run_sync }
    assert_equal "202_FAILED_ON_PREPARE_CONTENT_FILES", err.code
    assert_equal ["syn-42", "FAIL", "202_FAILED_ON_PREPARE_CONTENT_FILES"],
                 [@backend.reports.last[0], *@backend.reports.last[1].values_at(:status, :status_code)]
  end

  def test_playlist_failure_is_reported
    @plan["playlistText"] = nil
    assert_raises(Merlin::Sync::Failure) { run_sync }
    assert_equal "203_FAILED_ON_PREPARE_CONTENT_PLAYLIST", @backend.reports.last[1][:status_code]
  end

  def test_unreachable_speaker_reports_failure_and_saves_pending_report
    @fake.stop
    @backend.fail_reports = true
    sync = Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net),
                            speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: StringIO.new)
    sync.define_singleton_method(:connect_with_retry) do |*, **|
      raise Merlin::Sync::Failure.new("510_FAILED_ON_SDK_ESTABLISH_CONNEXION", "unreachable")
    end
    sync.define_singleton_method(:sleep) { |*| nil }
    err = assert_raises(Merlin::Sync::Failure) { sync.run }
    assert_equal "510_FAILED_ON_SDK_ESTABLISH_CONNEXION", err.code
    pending = JSON.parse(File.read(File.join(@dir, "pending_report.json")))
    assert_equal "FAIL", pending["body"]["status"]

    @backend.fail_reports = false
    @fake = FakeSpeaker.new
    Merlin::Sync.new(backend: @backend, cache_dir: @dir, wifi: NoWifi.new(@net),
                     speaker_opts: { host: "127.0.0.1", port: @fake.port }, out: StringIO.new).run
    assert_equal ["syn-42", "syn-42"], @backend.reports.map(&:first)
    assert_equal "510_FAILED_ON_SDK_ESTABLISH_CONNEXION", @backend.reports.first[1][:status_code]
    refute File.exist?(File.join(@dir, "pending_report.json"))
  end
end
