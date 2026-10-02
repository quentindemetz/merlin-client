# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "tmpdir"
require "uri"
require_relative "../lib/merlin"

# Exercises Backend against a tiny local HTTP server standing in for both the
# Keycloak token endpoint and the REST API.
class BackendTest < Minitest::Test
  class TinyHTTP
    attr_reader :requests, :port

    def initialize(&handler)
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @requests = []
      @handler = handler
      @thread = Thread.new { loop { serve(@server.accept) } rescue IOError }
    end

    def stop
      @server.close
      @thread.kill
    end

    private

    def serve(sock)
      line = sock.gets or return
      verb, path, = line.split
      headers = {}
      while (h = sock.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.downcase] = v.strip
      end
      body = sock.read(headers["content-length"].to_i)
      req = { verb: verb, path: path, headers: headers, body: body }
      @requests << req
      status, resp = @handler.call(req)
      sock.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{resp.bytesize}\r\nConnection: close\r\n\r\n#{resp}")
    ensure
      sock&.close
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @access = "tok1"
    @server = TinyHTTP.new do |req|
      if req[:path].start_with?("/plain/") # CDN download: no auth expected
        next [200, "JPEG"]
      end

      if req[:path].end_with?("/token")
        form = URI.decode_www_form(req[:body]).to_h
        next [401, '{"error_description":"Invalid user credentials"}'] if form["password"] == "bad"

        @access = form["grant_type"] == "refresh_token" ? "tok2" : "tok1"
        [200, JSON.generate(access_token: @access, refresh_token: "refresh-SECRET-123", expires_in: 300, refresh_expires_in: 1800)]
      elsif req[:headers]["authorization"] != "Bearer #{@access}" || @expire_next
        @expire_next = false
        [401, "{}"]
      elsif req[:path] == "/api/v1/synchros" && req[:verb] == "POST"
        [200, JSON.generate(id: "s1", type: "TRANSFERT", fileList: [], playlistText: "[]", ssid: "MERLIN_KH2755", password: "ap-pass-777", pendingSsid: "HomeNet-42", pendingPassword: "home-pass-888")]
      elsif req[:path] == "/api/v1/configs/multi"
        [200, JSON.generate(home_page_id: "home-1", settings: [{ id: "set-9", speaker_name: "Chambre de Lea", mac_address: "170:187:204:1:2:3" }])]
      elsif req[:path].start_with?("/api/v1/selections")
        [200, JSON.generate([{ add: true, selection: true, content: { id: "c1", title: "Le loup" } }])]
      elsif req[:path].start_with?("/api/v1/")
        [200, JSON.generate(echo: req[:path])]
      else
        [200, ""]
      end
    end
    base = "http://127.0.0.1:#{@server.port}"
    stub_const(:API_BASE, "#{base}/api/v1/")
    stub_const(:TOKEN_URL, "#{base}/realms/x/token")
    @backend = Merlin::Backend.new(token_store: Merlin::TokenStore.new(File.join(@dir, "t.json")), setting_id: "set-9")
  end

  def teardown
    @server.stop
    FileUtils.rm_rf(@dir)
    @saved_consts&.each { |k, v| silence { Merlin::Backend.const_set(k, v) } }
  end

  def test_login_and_create_synchro_with_headers
    @backend.login(" kid@example.com ", "pw")
    plan = @backend.create_synchro
    assert_equal "s1", plan["id"]

    token_req = @server.requests.first
    assert_equal({ "client_id" => "app", "grant_type" => "password", "username" => "kid@example.com", "password" => "pw" },
                 URI.decode_www_form(token_req[:body]).to_h)
    api_req = @server.requests.last
    assert_equal "Bearer tok1", api_req[:headers]["authorization"]
    assert_equal "set-9", api_req[:headers]["x-setting-id"]
    assert_equal "1.20.5", api_req[:headers]["x-merlin-app-version"]
    # Exact body the app sends (verified against the live API: anything else is a 400)
    assert_equal({ "status" => "PENDING", "type" => "TRANSFERT", "start" => "", "end" => "", "active" => true,
                   "device_content_added" => 0, "device_agent" => Merlin::Backend::USER_AGENT },
                 JSON.parse(api_req[:body]))
    assert_equal 0o600, File.stat(File.join(@dir, "t.json")).mode & 0o777
  end

  def test_refreshes_on_401
    @backend.login("a", "pw")
    @expire_next = true
    @backend.report_synchro("s1", { status: "SUCCESS", status_code: "100_SUCCEED", logs: nil })
    put = @server.requests.last
    assert_equal "PUT", put[:verb]
    assert_equal "/api/v1/synchros/s1", put[:path]
    assert_equal "Bearer tok2", put[:headers]["authorization"]
    body = JSON.parse(put[:body])
    refute body.key?("logs"), "nil fields are omitted"
    assert_equal ["", "", true], body.values_at("start", "end", "active")
  end

  def test_bad_password
    err = assert_raises(Merlin::BackendError) { @backend.login("a", "bad") }
    assert_match(/Invalid user credentials/, err.message)
    refute @backend.logged_in?
  end

  def test_download_tolerates_raw_spaces_and_accents_in_urls
    dest = File.join(@dir, "img.jpg")
    @backend.download("http://127.0.0.1:#{@server.port}/plain/https://x/10 histoires de j'aime lire é.jpg@jpg", dest)
    assert_equal "/plain/https://x/10%20histoires%20de%20j'aime%20lire%20%C3%A9.jpg@jpg", @server.requests.last[:path]
    assert File.exist?(dest)
  end

  def test_unreachable_host_raises_offline_error
    closed_port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    stub_const(:API_BASE, "http://127.0.0.1:#{closed_port}/api/v1/")
    @backend.login("a", "pw")
    err = assert_raises(Merlin::OfflineError) { @backend.selections }
    assert_match(/can't reach 127\.0\.0\.1.*speaker's Wi-Fi/, err.message)
    assert @backend.logged_in?, "losing the network must not log the user out"
    refute @backend.reachable?
  end

  def test_silent_server_times_out_quickly
    silent = TCPServer.new("127.0.0.1", 0)
    hold = Thread.new { loop { (@held ||= []) << silent.accept } }
    stub_const(:API_BASE, "http://127.0.0.1:#{silent.addr[1]}/api/v1/")
    stub_const(:API_TIMEOUT, 1)
    @backend.login("a", "pw")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Merlin::OfflineError) { @backend.selections }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
  ensure
    hold&.kill
    silent&.close
  end

  def test_api_timeout_is_ten_seconds
    conn = @backend.send(:connection)
    assert_equal [10, 10], [conn.options.timeout, conn.options.open_timeout]
    assert_equal Merlin::Backend::USER_AGENT, conn.headers["User-Agent"]
  end

  SECRETS = %w[kid@example.com s3cret-PW tok1 tok2 refresh-SECRET-123 ap-pass-777 home-pass-888
               HomeNet-42 Chambre\ de\ Lea 170:187:204:1:2:3 sigABC123].freeze

  def logged_backend(echo: nil)
    @log_dir = File.join(@dir, "logs")
    Merlin::Backend.new(token_store: Merlin::TokenStore.new(File.join(@dir, "t2.json")), setting_id: "set-9",
                        http_log: Merlin::HttpLog.new(dir: @log_dir, echo: echo))
  end

  def log_entries
    files = Dir[File.join(@log_dir, "http-*.jsonl")]
    assert_equal 1, files.size
    @raw_log = File.read(files.first)
    @raw_log.lines.map { JSON.parse(_1) }
  end

  def test_http_log_records_every_exchange_without_secrets_or_pii
    echoed = []
    backend = logged_backend(echo: ->(line) { echoed << line })
    backend.login("kid@example.com", "s3cret-PW")
    backend.speakers
    backend.create_synchro
    @expire_next = true # 401 -> refresh -> retry, all logged
    backend.report_synchro("s1", { status: "FAIL", logs: ["upload failed for kid@example.com"], mac_address: "170:187:204:1:2:3" })
    backend.download("http://127.0.0.1:#{@server.port}/plain/cover.jpg?w=128&signature=sigABC123", File.join(@dir, "c.jpg"))

    entries = log_entries
    SECRETS.each { |secret| refute_includes @raw_log, secret, "secret/PII leaked into the HTTP log" }

    # One entry per exchange: login, configs, synchros, PUT 401, refresh, PUT retry, download
    assert_equal %w[POST GET POST PUT POST PUT GET], entries.map { _1.dig("request", "method") }
    assert(entries.all? { _1["response"]["status"] && _1["duration_ms"] && _1["id"] && _1["at"] })

    login = entries[0]
    assert_equal({ "client_id" => "app", "grant_type" => "password", "username" => "[REDACTED]", "password" => "[REDACTED]" },
                 login.dig("request", "body"))
    assert_equal ["[REDACTED]", "[REDACTED]", 300], login.dig("response", "body").values_at("access_token", "refresh_token", "expires_in")

    config = entries[1]
    assert_equal "[REDACTED]", config.dig("request", "headers", "Authorization")
    assert_equal "set-9", config.dig("request", "headers", "X-Setting-Id")
    assert_equal({ "id" => "set-9", "speaker_name" => "[REDACTED]", "mac_address" => "[REDACTED]" },
                 config.dig("response", "body", "settings", 0))

    plan = entries[2].dig("response", "body")
    assert_equal ["s1", "MERLIN_KH2755", "[REDACTED]", "[REDACTED]", "[REDACTED]"],
                 plan.values_at("id", "ssid", "password", "pendingSsid", "pendingPassword")
    assert_equal "PENDING", entries[2].dig("request", "body", "status")

    assert_equal 401, entries[3].dig("response", "status")
    assert_equal ["upload failed for [EMAIL]"], entries[5].dig("request", "body", "logs")

    dl = entries[6]
    assert_includes dl.dig("request", "url"), "signature=%5BREDACTED%5D"
    assert_equal [200, 4, "JPEG"], dl["response"].values_at("status", "streamed_bytes", "body")

    assert_match(%r{\APOST http://127\.0\.0\.1:\d+/api/v1/synchros -> 200 \[\d+ms\]\z}, echoed[2])
    assert_equal 0o600, File.stat(Dir[File.join(@log_dir, "*.jsonl")].first).mode & 0o777
  end

  def test_http_log_records_network_errors
    closed_port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
    stub_const(:API_BASE, "http://127.0.0.1:#{closed_port}/api/v1/")
    backend = logged_backend
    assert_raises(Merlin::OfflineError) { backend.selections }
    entry = log_entries.last
    assert_equal "GET", entry.dig("request", "method")
    assert_match(/Faraday::ConnectionFailed/, entry["error"])
    assert_nil entry["response"]
  end

  def test_catalog_endpoints
    @backend.login("a", "pw")
    assert_equal "home-1", @backend.home_page_id
    {
      -> { @backend.page("p 1") } => "/api/v1/pages/p%201/full",
      -> { @backend.taxonomy("t1") } => "/api/v1/taxonomies/t1/full",
      -> { @backend.collection("c1") } => "/api/v1/collections/c1/purchase-info",
      -> { @backend.content("k1") } => "/api/v1/contents/k1/full",
      -> { @backend.search("petit ours/brun") } => "/api/v1/contents/search/petit%20ours%2Fbrun",
      -> { @backend.offered_packs } => "/api/v1/packs/list/offered",
      -> { @backend.pack_preview("pk") } => "/api/v1/packs/preview/pk",
      -> { @backend.speaker_library } => "/api/v1/catalogs"
    }.each do |call, path|
      assert_equal({ "echo" => path }, call.call)
      assert_equal "set-9", @server.requests.last[:headers]["x-setting-id"]
    end
  end

  def test_selection_endpoints
    @backend.login("a", "pw")
    entries = @backend.select_contents(%w[c1 c2])
    assert_equal "c1", entries.first.dig("content", "id")
    assert_selection_request "POST", "/api/v1/selections", { "add" => true, "contents" => %w[c1 c2] }

    @backend.select_contents("c3", add: false)
    assert_selection_request "POST", "/api/v1/selections", { "add" => false, "contents" => ["c3"] }

    @backend.select_collection("col-7")
    assert_selection_request "POST", "/api/v1/selections/collection", { "add" => true, "collectionId" => "col-7" }

    @backend.cancel_selections(["c1"])
    assert_selection_request "DELETE", "/api/v1/selections", { "contents" => ["c1"] }

    @backend.selections
    assert_equal %w[GET /api/v1/selections], @server.requests.last.values_at(:verb, :path)
  end

  private

  def assert_selection_request(verb, path, body)
    req = @server.requests.last
    assert_equal [verb, path], [req[:verb], req[:path]]
    assert_equal body, JSON.parse(req[:body])
  end

  def stub_const(name, value)
    (@saved_consts ||= {})[name] = Merlin::Backend.const_get(name)
    silence { Merlin::Backend.const_set(name, value) }
  end

  def silence
    old = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = old
  end
end
