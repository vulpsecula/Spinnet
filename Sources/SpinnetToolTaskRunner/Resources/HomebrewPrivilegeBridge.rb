# frozen_string_literal: true
# A sealed Host resource. Homebrew remains the logged-in user. Plugins never
# supply this Ruby source or sudo argv. Compatibility binds reviewed source bytes.
require "json"
require "digest"
require "uri"
require "system_command"
require "cask/installer"
require "cask/artifact/pkg"
require "cask/artifact/installer"
require "cask/artifact/generated_script"
require "cask/artifact/abstract_uninstall"
require "cask/artifact/zap"
REVIEWED_SOURCE_DIGESTS = {
  "cask/artifact/abstract_uninstall.rb" => "3152d4adf64750268a60b5ed2ff314528f852f19ba8dc3ee83a6855fb71f2eef",
  "cask/artifact/zap.rb" => "722bd89abedff09520691bbdf1637191c30affb78ef88d8b47309aef821c5a74",
  "cask/artifact/uninstall.rb" => "aef1b0af20468642a6f701055822690af04b3ed1bb995d39891c4d17e9d1001d",
  "system_command.rb" => "d93225d58e4e8f58644a3025aee1e67bc7c1de93cc812dc40ca8c5db1285f305",
  "cask/artifact/pkg.rb" => "35580f7ba61ac3b5bd3ad833519808dd23f368b436d2779c4c288c712775e3b2",
  "cask/artifact/installer.rb" => "9fe1be61de33e1daf58a74fac19400cac19ef23e54398a934fc9754fc2214e23",
  "cask/artifact/generated_script.rb" => "0d054e305b0e7922488e07899a436e27f7adb9e16af08cff031bee77e2c3da12",
  # Homebrew dd2a8cf5: equivalent conditional assignment in read_script_arguments.
  "cask/artifact/abstract_artifact.rb" => "4777d8ff029670880ea35fc1be32e5e6660f13546cf5ad8aed2b323d257432f3",
  "cask/installer.rb" => "7043f72f6cea608eb1d12e1bcb545576657975fe822605dcdc45d15738a3c21d",
  "cask/download.rb" => "ec2a119267476575af84f43ffca2043daaba7ee1709b68f2961c88276f9709e1",
  "cmd/install.rb" => "23e54ecfcba3a27d33e9c32d591ecf6ed0465b2417cc946228b98c9b305a2746",
  "cmd/upgrade.rb" => "9189a898e8e131bee4c120def946db3f42ed2f74bf53ea3f717c6e3ddf329ba7",
  "cmd/reinstall.rb" => "d8bbba249a700e905f7180d367514fe1642c5781c36332048053d87c0bc74df8",
  "cmd/uninstall.rb" => "6caafdb7808550dc6dc9918692b545969c81ec134b540bf6ffb9fbcbfc0dcd72",
  "trust.rb" => "0c40d55f481127ee83318439a46a1204c9ffe6691cc0a7143e89819baf794e3a"
}
# Complete reviewed Homebrew 3073d6a snapshot; never accept arbitrary mixtures
# of old/new private dispatchers and installer code.
REVIEWED_SOURCE_UPDATES = {
  "cask/artifact/abstract_uninstall.rb" => "474917562f4a7e404b6a8e1b7372b0abd4337de29f1d8ffaa081cc405d747e5f",
  "cask/artifact/zap.rb" => "b37740fcf730a86f690fc74ff6b1386c2da9b8c9604cc748800085ad47a3b312",
  "cask/artifact/uninstall.rb" => "3da21343c450a3fd644fb8bfe1efa80a8709da161ceac3279bd8b133ac3bb6e9",
  "cask/installer.rb" => "dfd30f709840fc9b8adc92659c361a9c8057a9b33bfddc5e8358a3b91ed5cbfc",
  "cmd/upgrade.rb" => "f855d2854c84c3c20bd6ffe1985c7b99ff445f1f4d9e40b4212ba8a6ac7db0c7"
}
REVIEWED_SOURCE_COHORTS = [REVIEWED_SOURCE_DIGESTS, REVIEWED_SOURCE_DIGESTS.merge(REVIEWED_SOURCE_UPDATES)].freeze
actual_sources = REVIEWED_SOURCE_DIGESTS.keys.to_h do |path|
  [path, Digest::SHA256.file(HOMEBREW_LIBRARY_PATH/path).hexdigest]
