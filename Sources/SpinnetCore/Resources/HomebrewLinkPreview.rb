# Host-owned read-only plan for the pinned Homebrew link implementation.
require_relative 'HomebrewSourceGuard'
require 'keg'
require 'stringio'
operation, kind, name = ARGV
abort 'Invalid reviewed link preview' unless %w[link unlink].include?(operation) &&
  %w[formula cask].include?(kind) && name&.match?(/\A(?:[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*\z/) && ARGV.length == 3
module SpinnetLinkPlan
  class Incomplete < StandardError; end
  @changes = {}
  @warnings = []
  class << self
    attr_reader :changes, :warnings
    def path(value, destination: true)
      text = value.to_s
      raise Incomplete, 'Unbounded or noncanonical link path' unless text.bytesize <= 2048 &&
        text.start_with?('/') && !text.match?(/[\x00-\x1f\x7f]/) && Pathname(text).cleanpath.to_s == text &&
        (!destination || text.start_with?("#{HOMEBREW_PREFIX}/"))
      text
    end
    def add(action, target, source = nil)
      target = path(target)
      entry = { action: action, path: target }
      entry[:source] = path(source, destination: false) if source
      previous = @changes[target]
      if previous && previous != entry && !(previous[:action] == 'unlink' && %w[link mkdir].include?(action))
        raise Incomplete, "Ambiguous changes at #{target}"
      end
      @changes[target] = entry
      raise Incomplete, 'Link plan exceeds 2000 changes' if @changes.length > 2000
    end
    def removed?(target)
      %w[unlink rmdir].include?(@changes[target.to_s]&.fetch(:action, nil))
    end
    def warning(text)
      raise Incomplete, 'Link diagnostics exceed their bound' if @warnings.length >= 128 || text.bytesize > 2000
      @warnings << text
    end
    def parents(target)
      parent = target.parent
      missing = []
      until parent.directory?
        path(parent)
        raise Incomplete, "A parent path is not a directory: #{parent}" if parent.exist? || parent.symlink?
        missing << parent
        raise Incomplete, 'Link parent traversal exceeds its bound' if missing.length > 128
        parent = parent.parent
      end
      missing.reverse_each { |directory| add('mkdir', directory) }
    end
    def cleanup_directory(directory)
      return unless directory.directory? && !directory.symlink?
      children = directory.children.reject { |child| removed?(child) }
      if children.one? && children.first.basename.to_s == '.DS_Store'
        add('unlink', children.first)
        children = []
      end
      add('rmdir', directory) if children.empty?
    end
    def aliases(keg)
      opt = keg.opt_record.parent
      linked = keg.linked_keg_record.parent
      if (tap = keg.tab.tap)
        legacy = opt/tap.user
        if legacy.directory? && !legacy.symlink?
          raise Incomplete, "Legacy recursive cleanup requires manual review: #{legacy}"
        end
      end
      candidates = keg.aliases.reject { |a| a.match?(/.+@./) }.flat_map { |a| [[opt/a, keg.opt_record, false], [linked/a, keg.linked_keg_record, false]] }
      Pathname.glob("#{keg.opt_record}@*").each do |link|
        next if keg.aliases.include?(link.basename.to_s) && link.exist?
        candidates += [[link, keg.rack, true], [linked/link.basename, keg.rack, true]]
        raise Incomplete, 'Alias cleanup exceeds its bound' if candidates.length > 2000
      end
      candidates.each do |target, match, match_parent|
        if target.symlink? && target.exist?
          resolved = target.realpath
          resolved = resolved.parent if match_parent
          add('unlink', target) if match.exist? && resolved == match.realpath
        elsif target.symlink? || target.exist?
          raise Incomplete, "Alias cleanup is not a file: #{target}" if target.directory? && !target.symlink?
          add('unlink', target)
        end
      end
    end
    def unlink(keg)
      previous = $stdout
      capture = StringIO.new
      $stdout = capture
      keg.unlink(dry_run: true)
      $stdout = previous
      capture.string.lines.map(&:strip).reject(&:empty?).each do |target|
        add('unlink', target)
        add('update_info_index', Pathname(target).parent/'dir') if target.match?(Keg::INFOFILE_RX)
      end
      aliases(keg)
      if keg.linked?
        add('unlink', keg.linked_keg_record)
        cleanup_directory(keg.linked_keg_record.parent)
      end
      directories = []
      keg_path = Pathname(keg.to_path)
      Keg.keg_link_directories.map { |relative| keg_path/relative }.select(&:exist?).each do |root|
        root.find do |source|
          target = HOMEBREW_PREFIX + source.relative_path_from(keg_path)
          directories << target if target.directory? && !target.symlink?
          raise Incomplete, 'Directory cleanup exceeds its bound' if directories.length > 2000
          Find.prune if source.directory? && target.symlink? && source == Utils::Path.resolved_path(target)
        end
      end
      (directories - Keg.must_exist_subdirectories).reverse_each { |directory| cleanup_directory(directory) }
    ensure
      $stdout = previous
    end
    def link(keg)
      return warning("Already linked: #{keg}") if keg.linked?
      formula = keg.to_formula
      keg_only = Formulary.keg_only?(keg.rack)
      if keg_only && ((HOMEBREW_PREFIX.to_s == HOMEBREW_DEFAULT_PREFIX && formula.keg_only_reason.by_macos?) || !formula.keg_only_reason.versioned_formula?)
        raise Incomplete, "This keg requires force or shadows macOS software: #{keg.name}"
      end
      # Normal link unlinks related formulae; Homebrew's --dry-run skips this.
      related = formula.link_overwrite_formulae.select(&:linked?)
      related.select!(&:keg_only?) unless formula.keg_only?
      related.filter_map(&:any_installed_keg).select(&:directory?).each do |other|
        warning("Homebrew will also unlink #{other.name}.")
        unlink(other)
      end
      aliases(keg)
      [keg.opt_record, *keg.aliases.map { |a| keg.opt_record.parent/a }, *keg.oldname_opt_records].uniq.each do |target|
        raise Incomplete, "Metadata link is not replaceable: #{target}" if target.exist? && !target.symlink?
        raise Incomplete, "Metadata parent directory is missing: #{target.parent}" unless target.parent.directory?
        add('link', target, Pathname(keg.to_path))
      end
      keg.link(dry_run: true)
      add('link', keg.linked_keg_record, Pathname(keg.to_path))
    end
  end
end

# No locks, directory creation, install-info subprocess, or filesystem changes
# occur in this adapter. The Host sandbox independently denies writes.
module SpinnetLinkDryTraversal
  def link_dir(relative_dir, verbose: false, dry_run: false, overwrite: false, &block)
    previous = Thread.current[:spinnet_link_preview]
    Thread.current[:spinnet_link_preview] = true
    super(relative_dir, verbose: verbose, dry_run: true, overwrite: false, &block)
  ensure
    Thread.current[:spinnet_link_preview] = previous
  end
  def resolve_any_conflicts(target, **options)
    if target.symlink?
      resolved = resolved_path(target)
      raise SpinnetLinkPlan::Incomplete, "Shared-directory conversion requires manual review: #{target}" if resolved.directory?
      SpinnetLinkPlan.add('unlink', target) unless target.exist?
    end
    super(target, **options, dry_run: true)
  end
  def make_relative_symlink(target, source, **options)
    return if target.symlink? && source == resolved_path(target) && !SpinnetLinkPlan.removed?(target)
    if target.exist? && !SpinnetLinkPlan.removed?(target)
      unless target.symlink? && record_cask_symlink(target)
        raise SpinnetLinkPlan::Incomplete, "A link destination already exists: #{target}"
      end
      SpinnetLinkPlan.warning("Homebrew will replace the existing cask link at #{target}.")
    end
    SpinnetLinkPlan.add('link', target, source)
  end
end
module SpinnetLinkDryDirectories
  def mkpath(*args, **kwargs)
    if Thread.current[:spinnet_link_preview]
      SpinnetLinkPlan.parents(self)
      SpinnetLinkPlan.add('mkdir', self)
      return
    end
    super
  end
end
module SpinnetLinkInfoIndex
  def install_info(path, **options)
    SpinnetLinkPlan.add('update_info_index', path.parent/'dir')
  end
end
Keg.prepend(SpinnetLinkDryTraversal)
Pathname.prepend(SpinnetLinkDryDirectories)
Utils::Path.singleton_class.prepend(SpinnetLinkInfoIndex)
require "cmd/#{operation}"
require 'cask/artifact/symlinked' if kind == 'cask'

output = $stdout
captured = StringIO.new
$stdout = captured
status = 0
complete = true
begin
  Homebrew.running_command = operation
  command = Homebrew::AbstractCommand.command(operation).new(['--dry-run', '--' + kind, '--', name])
  kegs, casks = operation == 'link' ? command.args.named.to_kegs_to_casks(method: :latest_kegs) : command.args.named.to_kegs_to_casks
  raise SpinnetLinkPlan::Incomplete, 'Package resolution is ambiguous' unless (kind == 'formula' ? casks.empty? && !kegs.empty? : kegs.empty? && casks.one?)
  raise SpinnetLinkPlan::Incomplete, 'Too many installed kegs' if kegs.length > 32
  kegs.each { |keg| operation == 'link' ? SpinnetLinkPlan.link(keg) : SpinnetLinkPlan.unlink(keg) }
  casks.each do |cask|
    raise Cask::CaskNotInstalledError, cask unless cask.installed?
    cask.artifacts.grep(Cask::Artifact::Symlinked).each do |artifact|
      if operation == 'link'
        case artifact.link_action
        when :link
          raise SpinnetLinkPlan::Incomplete, "Cask link source is missing: #{artifact.source}" unless artifact.source.exist?
          SpinnetLinkPlan.parents(artifact.target)
          SpinnetLinkPlan.add('link', artifact.target, artifact.source)
        when :already_linked then next
        when :skip_formula then SpinnetLinkPlan.warning("A formula link takes precedence at #{artifact.target}.")
        else raise SpinnetLinkPlan::Incomplete, "A cask link destination already exists: #{artifact.target}"
        end
      elsif artifact.target_links_to_source? && artifact.target.symlink? && !artifact.send(:conflicting_formula)
        SpinnetLinkPlan.add('unlink', artifact.target)
      end
    end
  end
  raise SpinnetLinkPlan::Incomplete, 'Installed Ruby history is unavailable' if $spinnet_unavailable_history
rescue Homebrew::UntrustedTapError
  warn '__SPINNET_SOURCE_NOT_ALLOWED__'
  complete = false
  status = 77
rescue StandardError => error
  complete = false
  status = $spinnet_unavailable_history ? 78 : 1
  warn '__SPINNET_INSTALLED_HISTORY_UNAVAILABLE__' if $spinnet_unavailable_history
  warn error.message
ensure
  $stdout = output
end
output.puts({ complete: complete, changes: SpinnetLinkPlan.changes.values.sort_by { |entry| entry[:path] }, warnings: SpinnetLinkPlan.warnings }.to_json)
exit status
