# Fixed Host-owned read adapter. Never accepts a selector or mutation option.
require_relative 'HomebrewSourceGuard'
require 'stringio'
abort 'Unsupported reviewed autoremove preview' unless ARGV == ['--dry-run']
begin
require 'cmd/autoremove'
output = StringIO.new
original = $stdout
begin
  $stdout = output
  Homebrew.running_command = 'autoremove'
  Homebrew::Cmd::Autoremove.new(['--dry-run']).run
ensure
  $stdout = original
end
if $spinnet_unavailable_history
  warn '__SPINNET_INSTALLED_HISTORY_UNAVAILABLE__'
  exit 78
end
exit 1 if Homebrew.failed?
text = output.string
abort 'Autoremove preview exceeds its bound' if text.bytesize > 98304
lines = text.lines.map(&:strip).reject(&:empty?)
names = []
unless lines.empty?
  match = lines.shift.match(/\A(?:==> )?Would autoremove ([0-9]+) unneeded formulae?:\z/)
  abort 'Unsupported autoremove preview output' unless match && lines.size == match[1].to_i && lines.size <= 2000
  abort 'Invalid autoremove preview identities' unless lines.uniq.size == lines.size && lines.all? { |n| n.bytesize <= 160 && n.match?(/\A(?:[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*\z/) }
  names = lines
end
puts({stdout: text, names: names}.to_json)

rescue Homebrew::UntrustedTapError
  warn '__SPINNET_SOURCE_NOT_ALLOWED__'
  exit 77
end
