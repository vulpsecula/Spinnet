# Loads exact upstream source snapshots without starting Homebrew. All leaf
# effects are replaced BEFORE invocation. The only command is an argv recorder.
require 'json'
require 'pathname'
require 'set'
source, bridge, mode = ARGV
module T
  class Type
    def self.[](*) = self
  end
  def self.const_missing(*) = Type
  def self.method_missing(*) = Type
  def self.cast(value, *) = value
end
class Array
  def exclude?(value) = !include?(value)
end
class Set
  def exclude?(value) = !include?(value)
end
class Module
  def sig(*) = nil # Ignore Sorbet annotation blocks, not executable methods.
end
module Formatter
  def self.identifier(*) = "fixture"
end
module Utils
  module Output
    module Mixin
      def odebug(*) = nil
      def ohai(*) = nil
      def oh1(*) = nil
      def opoo(*) = nil
    end
  end
  module Path; end
  module Data
    def self.assert_valid_keys(*) = nil
  end
  def self.pluralize(*) = 'fixture artifacts'
end
module SystemCommand
  module Mixin; end
end
# Upstream requires are not followed: dependencies are fixtures, so source
# evaluation cannot initialize a live Homebrew environment or service adapter.
module FixtureRequires
  def require(path)
    return false unless %w[json pathname set].include?(path)
    super
  end
  def system(*) = raise('Unexpected real system command')
  def exec(*) = raise('Unexpected real exec')
  def `(command) = raise('Unexpected real subprocess')
end
Kernel.prepend(FixtureRequires)
module Cask
  module Artifact
    class AbstractArtifact
      attr_reader :cask
      def initialize(cask, **) = @cask = cask
      def self.read_script_arguments(value, *)
        [value.fetch(:executable), {sudo: value[:sudo], args: value[:args], must_succeed: true}]
      end
    end
    %w[AbstractFlightBlock GeneratedCompletion KeyboardLayout Moved PostflightSteps PreflightSteps Qlplugin Symlinked UninstallPostflightSteps UninstallPreflightSteps].each { |name| const_set(name, Class.new) }
  end
end
%w[abstract_uninstall uninstall zap].each { |name| load File.join(source, "cask/artifact/#{name}.rb") }
load File.join(source, 'cask/installer.rb')
TRACE = []
module FixtureLeaves
  Cask::Artifact::AbstractUninstall::ORDERED_DIRECTIVES.reject { |directive| directive == :early_script }.each do |directive|
    define_method("uninstall_#{directive}") do |*args, **|
      TRACE << "#{is_a?(Cask::Artifact::Zap) ? 'zap' : 'uninstall'}:#{directive}"
    end
  end
end
Cask::Artifact::AbstractUninstall.prepend(FixtureLeaves)
# Freeze observable source classes; a failure here reveals accidental loading
# of a fixture implementation instead of the staged upstream method.
raise 'Wrong upstream installer' unless Cask::Installer.instance_method(:uninstall_artifacts).source_location.first == File.join(source, 'cask/installer.rb')
FakeCask = Struct.new(:artifacts) do
  def loaded_from_api? = true
  def full_name = 'fixture'
  def token = 'fixture'
end
class BoundaryArtifact
  def initialize(label, order) = (@label, @order = label, order)
  def uninstall_phase(**) = TRACE << @label
  def sort_order = {Cask::Artifact::Uninstall => 10, self.class => @order}
end
class Preflight < BoundaryArtifact; end
class Removable < BoundaryArtifact; end
class Postflight < BoundaryArtifact; end
class FixtureCommand
  def self.run(client, args:, **)
    raise 'Wrong client' unless client == '/fixture/sealed-client'
    TRACE << args
    Struct.new(:exit_status) { def success? = exit_status.zero? }.new(0)
  end
end
def artifact(klass, cask, directives)
  klass.new(cask, **directives)
end
def install_fixture(cask, uninstall, **flags)
  cask.artifacts = [Preflight.new('preflight', 0), uninstall, Removable.new('removable', 20), Postflight.new('postflight', 30)]
  instance = Cask::Installer.allocate
  instance.instance_variable_set(:@cask, cask)
  instance.instance_variable_set(:@command, FixtureCommand)
  instance.define_singleton_method(:artifacts) { cask.artifacts }
  instance.define_singleton_method(:verbose?) { false }
  instance.define_singleton_method(:force?) { false }
  instance.define_singleton_method(:upgrade?) { flags[:upgrade] == true }
  instance.define_singleton_method(:reinstall?) { flags[:reinstall] == true }
  instance.define_singleton_method(:load_installed_caskfile!) {}
  instance.define_singleton_method(:purge_caskroom_path) { TRACE << 'purge' }
  instance
end
DIRECTIVES = {quit: 'org.fixture', signal: ['TERM', 'org.fixture'], launchctl: 'org.fixture.daemon', pkgutil: 'org.fixture.receipt', delete: '/fixture/data', trash: '/fixture/trash', rmdir: '/fixture/empty'}.freeze
if mode == 'ordinary'
  cases = {}
  %i[upgrade reinstall].each do |operation|
    {default: nil, symbol: :signal, array: ['signal']}.each do |variant, opt|
      [true, false].each do |quit|
        TRACE.clear
        cask = FakeCask.new
        directives = DIRECTIVES.dup
        directives[:on_upgrade] = opt unless opt.nil?
        uninstall = artifact(Cask::Artifact::Uninstall, cask, directives)
        install_fixture(cask, uninstall, **{operation => true}).uninstall_artifacts(quit: quit)
        cases["#{operation}:#{variant}:#{quit}"] = TRACE.dup
      end
    end
  end
  puts JSON.generate(cases)
elsif mode == 'zap'
  cask = FakeCask.new
  uninstall = artifact(Cask::Artifact::Uninstall, cask, DIRECTIVES)
  zap = artifact(Cask::Artifact::Zap, cask, DIRECTIVES)
  installer = install_fixture(cask, uninstall)
  cask.artifacts << zap
  installer.zap
  puts JSON.generate(TRACE)
elsif mode == 'bridge'
  # Load the actual production prepend module verbatim. Full bridge bootstrap
  # intentionally remains guarded and is NOT exercised/approved by this proof.
  text = File.read(bridge)
  start = text.index("module SpinnetReviewedUninstall\n") or raise 'Missing bridge module'
  stop = text.index("Cask::Artifact::AbstractUninstall.prepend(SpinnetReviewedUninstall)", start) or raise 'Missing bridge prepend'
  eval(text[start...stop], TOPLEVEL_BINDING, bridge, text[0...start].count("\n") + 1)
  Cask::Artifact::AbstractUninstall.prepend(SpinnetReviewedUninstall)
  context = {'client' => '/fixture/sealed-client', 'casks' => []}
  Object.const_set(:SPINNET_PRIVILEGE_CONTEXT, context)
  binding = {'name' => 'fixture', 'receiptPatterns' => {'org.fixture.receipt' => ['org.fixture.exact']}, 'receipts' => [{'identifier' => 'org.fixture.exact', 'manifestSHA256' => 'receipt-seal'}], 'kernelExtensionRemoval' => {'identifiers' => ['org.fixture.kext'], 'sha256' => 'kext-seal'}, 'launchServiceRemovals' => [], 'pathRemovals' => [], 'removalCode' => {'download' => {'sha256' => 'code-seal'}, 'actions' => []}}
  %w[uninstall zap].each do |phase|
    binding['launchServiceRemovals'] << {'phase' => phase, 'declarations' => ['org.fixture.daemon'], 'manifestSHA256' => phase + '-service-seal'}
    %w[Delete Rmdir].each { |kind| binding['pathRemovals'] << {'phase' => phase + kind, 'grant' => {'manifestSHA256' => phase + kind + '-path-seal', 'directives' => [{'patterns' => [kind == 'Delete' ? '/fixture/data' : '/fixture/empty']}]}} }
    [phase, 'early' + phase.capitalize].each { |code_phase| binding['removalCode']['actions'] << {'recipeExecutable' => '/fixture/remove', 'script' => {'phase' => code_phase, 'arguments' => ['--remove'], 'mustSucceed' => true}} }
  end
  directives = DIRECTIVES.merge(kext: 'org.fixture.kext', script: {executable: '/fixture/remove', sudo: true, args: ['--remove']}, early_script: {executable: '/fixture/remove', sudo: true, args: ['--remove']})
  context['casks'] = [binding]
  cask = FakeCask.new
  uninstall = artifact(Cask::Artifact::Uninstall, cask, directives)
  zap = artifact(Cask::Artifact::Zap, cask, directives)
  installer = install_fixture(cask, uninstall)
  cask.artifacts << zap
  installer.zap
  accepted = TRACE.dup
  denied = []
  # Exercise the real low-level dispatch through each upstream artifact; an
  # absent phase, altered target, or absent owner must fail before client.run.
  %w[uninstall zap].each do |phase|
    klass = phase == 'zap' ? Cask::Artifact::Zap : Cask::Artifact::Uninstall
    {launchctl: 'wrong.daemon', pkgutil: 'wrong.receipt', delete: '/wrong/data', rmdir: '/wrong/empty', kext: 'wrong.kext', script: {executable: '/wrong/remove', sudo: true, args: ['--remove']}, early_script: {executable: '/wrong/remove', sudo: true, args: ['--remove']}}.each do |directive, wrong|
      [:wrong, :missing, :owner].each do |failure|
        saved = Marshal.load(Marshal.dump(binding))
        binding['name'] = 'other-fixture' if failure == :owner
        if failure == :missing
          key = {launchctl: 'launchServiceRemovals', pkgutil: 'receipts', delete: 'pathRemovals', rmdir: 'pathRemovals', kext: 'kernelExtensionRemoval', script: 'removalCode', early_script: 'removalCode'}.fetch(directive)
          binding.delete(key)
        end
        TRACE.clear
        item = artifact(klass, cask, {directive => failure == :wrong ? wrong : directives.fetch(directive)})
        begin
          item.dispatch_uninstall_directive(directive, command: FixtureCommand)
          raise "Expected grant refusal #{phase}:#{directive}:#{failure}"
        rescue StandardError => error
          raise if error.message.start_with?('Expected grant refusal')
          raise 'Refusal launched a client command' unless TRACE.empty?
          denied << "#{phase}:#{directive}:#{failure}"
        ensure
          binding.replace(saved)
        end
      end
    end
  end
  # An otherwise correct target in another phase never inherits its grant.
  %w[uninstall zap].each do |phase|
    klass = phase == 'zap' ? Cask::Artifact::Zap : Cask::Artifact::Uninstall
    [:launchctl, :delete, :rmdir, :script, :early_script].each do |directive|
      saved = Marshal.load(Marshal.dump(binding))
      if directive == :launchctl
        binding['launchServiceRemovals'].reject! { |item| item['phase'] == phase }
      elsif [:delete, :rmdir].include?(directive)
        binding['pathRemovals'].reject! { |item| item['phase'] == phase + (directive == :delete ? 'Delete' : 'Rmdir') }
      else
        code_phase = directive == :early_script ? 'early' + phase.capitalize : phase
        binding['removalCode']['actions'].reject! { |item| item['script']['phase'] == code_phase }
      end
      TRACE.clear
      begin
        artifact(klass, cask, {directive => directives.fetch(directive)}).dispatch_uninstall_directive(directive, command: FixtureCommand)
        raise 'Expected phase refusal'
      rescue StandardError => error
        raise if error.message == 'Expected phase refusal'
        raise 'Wrong phase launched a client command' unless TRACE.empty?
        denied << "#{phase}:#{directive}:phase"
      ensure
        binding.replace(saved)
      end
    end
  end
  puts JSON.generate({'accepted' => accepted, 'denied' => denied})
else
  raise 'Unknown fixture mode'
end
