# Runs the complete sealed bridge inside the installed Homebrew bootstrap.
# Replace the selected command's mutating run method BEFORE loading the bridge.
# Class lookup, construction and the real CLI parser still run; package effects
# and native authorization clients cannot be reached.
require "json"
require "abstract_command"
bridge, context_path, mode = ARGV
context = JSON.parse(File.read(context_path))
operation = context.fetch("arguments").first
if %w[install upgrade reinstall uninstall].include?(operation)
  require "cmd/#{operation}"
  command = Homebrew::AbstractCommand.command(operation)
  raise "Upstream command is not registered" unless command
  command.prepend(Module.new do
    define_method(:initialize) do |arguments|
      @fixture_arguments = arguments.dup
      super(arguments)
    end
    define_method(:run) do
      puts JSON.generate({ command: operation, class: command.name, arguments: @fixture_arguments,
                           running_command: Homebrew.running_command_with_args, cask: args.cask?,
                           packages: args.named.to_a, uid: Process.uid })
    end
  end)
end
if mode == "missing"
  Homebrew::AbstractCommand.define_singleton_method(:command) { |_name| nil }
end
ARGV.replace([context_path])
load bridge
