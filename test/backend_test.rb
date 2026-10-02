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
      if req[:path].end_with?("/token")
        form = URI.decode_www_form(req[:body]).to_h
        next [401, '{"error_description":"Invalid user credentials"}'] if form["password"] == "bad"

        @access = form["grant_type"] == "refresh_token" ? "tok2" : "tok1"
        [200, JSON.generate(access_token: @access, refresh_token: "r", expires_in: 300, refresh_expires_in: 1800)]
      elsif req[:headers]["authorization"] != "Bearer #{@access}" || @expire_next
        @expire_next = false
        [401, "{}"]
      elsif req[:path] == "/api/v1/synchros" && req[:verb] == "POST"
        [200, JSON.generate(id: "s1", type: "TRANSFERT", fileList: [], playlistText: "[]")]
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
    assert_equal({ "status" => "PENDING", "type" => "TRANSFERT", "active" => false,
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
    refute JSON.parse(put[:body]).key?("logs"), "nil fields are omitted"
  end

  def test_bad_password
    err = assert_raises(Merlin::BackendError) { @backend.login("a", "bad") }
    assert_match(/Invalid user credentials/, err.message)
    refute @backend.logged_in?
  end

  private

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
