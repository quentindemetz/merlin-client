# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"

module Merlin
  # Builds and runs the "Merlin Wi-Fi" background app (wifi_helper/main.swift):
  # since macOS 14 the current network name and Wi-Fi scan results are only
  # available to app bundles granted Location Services, so a command-line
  # tool can't read them itself. The app is compiled once (needs the Xcode
  # command-line tools) and launched through `open` so macOS attributes the
  # location permission to it rather than to the terminal.
  class WifiHelper
    SOURCE_DIR = File.join(__dir__, "wifi_helper")

    def initialize(dir: File.join(Dir.home, ".config", "merlin"))
      @app = File.join(dir, "MerlinWiFi.app")
    end

    # "authorized" | "denied" | "restricted" | "undetermined". Shows macOS's
    # location prompt the first time (the user has up to 2 minutes).
    def authorize = run("authorize", timeout: 130)

    def authorized? = authorize == "authorized"

    # Current network name, or nil when unknown (not connected / no permission).
    def current_ssid = run("ssid").then { _1.empty? ? nil : _1 }

    # Names of networks in range (empty without permission).
    def scan = run("scan").split("\n")

    def run(command, timeout: 15)
      build_if_needed
      out = File.join(Dir.tmpdir, "merlin-wifi-#{SecureRandom.hex(6)}")
      system("open", "-n", "-g", @app, "--args", command, out, out: File::NULL, err: File::NULL) or
        raise Error, "could not launch the Merlin Wi-Fi helper"
      deadline = Time.now + timeout
      sleep 0.1 until File.exist?(out) || Time.now > deadline
      raise Error, "the Merlin Wi-Fi helper did not answer (#{command})" unless File.exist?(out)

      File.read(out).strip
    ensure
      FileUtils.rm_f([out, "#{out}.tmp"]) if out
    end

    private

    def source_digest = Digest::SHA256.hexdigest(File.read(File.join(SOURCE_DIR, "main.swift")) +
                                                 File.read(File.join(SOURCE_DIR, "Info.plist")))

    # Rebuilt only when the source changes (a new build may make macOS ask for
    # location access again).
    def build_if_needed
      stamp = File.join(@app, "Contents", "Resources", "source.sha256")
      return if File.exist?(stamp) && File.read(stamp) == source_digest

      raise Error, "the Xcode command-line tools are needed (xcode-select --install)" unless system("which", "swiftc", out: File::NULL)

      macos = File.join(@app, "Contents", "MacOS")
      FileUtils.rm_rf(@app)
      FileUtils.mkdir_p([macos, File.dirname(stamp)])
      FileUtils.cp(File.join(SOURCE_DIR, "Info.plist"), File.join(@app, "Contents", "Info.plist"))
      out, status = Open3.capture2e("swiftc", "-O", "-o", File.join(macos, "merlin-wifi"), File.join(SOURCE_DIR, "main.swift"))
      raise Error, "building the Merlin Wi-Fi helper failed: #{out.lines.grep(/error/).first || out}" unless status.success?

      out, status = Open3.capture2e("codesign", "-s", "-", "--force", @app)
      raise Error, "signing the Merlin Wi-Fi helper failed: #{out}" unless status.success?

      File.write(stamp, source_digest)
    end
  end
end