end
abort "This Homebrew source revision needs privileged adapter review" unless REVIEWED_SOURCE_COHORTS.include?(actual_sources)
abort "Spinnet privileged bridge accepts no source arguments" unless ARGV.length == 1
context = JSON.parse(File.read(ARGV.fetch(0), 1_048_577))
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
module SpinnetFrozenCaskDownloads
  def fetch(quiet: nil, verify_download_integrity: true, timeout: nil)
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    snapshot = binding && binding["downloadSnapshot"]
    return super unless snapshot
    raise "The confirmed no-check source changed" unless cask.sha256.to_s == "no_check" && cask.version.to_s == binding["version"] && cask.url.to_s == snapshot["sourceURL"]
    uri = URI.parse(snapshot.fetch("fileURL"))
    raise "The frozen download path is invalid" unless uri.scheme == "file" && (uri.host.nil? || uri.host.empty?)
    path = Pathname(URI::DEFAULT_PARSER.unescape(uri.path))
    raise "The frozen download changed; no latest retry was performed" unless path.file? && !path.symlink? && Digest::SHA256.file(path).hexdigest == binding.fetch("sha256")
    quarantine(path)
    path
  end
end
Cask::Download.prepend(SpinnetFrozenCaskDownloads)
module SpinnetReviewedPkgInstaller
  def run_installer(command: SystemCommand, verbose: false)
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    raise "The confirmed cask package changed" unless binding && binding["version"] == cask.version.to_s && (binding["downloadSnapshot"] ? "no_check" : binding["sha256"]) == cask.sha256.to_s
    relative = path.relative_path_from(cask.staged_path).to_s
    options = (binding["packageInstallers"] || []).find { |item| item["path"] == relative }
    raw_choices = Array(stanza_options[:choices])
    toggles = raw_choices.all? { |item| item.is_a?(String) } ? raw_choices : []
    choices = toggles.empty? ? raw_choices.map do |item|
      raise "The installer choice format changed" unless item.is_a?(Hash) && item.keys.map(&:to_s).sort == %w[attributeSetting choiceAttribute choiceIdentifier]
      item = item.transform_keys(&:to_s)
      attribute = item.fetch("choiceAttribute")
      if attribute == "customLocation"
        raise "The installer custom location changed" unless item["attributeSetting"].is_a?(String)
        next({ "identifier" => item.fetch("choiceIdentifier"), "selected" => false, "attribute" => "customLocation", "customLocation" => item.fetch("attributeSetting") })
      end
      raise "The installer choice attribute changed" unless %w[selected enabled visible].include?(attribute) && [0, 1, false, true].include?(item["attributeSetting"])
      choice = { "identifier" => item.fetch("choiceIdentifier"), "selected" => item.fetch("attributeSetting") == 1 || item.fetch("attributeSetting") == true }
      choice["attribute"] = attribute unless attribute == "selected"
      choice
    end : []
    raise "The confirmed native package options changed" unless (options ? options["choices"] || [] : []) == choices && (options ? options["choiceToggles"] || [] : []) == toggles && (options ? options["allowUntrusted"] : false) == (stanza_options[:allow_untrusted] == true)
    archive = cask.download
    raise "The verified cask download is unavailable" unless archive && archive.file? && Digest::SHA256.file(archive).hexdigest == binding["sha256"]
    raise "The native installer package changed" unless path.exist? && !path.symlink? && %w[.pkg .mpkg].include?(path.extname.downcase)
    raise "The cask installer path escaped its package" if relative.start_with?("/") || relative.split("/").include?("..")
    client = SPINNET_PRIVILEGE_CONTEXT.fetch("client")
    result = command.run(client, args: ["--installer", binding.fetch("name"), path.to_s, binding.fetch("sha256"), archive.to_s, relative, "--target", "/"], print_stdout: true)
    exit 70 if result.exit_status == 70
    exit 79 if result.exit_status == 79
    raise "The reviewed native installer was refused, cancelled or failed" unless result.success?
  end
