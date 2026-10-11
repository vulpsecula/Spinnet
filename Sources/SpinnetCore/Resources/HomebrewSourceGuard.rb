# Host-owned loader boundary shared by reads, previews and Task preflight.
# A qualified Plugin selector is not a user's explicit Ruby trust decision.
require 'digest'
# Private loader seams are tied to reviewed source bytes. A new upstream
# implementation needs review before these guards can claim the same boundary.
if defined?(HOMEBREW_LIBRARY_PATH)
  {
    'trust.rb' => '0c40d55f481127ee83318439a46a1204c9ffe6691cc0a7143e89819baf794e3a',
    'formulary.rb' => '739950efcc367eeb8a5b97830cb40d0137570d7cc0a881e4f9ed159c21a5d161',
    'cask/cask_loader.rb' => 'b013adf5701f86159eca5bc2ebfa4957ef71971d5e1c0e804cf820f5f39636ff'
  }.each do |file, expected|
    unless Digest::SHA256.file(HOMEBREW_LIBRARY_PATH/file).hexdigest == expected
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
