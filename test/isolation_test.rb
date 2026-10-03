# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/merlin"

class IsolationTest < Minitest::Test
  # Records every command instead of touching the real firewall.
  class FakeRunner
    attr_reader :calls
    attr_accessor :fail_on

    def initialize = @calls = []

    def call(argv, stdin)
      @calls << [argv, stdin]
      return ["pfctl: failed", false] if fail_on && argv.include?(fail_on)

      argv.include?("-E") ? ["No ALTQ support in kernel\npf enabled\nToken : 1234567890\n", true] : ["", true]
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @runner = FakeRunner.new
    @iso = Merlin::Isolation.new(state_path: File.join(@dir, "isolation.json"), interface: "en0", runner: @runner,
                                 out: StringIO.new)
  end

  def teardown = FileUtils.rm_rf(@dir)

  def test_rules_only_let_the_transfer_and_dhcp_out_of_the_speaker_subnet
    assert_equal <<~PF, @iso.rules
      pass out quick on en0 proto tcp from 192.168.4.0/24 to 192.168.4.1 port 50000
      pass out quick on en0 proto udp from any port 68 to any port 67
      block out quick on en0 from 192.168.4.0/24 to any
    PF
  end

  def test_enable_then_disable
    @iso.enable!
    assert @iso.active?
    assert_equal [%w[sudo -n pfctl -a com.apple/merlin -f -], %w[sudo -n pfctl -E]], @runner.calls.map(&:first)
    assert_equal @iso.rules, @runner.calls.first.last
    assert_equal({ "token" => "1234567890", "interface" => "en0" }, JSON.parse(File.read(File.join(@dir, "isolation.json"))))

    @iso.disable!
    refute @iso.active?
    refute @iso.leftover?
    assert_equal [%w[sudo -n pfctl -a com.apple/merlin -F all], %w[sudo -n pfctl -X 1234567890]], @runner.calls.last(2).map(&:first)
  end

  def test_leftover_from_a_crashed_run_is_cleaned_before_enabling
    File.write(File.join(@dir, "isolation.json"), JSON.generate(token: "42"))
    @iso.enable!
    assert_equal [%w[sudo -n pfctl -a com.apple/merlin -F all], %w[sudo -n pfctl -X 42],
                  %w[sudo -n pfctl -a com.apple/merlin -f -], %w[sudo -n pfctl -E]], @runner.calls.map(&:first)
  end

  def test_failures_raise_merlin_errors
    @runner.fail_on = "-E"
    err = assert_raises(Merlin::Error) { @iso.enable! }
    assert_match(/pfctl -E failed/, err.message)
  end

  def test_authorize_uses_sudo_prompt
    asked = nil
    @iso.define_singleton_method(:system) { |*cmd| (asked = cmd) && true }
    assert @iso.authorize!
    assert_equal %w[sudo -v], asked
    @iso.disable! # stops the keepalive thread
  end
end
