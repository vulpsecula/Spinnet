# Host-owned reviewed adapter. Only Homebrew 7.0.x is reviewed here.
# Input is constructed by HomebrewDryRunReads, never accepted from a Plugin.
require 'trust'
require 'tap'
require 'bottle'
abort 'Unsupported reviewed preview arguments' unless %w[install upgrade].include?(ARGV[0]) && ARGV[1..2] == ['--dry-run', '--no-ask']
args = ARGV.dup
kind = args[3]
abort 'Invalid package kind' unless %w[--formula --cask].include?(kind)
args.delete_at(4) if args[4] == '--greedy' && args[0] == 'upgrade' && kind == '--cask'
args.delete_at(4) if args[4] == '--adopt' && args[0] == 'install' && kind == '--cask' # Validate optional typed greedy flag separately.
names = args[5..]
abort 'Invalid package identities' unless args[4] == '--' && names&.length&.between?(1, 50) && names.all? { |n| n.match?(/\A(?:[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*\z/) }
# Homebrew's normal fully qualified install/upgrade implicitly trusts items.
# A preview must preserve trust; its loader still enforces existing trust.
module SpinnetPreviewTrust
  def trust_fully_qualified_items!(*, **) = nil
  def trust!(*, **) = raise('A preview cannot change source trust')
end
Homebrew::Trust.singleton_class.prepend(SpinnetPreviewTrust)
module SpinnetPreviewTap
  def ensure_installed!(*, **)
    raise 'A preview cannot install a missing tap' unless installed? || official?
  end
end
Tap.prepend(SpinnetPreviewTap)
# No subprocess networking. Missing manifests stay unknown, rather than
# fetching arbitrary URLs or inventing a size. Host may broker fixed metadata.
$spinnet_preview_requests = []
module SpinnetPreviewBottle
  def fetch_tab(timeout: nil, quiet: false)
    resource = github_packages_manifest_resource
    return unless resource
    if resource.downloaded?
      resource.verify_download_integrity(resource.cached_download)
      return
    end
    file = resource.cached_download.basename.to_s
    directory = ENV['SPINNET_PREVIEW_MANIFESTS']
    supplied = directory && Pathname.new(directory)/file
    if supplied&.file? && supplied.size <= 128 * 1024
      json = JSON.parse(supplied.read)
      ref = GitHubPackages.version_rebuild(@resource.version, rebuild, tag.to_s)
      annotations = json.fetch('manifests', []).filter_map { |m| m['annotations'] }.find do |a|
        a['sh.brew.bottle.digest'] == @resource.checksum.hexdigest && a['org.opencontainers.image.ref.name'] == ref
      end
      if annotations
        resource.manifest_annotations = annotations
        @spinnet_manifest_available = true
        return
      end
    end
    $spinnet_preview_requests << {name: name, url: resource.url, file: file} unless $spinnet_preview_requests.any? { |m| m[:url] == resource.url }
    warn "Warning: download size unavailable for #{name}; bottle manifest is not cached"
  end
  def bottle_size
    return github_packages_manifest_resource.bottle_size if @spinnet_manifest_available
    super
  end
end
Bottle.prepend(SpinnetPreviewBottle)
if ARGV[0] == 'install'
  require 'cmd/install'
  Homebrew::Cmd::InstallCmd.new(ARGV[1..]).run
else
  require 'cmd/upgrade'
  Homebrew::Cmd::UpgradeCmd.new(ARGV[1..]).run
end
puts '__SPINNET_MANIFEST_REQUESTS__' + $spinnet_preview_requests.to_json unless $spinnet_preview_requests.empty?
exit(Homebrew.failed? ? 1 : 0)
