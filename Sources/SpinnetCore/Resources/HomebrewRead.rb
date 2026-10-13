# Fixed read-only command dispatcher; no Plugin chooses Ruby, paths or code.
require_relative 'HomebrewSourceGuard'
command = ARGV.shift
if command == 'host-trust'
  kind = ARGV.shift
  abort 'Unsupported Host trust query' unless %w[tap formula cask].include?(kind) && ARGV.size.between?(1, 50) &&
    ARGV.all? { |name| name.bytesize <= 200 && name.match?(/\A[a-z0-9][a-z0-9+_.@-]*(?:\/[a-z0-9][a-z0-9+_.@-]*){1,2}\z/) }
  # Match current Homebrew's persisted remote/reference semantics. The guard
  # disables qualified-argv temporary grants and implicit custom CoreTap trust.
  accepted = ARGV.select { |name| Homebrew::Trust.trusted?(kind.to_sym, name) }
  puts accepted.to_json
  exit 0
end
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
