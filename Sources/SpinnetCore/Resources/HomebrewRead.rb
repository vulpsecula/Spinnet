# Fixed read-only command dispatcher; no Plugin chooses Ruby, paths or code.
require_relative 'HomebrewSourceGuard'
command = ARGV.shift
allowed = %w[info outdated search list tap-info services doctor trust]
abort 'Unsupported reviewed read command' unless allowed.include?(command)
# Explicit persistent trust and source loading are distinct, even for an
# official-named tap with a custom remote. Homebrew retains its own identity
# checks, aliases, renames, migrations, and item-level persistent trust.
if %w[info].include?(command)
  kind = ARGV.include?('--cask') ? :cask : :formula
  ARGV.reject { |arg| arg.start_with?('-') }.each do |name|
    next unless name.match?(/\A[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9+_.@-]*\z/)
    unless Homebrew::Trust.trusted?(kind, name)
      warn '__SPINNET_SOURCE_NOT_ALLOWED__'
      exit 77
    end
  end
end
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
