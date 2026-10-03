# frozen_string_literal: true

module Merlin
  module TUI
    # IO-like sink for Sync's output, safe to read from the UI thread.
    # Understands "\r" (progress lines rewrite themselves).
    class SyncLog
      def initialize
        @lines = [+""]
        @mutex = Mutex.new
      end

      def print(*parts)
        @mutex.synchronize do
          parts.join.scan(/\r|\n|[^\r\n]+/) do |tok|
            case tok
            when "\r" then @lines[-1] = +""
            when "\n" then @lines << +""
            else @lines[-1] << tok
            end
          end
        end
        nil
      end

      def puts(*parts)
        parts = [""] if parts.empty?
        parts.each { |p| print(p.to_s.end_with?("\n") ? p.to_s : "#{p}\n") }
        nil
      end

      def lines
        @mutex.synchronize { @lines.last.empty? ? @lines[0..-2] : @lines.dup }
      end
    end

    # Wifi for the TUI: same automatic switching, plus what the sync screen
    # needs to show its full-screen "switch the speaker on" prompt.
    class TuiWifi
      # waiting: { ssid:, status: } while looking for the speaker's network.
      attr_reader :waiting

      def initialize(network:, log:)
        @wifi = Wifi.new(network: network, out: log, on_status: ->(msg) { @waiting = @waiting&.merge(status: msg) })
      end

      def remember_home! = @wifi.remember_home!
      def home_ssid = @wifi.home_ssid
      def rejoin_speaker = @wifi.rejoin_speaker
      def restore = @wifi.restore

      def join_speaker(ssid, password)
        @waiting = { ssid: ssid, status: Wifi::ASK }
        @wifi.join_speaker(ssid, password)
      ensure
        @waiting = nil
      end
    end

    # One synchronisation running in a background thread.
    #
    # The session is "finished" as soon as the speaker part is over (its
    # outcome is known); getting back online and reporting to Merlin happens
    # afterwards, still in the background thread ("reporting?").
    class SyncSession
      attr_reader :log, :wifi, :state, :error

      attr_reader :isolation

      def initialize(app, isolate: true)
        @log = SyncLog.new
        @wifi = TuiWifi.new(network: app.network, log: @log)
        @isolation = app.isolation if isolate # shared for the whole session (one password)
        @isolation&.out = @log
        opts = { out: @log, wifi: @wifi, on_transfer_end: ->(report) { @state = outcome(report) } }
        opts[:isolation] = @isolation if @isolation
        @sync = app.new_sync(**opts)
        @state = :idle
      end

      def start
        @state = :running
        @thread = Thread.new do
          @sync.run
          @state = :done if running?
        rescue Interrupt
          @log.puts "Aborted."
          @state = :aborted if running?
        rescue StandardError => e
          @error = e
          @log.puts "Error: #{e.message}"
          @state = :failed if running?
        end
        @thread.report_on_exception = false
        self
      end

      def running? = @state == :running
      def finished? = %i[done failed aborted].include?(@state)
      def reporting? = finished? && @thread&.alive?
      def abort! = @thread&.raise(Interrupt)
      def join(timeout = nil) = @thread&.join(timeout)

      # Leaving the app: let a sync that is reconnecting / reporting finish
      # (bounded: Wi-Fi restore and the internet wait are both time-limited).
      def shutdown
        @thread&.join(60)
      end

      private

      def outcome(report)
        return :done if report[:status] == "SUCCESS"

        report[:status_code].to_s.start_with?("800") ? :aborted : :failed
      end
    end

    module Screens
      class SyncScreen < ListScreen
        def initialize(app)
          super
          @isolate = true
        end

        attr_reader :session

        def title = "Sync"
        def busy? = @session&.running? || false

        def hints
          return [%w[↑↓ move], %w[enter select], %w[esc back]] unless @session
          return [%w[esc back]] if @session.finished?

          [%w[ctrl-c abort]]
        end

        def intro
          speaker = app.current_speaker&.dig("speaker_name") || "your speaker"
          [
            "Transfer the basket#{" (#{app.basket_count} pending)" if app.basket_count} and your account's content to #{speaker}.",
            "Files are downloaded first while you're online. Then you'll be asked to switch the speaker's " \
            "Wi-Fi on: this Mac joins it by itself, and reconnects to your usual network at the end."
          ]
        end

        def build_rows
          [Row.item("Start transfer", :start),
           Row.item("Block this Mac's other traffic (admin password): " \
                    "#{@isolate ? 'ON' : 'off (speaker may crash)'}", :isolate)]
        end

        def handle(event)
          return super unless @session

          if @session.finished?
            # Leaving is fine: a pending report keeps going in the background.
            app.pop if %i[esc left enter backspace].include?(event.to_sym)
          elsif event == :ctrl_c || event == :esc
            @session.abort!
            app.notify("Aborting…")
          end
        end

        def activate(row)
          case row.value
          when :isolate
            @isolate = !@isolate
            @rows = nil
          when :start
            session = SyncSession.new(app, isolate: @isolate)
            return unless authorize(session)

            @session = session.start
            app.active_sync = @session
          end
        end

        def render(frame, area)
          return super unless @session

          return render_speaker_prompt(frame, area, @session.wifi.waiting) if @session.wifi.waiting

          log_area = area
          lines = @session.log.lines
          lines += ["", result_line] if @session.finished?
          visible = [log_area.height - 2, 1].max
          frame.render_widget(tui.paragraph(text: lines.last(visible).join("\n"),
                                            block: tui.block(title: " Transfer — #{state_label} ", borders: [:all],
                                                             border_style: app.style(fg: border_color))), log_area)
        end

        private

        # sudo asks for the admin password on the real terminal, so step out of
        # the full-screen UI for it (once, before downloads start).
        def authorize(session)
          return true unless session.isolation
          return true if session.isolation.authorized? # granted at startup or by an earlier sync

          app.suspend do
            puts "\nThe speaker crashes when this Mac's other traffic reaches it, so a temporary"
            puts "network filter is applied during the transfer. macOS needs your admin password:"
            session.isolation.authorize!
          end
          true
        rescue Error => e
          app.error("#{e.message} — turn the traffic filter off to sync without it")
          false
        end

        def state_label
          @session.reporting? ? "#{@session.state} · reporting to Merlin" : @session.state.to_s
        end

        # Full screen while waiting for the speaker's network: the one thing the
        # user has to do. The Mac joins by itself as soon as the network appears.
        def render_speaker_prompt(frame, area, waiting)
          text = [
            tui.line(spans: [tui.span(content: "Switch on the speaker's Wi-Fi", style: app.style(fg: :yellow, modifiers: [:bold]))], alignment: :center),
            tui.line(spans: []),
            tui.line(spans: [tui.span(content: "1. Switch the speaker on")], alignment: :center),
            tui.line(spans: [tui.span(content: "2. Press its Wifi / Transfert button")], alignment: :center),
            tui.line(spans: []),
            tui.line(spans: [tui.span(content: "This Mac joins #{waiting[:ssid]} by itself as soon as it appears,", style: app.style(fg: :gray))], alignment: :center),
            tui.line(spans: [tui.span(content: "and reconnects to #{@session.wifi.home_ssid || 'your usual network'} when the transfer is over.", style: app.style(fg: :gray))], alignment: :center),
            tui.line(spans: []),
            tui.line(spans: [tui.span(content: "⏳ #{waiting[:status]}", style: app.style(fg: :cyan))], alignment: :center)
          ]
          _, box, = tui.layout_split(area, direction: :vertical,
                                           constraints: [tui.constraint_fill(1), tui.constraint_length(text.size + 2), tui.constraint_fill(1)])
          frame.render_widget(tui.paragraph(text: text, wrap: true,
                                            block: tui.block(borders: [:all], border_style: app.style(fg: :yellow))), box)
        end
        
        def result_line
          case @session.state
          when :done then "✔ Transfer complete. Press Esc to go back."
          when :aborted then "Transfer aborted. Press Esc to go back."
          else "✘ Transfer failed. API call details: #{app.config.log_dir}/. Press Esc to go back."
          end
        end

        def border_color
          { done: :green, failed: :red, aborted: :red }.fetch(@session.state, :cyan)
        end
      end
    end
  end
end