end
Cask::Artifact::Pkg.prepend(SpinnetReviewedPkgInstaller)
module SpinnetReviewedVendorInstaller
  def install_phase(adopt: false, auto_updates: false, force: false, verbose: false, predecessor: nil, command: SystemCommand)
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    return super unless binding
    if manual_install
      raise "The confirmed manual installer changed" unless (binding["manualInstallers"] || []).include?(path.to_s)
      marker = { taskID: SPINNET_PRIVILEGE_CONTEXT.fetch("taskID"), package: binding.fetch("name"), version: binding.fetch("version"), sha256: binding.fetch("sha256"), path: path.to_s }
      File.open(SPINNET_PRIVILEGE_CONTEXT.fetch("manualOutcome"), File::WRONLY | File::CREAT | File::EXCL, 0600) { |file| file.write(JSON.generate(marker)); file.flush; file.fsync }
      puts "Installation requires manual actions in #{cask.staged_path.join(path)}. Installation has not completed."
      exit 78
    end
    return super unless args[:sudo] == true
    raise "The confirmed cask version or download changed" unless binding["version"] == cask.version.to_s && (binding["downloadSnapshot"] ? "no_check" : binding["sha256"]) == cask.sha256.to_s
    relative = path.to_s.delete_prefix(cask.staged_path.to_s + "/")
    entries = binding["nativeScripts"] || []
    index = entries.index { |item| item["phase"] == "install" && item["executable"] == relative }
    raise "No frozen native vendor action exists" unless index
    entry = entries.fetch(index)
    raise "The native vendor arguments or input changed" unless entry.fetch("arguments") == Array(args[:args]).map(&:to_s) && entry["input"] == (args[:input].nil? ? nil : Array(args[:input]).join) && entry.fetch("mustSucceed") == (args[:must_succeed] != false)
    archive = cask.download
    raise "The immutable vendor download changed" unless archive&.file? && Digest::SHA256.file(archive).hexdigest == binding.fetch("sha256")
    result = command.run(SPINNET_PRIVILEGE_CONTEXT.fetch("client"), args: ["--vendor", binding.fetch("name"), index.to_s, binding.fetch("sha256"), archive.to_s], print_stdout: true)
    exit 70 if result.exit_status == 70
    exit 79 if result.exit_status == 79
    exit 78 if result.exit_status == 78
    raise "The reviewed vendor action was refused, cancelled or failed" unless result.success?
  end
