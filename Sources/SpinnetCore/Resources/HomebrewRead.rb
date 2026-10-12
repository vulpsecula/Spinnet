# Fixed read-only command dispatcher; no Plugin chooses Ruby, paths or code.
require_relative 'HomebrewSourceGuard'
command = ARGV.shift
allowed = %w[info outdated search list tap-info services doctor trust]
abort 'Unsupported reviewed read command' unless allowed.include?(command)
# Homebrew resolves aliases/renames before the guarded loader checks existing
# canonical item trust. A raw selector is not necessarily a trust target.
require "cmd/#{command}"
klass = Homebrew::AbstractCommand.command(command)
abort 'Unsupported reviewed Homebrew command implementation' unless klass
begin
  Homebrew.running_command = command
  klass.new(ARGV).run
  if $spinnet_unavailable_history
    warn '__SPINNET_INSTALLED_HISTORY_UNAVAILABLE__'
    exit 78
  end
rescue Homebrew::UntrustedTapError
  warn '__SPINNET_SOURCE_NOT_ALLOWED__'
  exit 77
end
exit(Homebrew.failed? ? 1 : 0)
