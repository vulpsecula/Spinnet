# frozen_string_literal: true
# A sealed Host resource. Homebrew remains the logged-in user. Plugins never
# supply this Ruby source or sudo argv. Compatibility binds reviewed source bytes.
require "json"
require "digest"
require "system_command"
require "cask/installer"
require "cask/artifact/pkg"
REVIEWED_SOURCE_DIGESTS = {
  "system_command.rb" => "d93225d58e4e8f58644a3025aee1e67bc7c1de93cc812dc40ca8c5db1285f305",
  "cask/artifact/pkg.rb" => "35580f7ba61ac3b5bd3ad833519808dd23f368b436d2779c4c288c712775e3b2",
  "cask/installer.rb" => "7043f72f6cea608eb1d12e1bcb545576657975fe822605dcdc45d15738a3c21d",
  "cask/download.rb" => "ec2a119267476575af84f43ffca2043daaba7ee1709b68f2961c88276f9709e1",
  "cmd/install.rb" => "6a90402002006656a5bf6860dd9420971a930c05179213f9dcc53f0b624329e6",
  "cmd/upgrade.rb" => "f66478d9a273ef56be511aeb22fa565f97d81e7c29808af369e0460f66589984",
  "cmd/reinstall.rb" => "d8bbba249a700e905f7180d367514fe1642c5781c36332048053d87c0bc74df8",
  "cmd/uninstall.rb" => "6caafdb7808550dc6dc9918692b545969c81ec134b540bf6ffb9fbcbfc0dcd72",
  "trust.rb" => "0c40d55f481127ee83318439a46a1204c9ffe6691cc0a7143e89819baf794e3a"
}
REVIEWED_SOURCE_DIGESTS.each do |path, expected|
  abort "This Homebrew source revision needs privileged adapter review" unless Digest::SHA256.file(HOMEBREW_LIBRARY_PATH/path).hexdigest == expected
end
abort "Spinnet privileged bridge accepts no source arguments" unless ARGV.length == 1
context = JSON.parse(File.read(ARGV.fetch(0), 65_537))
abort "Invalid Spinnet privilege context" unless context.is_a?(Hash) && context["arguments"].is_a?(Array)
SPINNET_PRIVILEGE_CONTEXT = context.freeze

module SpinnetRejectUnreviewedSudo
  def sudo_prefix
    raise "Spinnet refuses this unreviewed privileged Homebrew command; use Homebrew directly after reviewing its guidance"
  end
end
SystemCommand.prepend(SpinnetRejectUnreviewedSudo)
# Homebrew's cask preflight asks whether sudo exists before invoking the pkg
# artifact. Elevation is available through the signed client, while every
# ordinary sudo_prefix remains refused by the override above.
module SpinnetNativeElevationAvailable
  def sudo_available? = true
end
SystemCommand.singleton_class.prepend(SpinnetNativeElevationAvailable)
module SpinnetKeepConfirmedTrust
  def trust_fully_qualified_items!(names, type: nil)
    names.each do |name|
      parts = name.to_s.split("/")
      next unless parts.length == 3
      tap = Tap.fetch(parts[0..1].join("/"))
      raise "Source trust changed after Host Confirmation" unless tap.installed? && Homebrew::Trust.trusted_tap?(tap)
    end
    nil
  end
end
Homebrew::Trust.singleton_class.prepend(SpinnetKeepConfirmedTrust)
module SpinnetReviewedPkgInstaller
  def run_installer(command: SystemCommand, verbose: false)
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    raise "The confirmed cask package changed" unless binding && binding["version"] == cask.version.to_s && binding["sha256"] == cask.sha256.to_s
    raise "Installer choices or allowUntrusted require a separately reviewed native operation" if stanza_options[:choices] || stanza_options[:allow_untrusted]
    archive = cask.download
    raise "The verified cask download is unavailable" unless archive && archive.file? && Digest::SHA256.file(archive).hexdigest == binding["sha256"]
    raise "Only flat native installer packages are reviewed" unless path.file? && !path.symlink? && path.extname == ".pkg"
    relative = path.relative_path_from(cask.staged_path).to_s
    raise "The cask installer path escaped its package" if relative.start_with?("/") || relative.split("/").include?("..")
    client = SPINNET_PRIVILEGE_CONTEXT.fetch("client")
    result = command.run(client, args: ["--installer", binding.fetch("name"), path.to_s, Digest::SHA256.file(path).hexdigest, archive.to_s, relative, "--target", "/"], print_stdout: true)
    exit 70 if result.exit_status == 70
    raise "The reviewed native installer was refused, cancelled or failed" unless result.success?
  end
end
Cask::Artifact::Pkg.prepend(SpinnetReviewedPkgInstaller)
if context["mode"] == "verify"
  puts JSON.generate({ native_elevation: SystemCommand.sudo_available?, pkg_adapter: Cask::Artifact::Pkg.ancestors.include?(SpinnetReviewedPkgInstaller), task_bound: ENV["HOMEBREW_SPINNET_TASK_ID"] == "activity_verify", uid: Process.uid })
  exit 0
end
arguments = context.fetch("arguments")
raise "Unsupported privileged Homebrew operation" unless %w[install upgrade reinstall uninstall].include?(arguments.first)
require "cmd/#{arguments.first}"
klass = Homebrew::Cmd.const_get(arguments.shift.capitalize)
klass.new(arguments).run
