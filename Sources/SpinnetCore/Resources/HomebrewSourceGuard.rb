# Host-owned loader boundary shared by reads, previews and Task preflight.
# A qualified Plugin selector is not a user's explicit Ruby trust decision.
require 'digest'
# Private loader seams are tied to reviewed source bytes. A new upstream
# implementation needs review before these guards can claim the same boundary.
if defined?(HOMEBREW_LIBRARY_PATH)
  {
    'trust.rb' => '0c40d55f481127ee83318439a46a1204c9ffe6691cc0a7143e89819baf794e3a',
    # Reviewed 19fe946, 3073d6a and 3849568 cohorts. Later revisions add
    # compatibility_version and local_patch_checksums API accessors. The Host
    # accepts a complete source cohort before this second loader check.
    'formulary.rb' => %w[739950efcc367eeb8a5b97830cb40d0137570d7cc0a881e4f9ed159c21a5d161 da062bf811e5b7ed0d1b02a9d4c7782490276d682f9d7be2327232697cdfe8f9 b4eae02fef6405002f22d1ab81187786cb103f7ec6967d58fcbb11918da1beac],
    'cask/cask_loader.rb' => 'b013adf5701f86159eca5bc2ebfa4957ef71971d5e1c0e804cf820f5f39636ff'
  }.each do |file, expected|
    unless Array(expected).include?(Digest::SHA256.file(HOMEBREW_LIBRARY_PATH/file).hexdigest)
      warn '__SPINNET_SOURCE_ADAPTER_UNREVIEWED__'
      exit 79
    end
  end
end
require 'trust'
require 'formulary'
require 'cask/cask_loader'
module SpinnetReadTrust
  def explicitly_allowed?(*args, **kwargs); false; end
  # AbstractCoreTap's API-mode implicit trust must not authorize executable
  # files from an installed checkout with a noncanonical actual Git origin.
  def trusted_tap?(tap)
    return true if explicitly_trusted_tap?(tap)
    if tap.installed? && tap.official?
      # CoreTap calls a configured HOMEBREW_CORE_GIT_REMOTE canonical, too.
      # A preference for a mirror/fork is not persistent source-code trust.
      return false unless tap.name.match?(/\Ahomebrew\/[a-z0-9][a-z0-9_.-]*\z/)
      origin = tap.git_repository.origin_url
      expected = "https://github.com/Homebrew/homebrew-#{tap.name.split('/').last}"
      return origin && !origin.empty? && Tap.same_remote?(origin, expected)
    end
    super
  end
  def trust_fully_qualified_items!(*args, **kwargs); nil; end
  def trust!(*args, **kwargs); raise('A reviewed read cannot change source trust'); end
  private :explicitly_allowed?
end
Homebrew::Trust.singleton_class.prepend(SpinnetReadTrust)
# brew.env must not turn a read grant into permission to load every tap.
module SpinnetReadTrustRequired
  def no_require_tap_trust?; false; end
end
Homebrew::EnvConfig.singleton_class.prepend(SpinnetReadTrustRequired)
$spinnet_unavailable_history = false
module SpinnetInstalledCaskData
  def load(config:)
    if @from_installed_caskfile
      @api_fallback = false
      unless path.extname == '.json'
        $spinnet_unavailable_history = true
        raise Cask::CaskUnavailableError.new(token, 'Installed Ruby history requires immutable source provenance; this read only loads installed JSON')
      end
      # Parse one bounded immutable snapshot. FromPathLoader's JSON branch
      # falls through to instance_eval for valid JSON scalars/arrays/null.
      # Never call that loader again after deciding installed history is data.
      begin
        bytes = File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          before = file.stat
          raise IOError, 'Installed JSON is not a bounded regular file' unless before.file? && before.size <= 4 * 1024 * 1024
          snapshot = file.read(4 * 1024 * 1024 + 1)
          after = file.stat
          raise IOError, 'Installed JSON changed while reading' unless snapshot.bytesize == before.size &&
            before.size == after.size && before.mtime == after.mtime && before.ctime == after.ctime
          snapshot.freeze
        end
        raise JSON::ParserError, 'Installed JSON exceeds its bound' if bytes.bytesize > 4 * 1024 * 1024
        record = JSON.parse(bytes)
        raise JSON::ParserError, 'Installed JSON must be an object' unless record.is_a?(Hash)
        freeze_json = lambda do |value|
          case value
          when Hash; value.each { |key, child| key.freeze; freeze_json.call(child) }
          when Array; value.each { |child| freeze_json.call(child) }
          end
          value.freeze
        end
        freeze_json.call(record)
        return Cask::CaskLoader::FromAPILoader.new(
          token, from_json: record, path: path,
          from_installed_caskfile: true, from_internal_json: path.to_s.end_with?('.internal.json'),
          api_fallback: false,
        ).load(config: config)
      rescue JSON::ParserError, Cask::CaskInvalidError, Cask::CaskUnreadableError, SystemCallError, IOError, TypeError, KeyError, ArgumentError, NoMethodError => error
        $spinnet_unavailable_history = true
        raise Cask::CaskUnavailableError.new(token, 'Installed JSON is malformed or unavailable; Ruby fallback is forbidden')
      end
    elsif path.extname == '.rb' && !@tap
      $spinnet_unavailable_history = true
      raise Cask::CaskUnavailableError.new(token, 'Ruby outside a trusted tap is unavailable to this read')
    end
    super
  end
end
Cask::CaskLoader::FromPathLoader.prepend(SpinnetInstalledCaskData)

# Installed .brew recipes and detached Ruby caches have no current trusted-tap
# path authority. The official data-only API loader does not call this seam.
module SpinnetFormulaCodeSource
  def load_formula(name, path, *args, **kwargs)
    unless Tap.from_path(path.realpath) || Tap.from_path(path)
      $spinnet_unavailable_history = true
      raise FormulaUnavailableError, name
    end
    super
  end
end
Formulary.singleton_class.prepend(SpinnetFormulaCodeSource)
