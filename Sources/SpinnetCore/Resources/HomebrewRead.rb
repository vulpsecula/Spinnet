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
if command == 'doctor'
  # Bind the narrow result-annotation seam to reviewed upstream source. The
  # Host needs check identity, not English text matching, to assess context.
  {
    'cmd/doctor.rb' => '4aa3455bcf19e86d80ffab2233203eff3b85a954471cbc9cfd01583e1bd235b8',
    'diagnostic.rb' => 'ddbc104101690c2ab8365dd057d69fdec756e29ff71d431c2809d3eac0247d30',
    'diagnostic/finding.rb' => '5f299cfd51dc0bf0c49741b6579b544cf9a693ff68800d611c5948cbcfb1f702'
  }.each do |file, expected|
    unless Digest::SHA256.file(HOMEBREW_LIBRARY_PATH/file).hexdigest == expected
      warn '__SPINNET_DOCTOR_SOURCE_UNREVIEWED__'
      exit 79
    end
  end
end
require "cmd/#{command}"
if command == 'doctor'
  module SpinnetDoctorCheckIdentity
    def public_send(method, *args, **kwargs, &block)
      result = super
      if method.to_s.match?(/\Acheck_[a-z0-9_]+\z/)
        Array(result).each do |finding|
          finding.instance_variable_set(:@spinnet_doctor_check, method.to_s) if finding.is_a?(Homebrew::Diagnostic::Finding)
        end
      end
      result
    end
  end
  module SpinnetDoctorFindingIdentity
    def to_h
      result = super
      check = instance_variable_get(:@spinnet_doctor_check)
      check ? result.merge(check: check) : result
    end
  end
  Homebrew::Diagnostic::Checks.prepend(SpinnetDoctorCheckIdentity)
  Homebrew::Diagnostic::Finding.prepend(SpinnetDoctorFindingIdentity)
end
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
