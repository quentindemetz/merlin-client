# frozen_string_literal: true

require "ratatui_ruby"
require_relative "../merlin"
require_relative "tui/screens"
require_relative "tui/sync_session"
require_relative "tui/library_screens"

module Merlin
  # Full-screen terminal UI (ratatui_ruby) over the Backend / Sync APIs.
  #
  # Screens form a stack: Enter pushes, Esc pops. Each screen renders itself
  # into the body area and handles key events; the app draws the header
  # (account / speaker) and footer (status + key hints).
  module TUI
    class App
      attr_reader :config, :tui, :speaker_opts
      attr_accessor :basket_count

      # isolation_factory: ->(out:) { Isolation or nil } — the traffic filter used
      # during transfers (injectable so tests never touch the real firewall).
      def initialize(backend:, config:, speaker_opts: {}, sync_factory: nil, isolation_factory: nil)
        @backend = backend
        @config = config
        @speaker_opts = speaker_opts
        @sync_factory = sync_factory || method(:default_sync)
        @isolation_factory = isolation_factory || method(:default_isolation)
        @stack = []
        @status = nil
      end

      # stop_when: test hook evaluated every frame.
      def run(stop_when: nil)
        RatatuiRuby.run do |tui|
          @tui = tui
          push(Screens::MainMenu.new(self))
          until @stack.empty?
            draw
            break if stop_when&.call(self)

            event = tui.poll_event(timeout: 0.1)
            handle(event) unless event.none?
          end
        end
      ensure
        active_sync&.shutdown # a sync still waiting to report saves it for next time
      end

      # --- navigation ----------------------------------------------------------

      def screen = @stack.last

      def push(screen)
        @stack.push(screen)
        screen.on_enter
      end

      def pop
        @stack.pop
        screen&.on_resume
      end

      def quit = @stack.clear

      # --- shared state ----------------------------------------------------------

      def backend
        @backend.setting_id = config.setting_id
        @backend
      end

      def logged_in? = @backend.logged_in?

      def speakers
        @speakers ||= logged_in? ? backend.speakers : []
      end

      def current_speaker
        speakers.find { |s| s["id"].to_s == config.setting_id.to_s }
      end

      def select_speaker(speaker)
        config.setting_id = speaker["id"]
        @basket_count = nil
        notify "Speaker #{speaker['speaker_name'] || speaker['id']} selected"
      end

      def forget_account
        @speakers = nil
        @basket_count = nil
      end

      def refresh_basket_count
        @basket_count = logged_in? && config.setting_id ? Array(backend.selections).size : nil
      rescue OfflineError => e
        @basket_count = nil
        error(e.message)
      rescue Error
        @basket_count = nil
      end

      def new_sync(**) = @sync_factory.call(**)

      # Audio imported from this Mac for the selected speaker.
      def library = config.library
      def new_isolation(out:) = @isolation_factory.call(out: out)

      # Hands the real terminal back (e.g. for sudo's password prompt), then
      # resumes the full-screen UI.
      def suspend
        RatatuiRuby.restore_terminal
        yield
      ensure
        RatatuiRuby.init_terminal
      end

      # The most recent sync, which may still be reporting in the background.
      attr_accessor :active_sync

      # --- status / loading ------------------------------------------------------

      def notify(msg) = @status = [:ok, msg]
      def error(msg) = @status = [:error, msg]

      # Runs a (blocking) backend call with a "Loading…" status painted first.
      # Errors become a red status line and the block's result is nil.
      def load(label = "Loading…")
        @status = [:busy, label]
        draw if @tui
        result = yield
        @status = nil if @status&.first == :busy
        result
      rescue Error, SystemCallError, SocketError, IOError, JSON::ParserError => e
        error(e.message)
        nil
      end

      # --- rendering -------------------------------------------------------------

      # ratatui forbids nested draws: data is loaded before painting, and a
      # draw requested while painting (App#load's "Loading…") is skipped.
      def draw
        return if @painting

        screen.rows if screen.respond_to?(:rows)
        @painting = true
        begin
          paint
        ensure
          @painting = false
        end
      end

      def style(**) = tui.style(**)

      private

      def paint
        tui.draw do |frame|
          header, body, status, hints = tui.layout_split(
            frame.area, direction: :vertical,
                        constraints: [tui.constraint_length(1), tui.constraint_fill(1),
                                      tui.constraint_length(1), tui.constraint_length(1)]
          )
          frame.render_widget(tui.paragraph(text: [header_line]), header)
          screen&.render(frame, body)
          frame.render_widget(tui.paragraph(text: [status_line]), status)
          frame.render_widget(tui.paragraph(text: [hints_line]), hints)
        end
      end

      def handle(event)
        if event.paste?
          screen.handle_paste(event.content) if screen.respond_to?(:handle_paste)
          return
        end
        return unless event.key?
        return quit if event == :ctrl_c && !screen.busy?

        @status = nil unless @status&.first == :busy
        screen.handle(event)
      rescue Error => e
        error(e.message)
      end

      def header_line
        spans = [tui.span(content: " Merlin ", style: style(fg: :black, bg: :cyan, modifiers: [:bold])), tui.span(content: " ")]
        if logged_in?
          name = current_speaker&.dig("speaker_name") || (config.setting_id ? config.setting_id.to_s : "no speaker selected")
          spans << tui.span(content: "🔈 #{name}", style: style(fg: :cyan))
          spans << tui.span(content: "  ·  basket: #{basket_count}", style: style(fg: :yellow)) if basket_count
        else
          spans << tui.span(content: "not logged in", style: style(fg: :dark_gray))
        end
        crumbs = @stack.drop(1).map(&:title).last(3).join(" › ")
        spans << tui.span(content: "   #{crumbs}", style: style(fg: :dark_gray)) unless crumbs.empty?
        tui.line(spans: spans)
      end

      def status_line
        kind, msg = @status
        color = { ok: :green, error: :red, busy: :yellow }[kind]
        tui.line(spans: [tui.span(content: " #{msg}", style: color && style(fg: color))])
      end

      def hints_line
        spans = (screen&.hints || []).flat_map do |key, label|
          [tui.span(content: " #{key} ", style: style(fg: :black, bg: :dark_gray)),
           tui.span(content: " #{label}  ", style: style(fg: :gray))]
        end
        tui.line(spans: spans)
      end

      def default_sync(out:, wifi:, on_transfer_end: nil, isolation: nil)
        Sync.new(backend: backend, cache_dir: config.cache_dir, wifi: wifi, speaker_opts: speaker_opts, out: out,
                 on_transfer_end: on_transfer_end, isolation: isolation, library: library)
      end

      def default_isolation(out:)
        config.isolation(out: out, speaker_ip: speaker_opts.fetch(:host, Speaker::DEFAULT_HOST),
                         port: speaker_opts.fetch(:port, Speaker::DEFAULT_PORT))
      end
    end
  end
end
