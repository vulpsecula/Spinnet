# Host-only native metadata exporter. No Installer, downloads, saves, or detached
# installed Ruby evaluation. Private adapters are pinned before invocation.
require 'json'
require 'digest'
{
  'tap/abstract_core_tap.rb' => '580fa663435dc5caa04afbd1db4948924431943de0253139165456869cf35fb0',
  'tap/core_cask_tap.rb' => '5159c01629e803edb3f0469df4266cea246b5de44b34113cdd155bdcb19b27a0',
  'tap.rb' => '8ea9d6c46ef61dda3b9bfd7e580f8e8b81358245fbb3a2eb4154a66cf5f400f1',
  'api.rb' => '8863f378ac64fb5c678fc86e6b0b8a85349d864bdb1465ff3c90bbf49faee7fe',
  'api/homebrew-1.pem' => 'ef2d2c9e0219d485df9f07fff7b037feadc36c93085be9ffefb1390f31a3de1d',
  'api/internal.rb' => 'eb98dc96639bfa500261818f455fe894f6eda10150f5e62f1428a885586b2d03',
  'api/cask_struct.rb' => 'bab1b13ddd718f20d724ef6963a229d1a4a1eca2621a58213c6efb8dfa8f394f',
  'cask/config.rb' => 'e544e0730a19b54942bddeb75ac36063e6964f63ea1cce63688bac021be17e20',
  'extend/os/mac/cask/config.rb' => '0154133c94dab6d6d4b3452d796bed9f27cfaaf82a4e04b90b4024a0ca9507d2'
}.each do |file, expected|
  unless Digest::SHA256.file(HOMEBREW_LIBRARY_PATH/file).hexdigest == expected
    warn '__SPINNET_SOURCE_ADAPTER_UNREVIEWED__'
    exit 79
  end
end
require_relative 'HomebrewSourceGuard'
require 'api'
require 'api/internal'
require 'api/cask_struct'
require 'cask/config'
require 'cask/caskroom'

module SpinnetNativeMetadata
  def self.reject_source(reason)
    warn "__SPINNET_SOURCE_NOT_ALLOWED__: #{reason}"
    exit 77
  end
  def self.bounded_file(path, maximum)
    # Cache and saved config are data, never executable source authority.
    flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    File.open(path, flags) do |file|
      before = file.stat
      reject_source('metadata is not a bounded regular file') unless before.file? && before.size.between?(1, maximum)
      bytes = file.read(maximum + 1)
      after = file.stat
      reject_source('metadata changed while read') unless bytes.bytesize == before.size && bytes.bytesize <= maximum &&
        before.ino == after.ino && before.dev == after.dev && before.mtime == after.mtime && before.ctime == after.ctime
      bytes
    end
  rescue Errno::ENOENT
    warn '__SPINNET_NATIVE_METADATA_UNAVAILABLE__'
    exit 78
  end
  def self.config(token, language)
    explicit = language.empty? ? {} : { languages: [language] }
    requested = Cask::Config.new(explicit: explicit)
    path = Cask::Caskroom.path/token/'.metadata/config.json'
    bytes = path.exist? ? bounded_file(path, 256 * 1024) : nil
    saved = bytes ? Cask::Config.from_json(bytes, ignore_invalid_keys: true) : requested
    effective = requested.merge(saved)
    [requested, effective, bytes ? Digest::SHA256.hexdigest(bytes) : nil]
  end
  def self.git(tap, *args)
    # No shell, pager, optional locks, fsmonitor or caller environment.
    command = ['/usr/bin/git', '--no-pager', '--no-optional-locks', '-c', 'core.fsmonitor=false', '-C', tap.path.to_s, *args]
    value = IO.popen(command, 'rb') { |pipe| pipe.read(4 * 1024 * 1024 + 1) }
    reject_source('immutable Git source unavailable') unless $?.success? && value.bytesize <= 4 * 1024 * 1024
    value
  end
  def self.api_snapshot
    return @api_snapshot if @api_snapshot
    path = Homebrew::API::Internal.cached_packages_json_file_path
    raw = SpinnetNativeMetadata.bounded_file(path, 32 * 1024 * 1024)
    begin
      envelope = JSON.parse(raw)
      verified, payload = Homebrew::API.send(:verify_and_parse_jws, envelope)
    rescue JSON::ParserError, TypeError, NoMethodError, ArgumentError
      SpinnetNativeMetadata.reject_source('official API signature envelope is malformed')
    end
    SpinnetNativeMetadata.reject_source('official API signature invalid') unless verified && payload.is_a?(Hash)
    @api_snapshot = [payload, Digest::SHA256.hexdigest(raw)]
  end
  def self.artifacts(struct, appdir)
    struct.artifacts(appdir: appdir).map do |key, args, kwargs, block|
      values = args.dup
      values << kwargs unless kwargs.empty?
      values << { key => nil } if block
      { key => values }
    end
  end
end

# A fixed data-only configuration lane never loads a cask source.
if ARGV.first == '--configuration'
  token = ARGV[1]
  abort 'Invalid Host native configuration arguments' unless ARGV.length == 2 && token&.match?(/\A[a-z0-9][a-z0-9+_.@-]*\z/) && token.bytesize <= 200
  _, effective, = SpinnetNativeMetadata.config(token, '')
  puts JSON.generate({ home: Dir.home, prefix: HOMEBREW_PREFIX.to_s, appdir: effective.appdir.to_s })
  exit 0
