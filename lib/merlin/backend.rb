# frozen_string_literal: true

require "net/http"
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
    def download(url, dest)
      FileUtils.mkdir_p(File.dirname(dest))
      tmp = "#{dest}.part"
      fetch_to_file(URI(url), tmp)
      File.rename(tmp, dest)
      dest
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
      uri = URI.join(API_BASE, path)
      req = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put,
              delete: Net::HTTP::Delete }.fetch(verb).new(uri)
      app_headers(req)
      req["Authorization"] = "Bearer #{@tokens['access_token']}" if @tokens
      req["X-Setting-Id"] = setting_id.to_s if setting_id
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      log("#{verb.upcase} #{uri}")
      res = http(uri) { |h| h.request(req) }

      if res.code == "401" && @tokens && !retried
        refresh!
        return api(verb, path, body, retried: true)
      end
      unless res.is_a?(Net::HTTPSuccess)
        raise BackendError.new("#{verb.upcase} #{path} -> HTTP #{res.code}: #{res.body.to_s[0, 300]}", status: res.code.to_i)
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
      uri = URI(TOKEN_URL)
      req = Net::HTTP::Post.new(uri)
      app_headers(req)
      req.set_form_data({ client_id: "app" }.merge(form))
      res = http(uri) { |h| h.request(req) }
      unless res.is_a?(Net::HTTPSuccess)
        detail = (JSON.parse(res.body)["error_description"] rescue res.body.to_s[0, 200])
        raise BackendError.new("authentication failed (HTTP #{res.code}): #{detail}", status: res.code.to_i)
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

    def fetch_to_file(uri, path, redirects: 5)
      http(uri) do |h|
        req = Net::HTTP::Get.new(uri)
        app_headers(req)
        h.request(req) do |res|
          case res
          when Net::HTTPRedirection
            raise BackendError, "too many redirects" if redirects.zero?

            return fetch_to_file(URI.join(uri, res["location"]), path, redirects: redirects - 1)
          when Net::HTTPSuccess
            File.open(path, "wb") { |f| res.read_body { |chunk| f.write(chunk) } }
          else
            raise BackendError.new("download #{uri} -> HTTP #{res.code}", status: res.code.to_i)
          end
        end
      end
    end

    def seg(value) = URI.encode_uri_component(value.to_s)

    def app_headers(req)
      req["User-Agent"] = USER_AGENT
      req["X-Merlin-App-Version"] = APP_VERSION
      req["X-Merlin-App-Build"] = APP_BUILD
      req["X-Merlin-OS"] = "Android"
      req["X-Merlin-OS-Version"] = "14"
    end

    def http(uri, &)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 120, &)
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
