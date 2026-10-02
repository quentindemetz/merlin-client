# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require "fileutils"

module Merlin
  class BackendError < Error
    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end
  end

  # No route to the Merlin servers — typically because the Mac is on the
  # speaker's (internet-less) Wi-Fi.
  class OfflineError < BackendError; end

  # Client for the Hello Merlin cloud API (the app's Retrofit services).
  class Backend
    API_BASE = "https://api.hello-merlin.com/api/v1/"
    TOKEN_URL = "https://sso.hello-merlin.com/auth/realms/hello-merlin/protocol/openid-connect/token"
    APP_VERSION = "1.20.5"
    APP_BUILD = "1020005"
    USER_AGENT = "Merlin/#{APP_VERSION} Dalvik/2.1.0 (Linux; U; Android 14)".freeze

    attr_accessor :setting_id

    # token_store: object responding to #load and #save(hash) (see TokenStore).
    def initialize(token_store:, setting_id: nil, logger: nil)
      @token_store = token_store
      @tokens = token_store.load
      @setting_id = setting_id
      @logger = logger
    end

    def logged_in? = !@tokens.nil?

    # Cheap connectivity probe (the app does the same HEAD on the API base).
    def reachable?(timeout: 4)
      perform(API_BASE) { connection(timeout: timeout).head(API_BASE) }
      true
    rescue OfflineError
      false
    end

    # --- Auth (Keycloak) -----------------------------------------------------

    def login(username, password)
      store_tokens(token_request(grant_type: "password", username: username.strip, password: password))
    end

    def logout
      @tokens = nil
      @token_store.save(nil)
    end

    # --- API -----------------------------------------------------------------

    # Account configuration; "settings" lists the paired speakers.
    def config = get("configs/multi")

    def speakers = Array(config["settings"])

    # Starts a synchronisation. type: "TRANSFERT" (content), "PAIRING",
    # "FIRMWARE_UPDATE". Returns the plan: fileList, playlistText, time_slot...
    # The app builds SynchroBody with Kotlin defaults (mask 14330 / 1920 / 896),
    # which force start = end = "" and active = true; the API answers a bare
    # 400 Bad Request without them.
    SYNCHRO_DEFAULTS = { start: "", end: "", active: true, device_content_added: 0 }.freeze

    def create_synchro(type: "TRANSFERT")
      post("synchros", { status: "PENDING", type: type, **SYNCHRO_DEFAULTS, device_agent: USER_AGENT })
    end

    def report_synchro(id, body)
      put("synchros/#{id}", { **SYNCHRO_DEFAULTS, device_agent: USER_AGENT }.merge(body).compact)
    end

    # File URLs in a synchro plan are fetched without auth, like the app does.
    # Streams to disk; the timeout bounds each read, so large MP3s are fine.
    def download(url, dest, redirects: 5)
      FileUtils.mkdir_p(File.dirname(dest))
      tmp = "#{dest}.part"
      url = lenient_url(url)
      loop do
        res = File.open(tmp, "wb") do |f|
          perform(url) do
            connection.get(url) do |req|
              # Only keep the body of the final 2xx response, not redirect pages.
              req.options.on_data = proc { |chunk, _size, env| f.write(chunk) if env.status.to_i.between?(200, 299) }
            end
          end
        end
        if res.status.between?(300, 399) && res.headers["location"]
          raise BackendError, "download #{url}: too many redirects" if (redirects -= 1).negative?

          url = URI.join(url, lenient_url(res.headers["location"])).to_s
          next
        end
        raise BackendError.new("download #{url} -> HTTP #{res.status}", status: res.status) unless res.success?

        File.rename(tmp, dest)
        return dest
      end
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end

    # --- Catalog -------------------------------------------------------------
    #
    # The store is a tree of pages: a page has "modules" (keyed by "format":
    # selection_slider, taxon_slider, taxon_grid_large/small,
    # taxon_slider_potatoes, website_purchase). Taxa either open another page
    # ("subpageid") or a taxonomy listing collections/contents. Durations are in
    # seconds.

    def home_page_id = config["home_page_id"]
    def page(id) = get("pages/#{seg(id)}/full")
    def taxonomy(id) = get("taxonomies/#{seg(id)}/full")
    def collection(id) = get("collections/#{seg(id)}/purchase-info") # includes the episode list
    def content(id) = get("contents/#{seg(id)}/full")
    def search(query) = get("contents/search/#{seg(query)}") # [{collection:}|{content:}]
    def offered_packs = get("packs/list/offered")
    def pack_preview(id) = get("packs/preview/#{seg(id)}")

    # What is (or will be) on the selected speaker: a tree of folders/contents
    # with add / selection / isInLastSync flags.
    def speaker_library = get("catalogs")

    # The "basket" of pending changes picked up by the next synchro.
    def selections = get("selections")
    def select_contents(ids, add: true) = post("selections", { add: add, contents: Array(ids) })
    def select_collection(id) = post("selections/collection", { add: true, collectionId: id })
    def cancel_selections(ids) = api(:delete, "selections", { contents: Array(ids) })

    def get(path) = api(:get, path)
    def post(path, body) = api(:post, path, body)
    def put(path, body) = api(:put, path, body)

    private

    def api(verb, path, body = nil, retried: false)
      refresh! if @tokens && Time.now.to_i >= @tokens["expires_at"].to_i
      url = URI.join(API_BASE, path).to_s
      headers = {}
      headers["Authorization"] = "Bearer #{@tokens['access_token']}" if @tokens
      headers["X-Setting-Id"] = setting_id.to_s if setting_id
      headers["Content-Type"] = "application/json" if body
      log("#{verb.upcase} #{url}")
      res = perform(url) { connection.run_request(verb, url, body && JSON.generate(body), headers) }

      if res.status == 401 && @tokens && !retried
        refresh!
        return api(verb, path, body, retried: true)
      end
      unless res.success?
        raise BackendError.new("#{verb.upcase} #{path} -> HTTP #{res.status}: #{res.body.to_s[0, 300]}", status: res.status)
      end

      res.body.to_s.strip.empty? ? nil : JSON.parse(res.body)
    end

    def refresh!
      raise BackendError, "not logged in (run `merlin login`)" unless @tokens

      store_tokens(token_request(grant_type: "refresh_token", refresh_token: @tokens["refresh_token"]))
    rescue BackendError => e
      if e.status && e.status.between?(400, 499)
        logout
        raise BackendError, "session expired, run `merlin login` again"
      end
      raise
    end

    def token_request(**form)
      res = perform(TOKEN_URL) do
        connection.post(TOKEN_URL, URI.encode_www_form({ client_id: "app" }.merge(form)),
                        "Content-Type" => "application/x-www-form-urlencoded")
      end
      unless res.success?
        detail = (JSON.parse(res.body)["error_description"] rescue res.body.to_s[0, 200])
        raise BackendError.new("authentication failed (HTTP #{res.status}): #{detail}", status: res.status)
      end
      JSON.parse(res.body)
    end

    def store_tokens(raw)
      now = Time.now.to_i
      @tokens = {
        "access_token" => raw.fetch("access_token"),
        "refresh_token" => raw["refresh_token"],
        "expires_at" => now + raw.fetch("expires_in", 300).to_i - 30,
        "refresh_expires_at" => now + raw.fetch("refresh_expires_in", 0).to_i - 30
      }
      @token_store.save(@tokens)
      @tokens
    end

    def seg(value) = URI.encode_uri_component(value.to_s)

    # The API hands out URLs with raw spaces / accents (imgproxy URLs embedding
    # file names); OkHttp tolerates them, URI() doesn't. Percent-encode only
    # characters that are never valid in a URI, leaving existing escapes alone.
    def lenient_url(url)
      url.to_s.gsub(%r{[^A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]}) { |c| c.bytes.map { |b| format("%%%02X", b) }.join }
    end

    APP_HEADERS = {
      "User-Agent" => USER_AGENT,
      "X-Merlin-App-Version" => APP_VERSION,
      "X-Merlin-App-Build" => APP_BUILD,
      "X-Merlin-OS" => "Android",
      "X-Merlin-OS-Version" => "14"
    }.freeze

    # Every HTTP call goes through Faraday with a short timeout. With the
    # Net::HTTP adapter it bounds the connect and each socket read/write, so a
    # dead network (e.g. the speaker's access point) fails fast while long
    # downloads that keep making progress are unaffected.
    API_TIMEOUT = 10

    def connection(timeout: API_TIMEOUT)
      Faraday.new(headers: APP_HEADERS, request: { timeout: timeout, open_timeout: timeout })
    end

    # Transport failures (DNS, refused/reset connections, timeouts, TLS) become
    # OfflineError; HTTP statuses are left to the caller.
    def perform(url)
      yield
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      host = (URI(url).host rescue url)
      raise OfflineError, "can't reach #{host} (#{e.message}) — is this Mac still on the speaker's Wi-Fi?"
    end

    def log(msg) = @logger&.call(msg)
  end

  # Persists OAuth tokens (never the password) in a 0600 JSON file.
  class TokenStore
    def initialize(path)
      @path = path
    end

    def load
      File.exist?(@path) ? JSON.parse(File.read(@path)) : nil
    rescue JSON::ParserError
      nil
    end

    def save(tokens)
      if tokens.nil?
        FileUtils.rm_f(@path)
        return
      end
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      File.write(@path, JSON.pretty_generate(tokens), perm: 0o600)
    end
  end
end