end
Cask::Artifact::Installer.prepend(SpinnetReviewedVendorInstaller)
# Exact system-daemon removals are bound by the authenticated Host plan.
# Do not route Homebrew's general launchctl/rm sudo operations through the client.
module SpinnetReviewedUninstall
  def uninstall_script(directives, command:, directive_name: :script, force: false, **kwargs)
    executable, arguments = self.class.read_script_arguments(directives, "uninstall", { must_succeed: true, sudo: false }, { print_stdout: true }, directive_name)
    return super unless arguments[:sudo] == true
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    code = binding && binding["removalCode"]
    raise "No confirmed immutable old-version uninstall code" unless code
    phase = is_a?(Cask::Artifact::Zap) ? "zap" : "uninstall"
    phase = "early" + phase.capitalize if directive_name == :early_script
    entries = code.fetch("actions")
    index = entries.index { |item| item.fetch("recipeExecutable") == executable.to_s && item.fetch("script").fetch("phase") == phase }
    raise "The confirmed old-version code phase changed" unless index
    script = entries.fetch(index).fetch("script")
    raise "The confirmed old-version arguments/input changed" unless script.fetch("arguments") == Array(arguments[:args]).map(&:to_s) && script["input"] == (arguments[:input].nil? ? nil : Array(arguments[:input]).join) && script.fetch("mustSucceed") == (arguments[:must_succeed] != false)
    result = command.run(SPINNET_PRIVILEGE_CONTEXT.fetch("client"), args: ["--removal-code", binding.fetch("name"), index.to_s, code.fetch("download").fetch("sha256")], print_stdout: true)
    exit 70 if result.exit_status == 70
    exit 79 if result.exit_status == 79
    raise "The confirmed old-version code was refused, stopped or failed" unless result.success?
  end
  def spinnet_remove_paths(kind, paths, command:)
    return if paths.empty?
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    raise "No confirmed native data cleanup" unless binding
    phase = is_a?(Cask::Artifact::Zap) ? "zap" : "uninstall"
    phase += kind == :delete ? "Delete" : "Rmdir"
    actions = binding["pathRemovals"] || []
    index = actions.index { |item| item["phase"] == phase }
    raise "No frozen native cleanup phase" unless index
    action = actions.fetch(index)
    patterns = action.fetch("grant").fetch("directives").flat_map { |item| item.fetch("patterns") }
    raise "The confirmed native cleanup expressions changed" unless paths.map(&:to_s).all? { |path| patterns.include?(path) }
    result = command.run(SPINNET_PRIVILEGE_CONTEXT.fetch("client"), args: ["--remove-paths", binding.fetch("name"), index.to_s, action.fetch("grant").fetch("manifestSHA256")], print_stdout: true)
    exit 70 if result.exit_status == 70
    exit 79 if result.exit_status == 79
    raise "Reviewed native cleanup refused, stopped or partially failed; no retry" unless result.success?
  end
  def uninstall_kext(*identifiers, command:, **_kwargs)
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    grant = binding && binding["kernelExtensionRemoval"]
    raise "No confirmed native kernel-extension grant" unless grant && identifiers.sort == grant.fetch("identifiers")
    result = command.run(SPINNET_PRIVILEGE_CONTEXT.fetch("client"), args: ["--remove-kernel-extensions", binding.fetch("name"), grant.fetch("sha256")], print_stdout: true)
    exit 70 if result.exit_status == 70
    exit 79 if result.exit_status == 79
    raise "The confirmed kernel extension was refused, stopped or failed" unless result.success?
  end
  def uninstall_delete(*paths, command:, **_kwargs)
    spinnet_remove_paths(:delete, paths, command:)
  end
  def uninstall_rmdir(*paths, command:, **_kwargs)
    spinnet_remove_paths(:rmdir, paths, command:)
  end
  def uninstall_pkgutil(*identifiers, command:, **_kwargs)
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    raise "No confirmed receipt removal" unless binding
    exact = identifiers.flat_map do |pattern|
      bound = (binding["receiptPatterns"] || {})[pattern]
      raise "The confirmed receipt expression changed" unless bound && bound.is_a?(Array) && !bound.empty?
      bound
    end.uniq
    exact.each do |identifier|
      receipt = (binding["receipts"] || []).find { |item| item["identifier"] == identifier }
      raise "The confirmed receipt changed" unless receipt
      result = command.run(SPINNET_PRIVILEGE_CONTEXT.fetch("client"), args: ["--remove-receipt", binding.fetch("name"), identifier, receipt.fetch("manifestSHA256")], print_stdout: true)
      exit 70 if result.exit_status == 70
      exit 79 if result.exit_status == 79
      raise "Reviewed receipt removal was refused, cancelled or failed" unless result.success?
    end
  end
  def uninstall_launchctl(*services, command:, **_kwargs)
    return if services.empty?
    binding = SPINNET_PRIVILEGE_CONTEXT.fetch("casks").find { |item| item["name"] == cask.full_name || item["name"] == cask.token }
    raise "No confirmed native launch-service removal" unless binding
    phase = is_a?(Cask::Artifact::Zap) ? "zap" : "uninstall"
    grant = (binding["launchServiceRemovals"] || []).find { |item| item.fetch("phase") == phase }
    raise "The confirmed launch-service phase changed" unless grant && services.map(&:to_s).all? { |item| grant.fetch("declarations").include?(item) }
    result = command.run(SPINNET_PRIVILEGE_CONTEXT.fetch("client"), args: ["--remove-launch-services", binding.fetch("name"), phase, grant.fetch("manifestSHA256")], print_stdout: true)
    exit 70 if result.exit_status == 70
    exit 79 if result.exit_status == 79
    raise "Reviewed launch-service removal was refused, stopped or partially failed; no retry" unless result.success?
  end
end
Cask::Artifact::AbstractUninstall.prepend(SpinnetReviewedUninstall)
if context["mode"] == "verify"
  puts JSON.generate({ native_elevation: SystemCommand.sudo_available?, pkg_adapter: Cask::Artifact::Pkg.ancestors.include?(SpinnetReviewedPkgInstaller), task_bound: ENV["HOMEBREW_SPINNET_TASK_ID"] == "activity_verify", uid: Process.uid })
  exit 0
end
context.fetch("casks").each do |binding|
  next unless binding["installedFingerprint"]
  result = SystemCommand.run(SPINNET_PRIVILEGE_CONTEXT.fetch("client"), args: ["--installed-history-digest", binding.fetch("name"), HOMEBREW_PREFIX.to_s])
  raise "Installed cask history changed after Host Confirmation" unless result.success? && result.stdout.strip == binding.fetch("installedFingerprint")
end
arguments = context.fetch("arguments")
raise "Unsupported privileged Homebrew operation" unless %w[install upgrade reinstall uninstall].include?(arguments.first)
require "cmd/#{arguments.first}"
klass = Homebrew::Cmd.const_get(arguments.shift.capitalize)
klass.new(arguments).run