end
requests = ARGV.each_slice(2).to_a
unless ARGV.length.between?(2, 200) && ARGV.length.even? && requests.all? { |name, language|
       name&.match?(/\A(?:[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*\z/) &&
       language&.match?(/\A(?:[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)?\z/) && language.bytesize <= 64 && name.bytesize <= 200 }
  abort 'Invalid Host native metadata arguments'
end
def SpinnetNativeMetadata.project(name, language)
  token = name.split('/').last
  requested, effective, config_hash = SpinnetNativeMetadata.config(token, language)
  tap = name.include?('/') ? Tap.fetch(name.split('/')[0..1].join('/')) : Tap.fetch('homebrew/cask')

  if tap.core_cask_tap? && tap.installed? && !tap.official_git_checkout?
    SpinnetNativeMetadata.reject_source('official-named noncanonical checkout has ambiguous native source authority')
  end

  if tap.core_cask_tap? && (!tap.installed? || tap.official_git_checkout?)
    # This always re-verifies the complete signed source, never trusts a payload
    # sidecar/index or a local JSON hash as publisher provenance.
    payload, source_digest = SpinnetNativeMetadata.api_snapshot
    record = payload.fetch('casks', {})[token]
    SpinnetNativeMetadata.reject_source('cask is absent from the verified official source') unless record.is_a?(Hash)
    source_hash = Digest::SHA256.hexdigest(JSON.generate(record))
    struct = Homebrew::API::CaskStruct.deserialize(record)
    localized = struct.localise(effective.languages)
    result = {
      name: "homebrew/cask/#{token}", version: localized.version.to_s,
      url: localized.url_args.first, sha256: localized.sha256.to_s,
      language: struct.language(effective.languages), effective_languages: effective.languages,
      artifacts: SpinnetNativeMetadata.artifacts(localized, effective.appdir),
      source: { kind: 'verified-api-jws', sha256: source_digest, record_sha256: source_hash,
                tap: 'homebrew/cask', git_head: payload['cask_tap_git_head'],
                ruby_source_path: record['ruby_source_path'], ruby_source_checksum: record['ruby_source_checksum'] },
      config: { requested_language: language.empty? ? nil : language, saved_sha256: config_hash,
                effective: JSON.parse(effective.to_json) }
    }
  else
    SpinnetNativeMetadata.reject_source('native third-party casks require a qualified identity') unless name.include?('/')
    tap.define_singleton_method(:implicitly_trusted?) { |remote: self.remote| official_git_checkout? }
    SpinnetNativeMetadata.reject_source('tap is not persistently trusted') unless Homebrew::Trust.trusted_tap?(tap) || Homebrew::Trust.trusted?(:cask, name)
    loader = Cask::CaskLoader::FromTapLoader.new(name)
    path = loader.path
    root = tap.path.realpath
    SpinnetNativeMetadata.reject_source('tap source is not a canonical Ruby path') unless path.extname == '.rb' && path.realpath == path && path.to_s.start_with?(root.to_s + '/')
    relative = path.relative_path_from(root).to_s
    head = SpinnetNativeMetadata.git(tap, 'rev-parse', '--verify', 'HEAD^{commit}').strip
    SpinnetNativeMetadata.reject_source('tap HEAD is unavailable') unless head.match?(/\A[0-9a-f]{40}\z/)
    blob = SpinnetNativeMetadata.git(tap, 'cat-file', 'blob', "#{head}:#{relative}")
    current = SpinnetNativeMetadata.bounded_file(path, 4 * 1024 * 1024)
    SpinnetNativeMetadata.reject_source('tap Ruby differs from its immutable HEAD blob') unless current == blob
    # The loader rereads this specific path after checking trust. Return the held
    # verified bytes, not a second mutable filesystem read before instance_eval.
    held = current.force_encoding(Encoding::UTF_8).freeze
    SpinnetNativeMetadata.reject_source('invalid source encoding') unless held.valid_encoding?
    path.define_singleton_method(:read) { |*args, **kwargs| held }
    candidate = loader.load(config: requested)
    candidate.config = requested.merge(candidate.config)
    result = {
      name: "#{tap.name}/#{candidate.token}", version: candidate.version.to_s, url: candidate.url.to_s, sha256: candidate.sha256.to_s,
      language: candidate.language, effective_languages: candidate.config.languages, artifacts: candidate.artifacts_list,
      source: { kind: 'trusted-git-blob', tap: tap.name, remote: tap.remote, git_head: head,
                ruby_source_path: relative, sha256: Digest::SHA256.hexdigest(blob) },
      config: { requested_language: language.empty? ? nil : language, saved_sha256: config_hash,
                effective: JSON.parse(candidate.config.to_json) }
    }
  end
  result
end
results = requests.map { |name, language| SpinnetNativeMetadata.project(name, language) }
serialized = JSON.generate(results.length == 1 ? results.first : { records: results })
SpinnetNativeMetadata.reject_source('native metadata exceeds its export budget') if serialized.bytesize > 1024 * 1024
puts serialized
