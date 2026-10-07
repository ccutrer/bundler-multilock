# frozen_string_literal: true

require_relative "multilock/ext/bundler"
require_relative "multilock/ext/definition"
require_relative "multilock/ext/dsl"
require_relative "multilock/ext/plugin/dsl"
require_relative "multilock/ext/shared_helpers"
require_relative "multilock/ext/source"
require_relative "multilock/ext/source_list"
require_relative "multilock/version"

module Bundler
  module Multilock
    # @!visibility private
    GENERATED_LOCKFILE_ENV = "BUNDLE_MULTILOCK_GENERATED_LOCKFILE"

    class << self
      # @!visibility private
      attr_reader :lockfile_definitions
      # @!visibility private
      attr_accessor :prepare_block

      # @param lockfile [String] The lockfile path (defaults to Gemfile.lock)
      # @param builder [Dsl] The Bundler DSL
      # @param gemfile [String, nil]
      #   The Gemfile for this lockfile (defaults to Gemfile)
      # @param active [Boolean]
      #   If this lockfile should be the default (instead of Gemfile.lock)
      #   BUNDLE_LOCKFILE will still override a lockfile tagged as active
      # @param parent [String] The parent lockfile to sync dependencies from.
      #   Also used for comparing enforce_pinned_additional_dependencies against.
      # @param enforce_pinned_additional_dependencies [true, false]
      #   If dependencies are present in this lockfile that are not present in the
      #   default lockfile, enforce that they are pinned.
      # @yield
      #   Block executed only when this lockfile is active.
      # @return [true, false] if the lockfile is the active lockfile
      def add_lockfile(lockfile = nil, # rubocop:disable Naming/PredicateMethod -- not a predicate
                       builder:,
                       gemfile: nil,
                       active: nil,
                       parent: nil,
                       enforce_pinned_additional_dependencies: false,
                       &block)
        active = true if active.nil? && lockfile_definitions.empty? && lockfile.nil? && gemfile.nil?

        # if a gemfile was provided, but not a lockfile, infer the default lockfile for that gemfile
        lockfile ||= "#{gemfile}.lock" if gemfile
        # allow short-form lockfile names
        lockfile = expand_lockfile(lockfile)

        raise ArgumentError, "Lockfile #{lockfile} is already defined" if lockfile_definitions.key?(lockfile)

        env_lockfile = lockfile if active && self.env_lockfile == "active"
        env_lockfile ||= self.env_lockfile&.then { |l| expand_lockfile(l) }
        active = env_lockfile == lockfile if env_lockfile

        if active && (old_active = lockfile_definitions.each_value.find { |definition| definition[:active] })
          raise ArgumentError, "Only one lockfile (#{old_active[:lockfile]}) can be flagged as active"
        end

        parent = expand_lockfile(parent)
        if parent != Bundler.default_lockfile(force_original: true) &&
           !lockfile_definitions.key?(parent) &&
           !parent.exist?
          raise ArgumentError, "Parent lockfile #{parent} is not defined"
        end

        lockfile_definitions[lockfile] = (lockfile_def = {
          gemfile: (gemfile && Bundler.root.join(gemfile).expand_path) || Bundler.default_gemfile,
          lockfile:,
          active:,
          prepare: block,
          parent:,
          enforce_pinned_additional_dependencies:
        })

        # If they're using BUNDLE_LOCKFILE, then they really do want to
        # use a particular lockfile, and it overrides whatever they
        # dynamically set in their gemfile
        if !env_lockfile && defined?(CLI) &&
           %i[check install lock update].include?(CLI.instance&.current_command_chain&.first)
          # always use Gemfile.lock for `bundle check`, `bundle install`,
          # `bundle lock`, and `bundle update`.
          active = lockfile == Bundler.default_lockfile(force_original: true)
        end

        if active
          block&.call
          Bundler.default_lockfile = lockfile

          # we started evaluating the project's primary gemfile, but got told to use a lockfile
          # associated with a different Gemfile. so we need to evaluate that Gemfile instead
          if lockfile_def[:gemfile] != Bundler.default_gemfile
            # share a cache between all lockfiles
            Bundler.cache_root = Bundler.root
            ENV["BUNDLE_GEMFILE"] = lockfile_def[:gemfile].to_s
            Bundler.root = Bundler.default_gemfile.dirname
            Bundler.default_lockfile = lockfile

            builder.eval_gemfile(Bundler.default_gemfile)

            return false
          end
        end
        true
      end

      # @!visibility private
      def after_install_all(install: true)
        loaded!
        previous_recursive = @recursive

        return if lockfile_definitions.empty?
        return if env_lockfile # explicitly working against a single lockfile

        # must be running `bundle cache`
        return unless Bundler.default_lockfile == Bundler.default_lockfile(force_original: true)

        require_relative "multilock/check"

        if Bundler.frozen_bundle? && !install
          # only do the checks if we're frozen
          exit 1 unless Check.run
          return
        end

        # this hook will be called recursively when it has to install gems
        # for a secondary lockfile. defend against that
        return if @recursive

        @recursive = true

        require "tempfile"
        require_relative "multilock/lockfile_generator"

        Bundler.ui.debug("Syncing to alternate lockfiles")

        attempts = 1
        previous_contents = Set.new

        default_root = Bundler.root

        cache = Cache.new
        checker = Check.new(cache, check_installed: install)
        synced_any = false
        local_parser_cache = {}
        Bundler.settings.temporary(cache_all_platforms: true, suppress_install_using_messages: true) do
          lockfile_definitions.each do |lockfile_name, lockfile_definition|
            # we already wrote the default lockfile
            next if lockfile_name == Bundler.default_lockfile(force_original: true)

            # root needs to be set so that paths are output relative to the correct root in the lockfile
            Bundler.root = lockfile_definition[:gemfile].dirname

            relative_lockfile = lockfile_name.relative_path_from(Dir.pwd)

            # prevent infinite loops of tick-tocking back and forth between two versions
            current_contents = cache.contents(lockfile_name)
            if previous_contents.include?(current_contents)
              Bundler.ui.debug("Unable to converge on a single solution for #{lockfile_name}; " \
                               "perhaps there are conflicting requirements?")
              attempts = 1
              previous_contents.clear
              next
            end
            previous_contents << current_contents

            # already up to date?
            up_to_date = false
            conflicts = Set.new
            Bundler.settings.temporary(frozen: true) do
              Bundler.ui.silence do
                up_to_date = checker.base_check(lockfile_definition, check_missing_deps: true) &&
                             checker.deep_check(lockfile_definition, conflicts:)
              end
            end
            if up_to_date
              attempts = 1
              previous_contents.clear
              next
            end

            if Bundler.frozen_bundle?
              # if we're frozen, you have to use the pre-existing lockfile
              unless lockfile_name.exist?
                Bundler.ui.error("The bundle is locked, but #{relative_lockfile} is missing. " \
                                 "Please make sure you have checked #{relative_lockfile} " \
                                 "into version control before deploying.")
                exit 1
              end

              Bundler.ui.info("Installing gems for #{relative_lockfile}...")
              write_lockfile(lockfile_definition, lockfile_name, cache, install:)
            else
              Bundler.ui.info("Syncing to #{relative_lockfile}...") if attempts == 1
              synced_any = true

              parent_lockfile_name = lockfile_definition[:parent]
              parent_root = parent_lockfile_name.dirname
              parent_specs = cache.specs(parent_lockfile_name)

              # adjust locked paths from the parent lockfile to be relative to _this_ gemfile
              adjusted_parent_lockfile_contents =
                cache.contents(parent_lockfile_name).gsub(/PATH\n  remote: ([^\n]+)\n/) do |remote|
                  remote_path = Pathname.new($1)
                  next remote if remote_path.absolute?

                  relative_remote_path = remote_path.expand_path(parent_root).relative_path_from(Bundler.root).to_s
                  remote.sub($1, relative_remote_path)
                end

              # add a source for the current gem
              gem_spec = parent_specs.dig(File.basename(Bundler.root), "ruby")

              if gem_spec
                adjusted_parent_lockfile_contents += <<~TEXT
                  PATH
                    remote: .
                    specs:
                  #{gem_spec.to_lock}
                TEXT
              end

              if lockfile_name.exist?
                # if the lockfile already exists, "merge" it together
                parent_lockfile = if adjusted_parent_lockfile_contents == cache.contents(lockfile_name)
                                    cache.parser(parent_lockfile_name)
                                  else
                                    local_parser_cache[adjusted_parent_lockfile_contents] ||=
                                      LockfileParser.new(adjusted_parent_lockfile_contents)
                                  end
                lockfile = cache.parser(lockfile_name)

                dependency_changes = false

                spec_precedences = {}

                check_precedence = lambda do |spec, parent_spec|
                  next :parent if spec.nil?
                  next :self if parent_spec.nil?
                  next spec_precedences[spec.name] if spec_precedences.key?(spec.name)

                  precedence = if !(cache.reverse_dependencies(lockfile_name)[spec.name] & conflicts).empty? # rubocop:disable Style/ArrayIntersect -- not an array
                                 :parent
                               elsif cache.conflicting_requirements?(lockfile_name,
                                                                     parent_lockfile_name,
                                                                     spec,
                                                                     parent_spec)
                                 :self
                               end

                  spec_precedences[spec.name] = precedence || :parent
                end

                lockfile.sources.map! do |source|
                  parent_lockfile.sources.find { |s| s == source } || source
                end
                # replace any duplicate specs with what's in the parent lockfile
                lockfile.specs.map! do |spec|
                  parent_spec = cache.find_matching_spec(parent_specs, spec)
                  next spec unless parent_spec
                  next spec if check_precedence.call(spec, parent_spec) == :self

                  dependency_changes ||= spec != parent_spec

                  if spec.source != parent_spec.source
                    parent_spec = parent_spec.dup
                    parent_spec.source = spec.source
                  end
                  parent_spec
                end

                lockfile.platforms.replace(parent_lockfile.platforms).uniq!
                lockfile.instance_variable_set(:@ruby_version, parent_lockfile.ruby_version) if lockfile.ruby_version
                unless lockfile.bundler_version == parent_lockfile.bundler_version
                  unlocking_bundler = parent_lockfile.bundler_version
                  lockfile.instance_variable_set(:@bundler_version, parent_lockfile.bundler_version)
                end

                new_contents = LockfileGenerator.generate(lockfile)
              else
                # no lockfile? just start out with the parent lockfile's contents to inherit its
                # locked gems
                new_contents = adjusted_parent_lockfile_contents
              end

              had_changes = false
              # Now build a definition based on the given Gemfile, with the combined lockfile
              Tempfile.create do |temp_lockfile|
                temp_lockfile.write(new_contents)
                temp_lockfile.flush

                had_changes ||= write_lockfile(lockfile_definition,
                                               temp_lockfile.path,
                                               cache,
                                               install:,
                                               dependency_changes:,
                                               unlocking_bundler:)
              end
              cache.invalidate_lockfile(lockfile_name) if had_changes

              # if we had changes, bundler may have updated some common
              # dependencies beyond the default lockfile, so re-run it
              # once to reset them back to the default lockfile's version.
              # if it's already good, the `check` check at the beginning of
              # the loop will skip the second sync anyway.
              if had_changes
                attempts += 1
                Bundler.ui.debug("Re-running sync to #{relative_lockfile} to reset common dependencies")
                redo
              else
                attempts = 1
                previous_contents.clear
              end
            end
          end
        ensure
          Bundler.root = default_root
        end

        exit 1 unless checker.run(skip_base_checks: !synced_any)
      ensure
        @recursive = previous_recursive
      end

      # @!visibility private
      def loaded!
        return if loaded?

        @loaded = true
        if lockfile_definitions.empty?
          # nothing for Multilock to manage; use BUNDLE_LOCKFILE as a plain path, like Bundler would
          if env_lockfile && env_lockfile != "active"
            Bundler.default_lockfile = Pathname.new(File.expand_path(env_lockfile))
          end
          return
        end

        return unless lockfile_definitions.each_value.none? { |definition| definition[:active] }

        return if env_lockfile&.then { |l| expand_lockfile(l) } == Bundler.default_lockfile(force_original: true)

        raise GemfileNotFound, "Could not locate lockfile #{env_lockfile.inspect}" if env_lockfile

        # Gemfile.lock isn't explicitly specified, otherwise it would be active
        default_lockfile_definition = self.default_lockfile_definition
        return unless default_lockfile_definition && default_lockfile_definition[:active] == false

        raise GemfileEvalError, "No lockfiles marked as active"
      end

      # @!visibility private
      def loaded?
        @loaded
      end

      # @!visibility private
      # The version requirement for the plugin in the Gemfile preamble
      def plugin_requirement
        version = Gem::Version.new(VERSION)
        # a prerelease doesn't satisfy `~> 2.0`, so allow later prereleases
        # (and releases) of this minor version instead
        return "~> #{version}" if version.prerelease?

        "~> #{version.segments.first}.0"
      end

      # @!visibility private
      def inject_preamble
        Bundler.ui.debug("Injecting multilock preamble")

        requirement = plugin_requirement
        bundle_preamble1_match = /plugin ["']bundler-multilock["']/
        bundle_preamble1 = <<~RUBY
          plugin "bundler-multilock", "#{requirement}"
        RUBY
        bundle_preamble2 = <<~RUBY
          return unless Plugin.loaded?("bundler-multilock")
        RUBY

        builder = Bundler::Plugin::DSL.new
        # this method is called as part of the plugin loading, but @loaded_plugin_names
        # hasn't been set yet, so avoid re-entrancy issues
        plugins = Bundler::Plugin.instance_variable_get(:@loaded_plugin_names)
        original_plugins = plugins.dup
        plugins << "bundler-multilock"
        begin
          builder.eval_gemfile(Bundler.default_gemfile)
        ensure
          plugins.replace(original_plugins)
        end
        gemfile_paths = builder.instance_variable_get(:@gemfiles).to_a
        gemfiles = gemfile_paths.to_h { |path| [path, path.read] }
        originals = gemfiles.transform_values(&:dup)

        gemfiles.each_value { |contents| upgrade_preamble(contents, requirement) }

        gemfile = gemfiles[Bundler.default_gemfile.expand_path] || Bundler.default_gemfile.read

        injection_point = 0
        while gemfile.match?(/^(?:#|\n|source)/, injection_point)
          if gemfile[injection_point] == "\n"
            injection_point += 1
          else
            injection_point = gemfile.index("\n", injection_point)
            injection_point += 1 if injection_point
            injection_point ||= -1
          end
        end

        inject_specific_preamble(gemfile, gemfiles.values, injection_point, bundle_preamble2, add_newline: true)
        inject_specific_preamble(gemfile,
                                 gemfiles.values,
                                 injection_point,
                                 bundle_preamble1,
                                 match: bundle_preamble1_match,
                                 add_newline: false)
        gemfiles[Bundler.default_gemfile.expand_path] = gemfile

        gemfiles.each do |path, contents|
          path.write(contents) unless contents == originals[path]
        end
      end

      # @!visibility private
      # The BUNDLE_LOCKFILE the user asked for, if any
      def env_lockfile
        lockfile = ENV.fetch("BUNDLE_LOCKFILE", nil)
        return if lockfile.nil? || lockfile.empty?
        # Bundler sets BUNDLE_LOCKFILE itself for subprocesses (see Ext::SharedHelpers);
        # that's not a request for a particular lockfile
        return if lockfile == ENV.fetch(GENERATED_LOCKFILE_ENV, nil)

        # Bundler expands BUNDLE_LOCKFILE to an absolute path, relative to the current
        # directory. Undo that for a bare name, so that short lockfile names (and
        # "active") still work.
        path = Pathname.new(lockfile)
        if path.absolute?
          relative = path.relative_path_from(Pathname.pwd).to_s
          return relative unless relative.include?("/")
        end

        lockfile
      end

      # @!visibility private
      def reset!
        @lockfile_definitions = {}
        @loaded = false
      end

      # @!visibility private
      def default_lockfile_definition
        lockfile_definitions[Bundler.default_lockfile(force_original: true)]
      end

      private

      def expand_lockfile(lockfile)
        if lockfile.is_a?(String) && !(lockfile.include?("/") || lockfile.end_with?(".lock"))
          lockfile = "Gemfile.#{lockfile}.lock"
        end
        # use absolute paths
        lockfile = Bundler.root.join(lockfile).expand_path if lockfile
        # use the default lockfile (Gemfile.lock) if none was given
        lockfile || Bundler.default_lockfile(force_original: true)
      end

      # Bundler loads the plugin before evaluating the Gemfile, so manually
      # loading it is no longer necessary. But Bundler also pre-parses the
      # Gemfile for plugins _without_ loading them, so the rest of the Gemfile
      # needs to be skipped when the plugin isn't loaded (not just installed).
      # Also update the version requirement if it doesn't allow this version,
      # or if it still references a prerelease after a release.
      def upgrade_preamble(gemfile, requirement)
        gemfile.gsub!(/^\n?[ \t]*Plugin\.send\(:load_plugin, (["'])bundler-multilock\1\)[ \t]*\n/, "")
        gemfile.gsub!(/(return unless Plugin\.)installed\?(\((["'])bundler-multilock\3\))/, "\\1loaded?\\2")
        # every string argument after the name is a version constraint, until
        # options (like `source:`, or `"source" =>`) start
        constraint = /\s*,\s*(["'])[^"'\n]*\k<-1>(?!\s*=>)/
        gemfile.gsub!(/^([ \t]*plugin\(?\s*(["'])bundler-multilock\2)((?:#{constraint})+)/) do |match|
          prefix, constraints = $1, $3
          quote = constraints[/["']/]
          existing_requirement = Gem::Requirement.new(*constraints.scan(/(["'])([^"'\n]*)\1/).map(&:last))
          version = Gem::Version.new(VERSION)
          if existing_requirement.satisfied_by?(version) && (version.prerelease? || !existing_requirement.prerelease?)
            next match
          end

          "#{prefix}, #{quote}#{requirement}#{quote}"
        rescue Gem::Requirement::BadRequirementError
          match
        end
      end

      def inject_specific_preamble(gemfile, gemfiles, injection_point, preamble, add_newline:, match: nil) # rubocop:disable Naming/PredicateMethod -- not a predicate
        # allow either type of quotes
        match ||= Regexp.new(Regexp.escape(preamble).gsub('"', %(["'])))
        return false if gemfiles.any? { |g| match.match?(g) }

        add_newline = false unless gemfile[injection_point - 1] == "\n"

        gemfile.insert(injection_point, "\n") if add_newline
        gemfile.insert(injection_point, preamble)

        true
      end

      # Copies checksums from the parent lockfile for gems in common, so that they match
      #
      # @return [true, false] if any (rubygems) gems are still missing checksums
      def copy_parent_checksums(definition, parent_lockfile, cache)
        return false if Bundler.frozen_bundle? || !definition.locked_checksums

        parent_specs = cache.parser(parent_lockfile).specs.to_h { |spec| [spec.full_name, spec] }
        missing = false
        definition.resolve.each do |spec|
          next unless spec.source.is_a?(Source::Rubygems)

          store = spec.source.checksum_store
          if (parent_spec = parent_specs[spec.full_name]) &&
             (checksums = parent_spec.source.checksum_store.checksums_to_lock(spec.full_name))
            checksums.split(",").each do |checksum|
              store.replace(spec, Checksum.from_lock(checksum, parent_lockfile.to_s))
            end
          end

          missing = true if store.missing?(spec) || store.empty?(spec)
        end
        missing
      end

      def write_lockfile(lockfile_definition,
                         lockfile,
                         cache,
                         install:,
                         dependency_changes: false,
                         unlocking_bundler: false)
        prepare_block = lockfile_definition[:prepare]

        gemfile = lockfile_definition[:gemfile]
        # use avoid Definition.build, so that we don't have to evaluate
        # the gemfile multiple times, each time we need a separate definition
        builder = Dsl.new
        builder.eval_gemfile(gemfile, &prepare_block) if prepare_block
        builder.eval_gemfile(gemfile)
        if !builder.instance_variable_get(:@ruby_version) &&
           (parent_lockfile = lockfile_definition[:parent]) &&
           (parent_lockfile_definition = lockfile_definitions[parent_lockfile]) &&
           (parent_ruby_version_requirement = parent_lockfile_definition[:ruby_version_requirement])
          builder.instance_variable_set(:@ruby_version, parent_ruby_version_requirement)
        end

        definition = builder.to_definition(lockfile, { bundler: unlocking_bundler })
        definition.instance_variable_set(:@dependency_changes, dependency_changes) if dependency_changes

        # match the parent lockfile in whether there are checksums
        unless Bundler.frozen_bundle?
          parent_checksums = cache.parser(lockfile_definition[:parent]).checksums
          if parent_checksums && !definition.locked_checksums
            definition.add_checksums
          elsif !parent_checksums && definition.locked_checksums
            definition.instance_variable_set(:@locked_checksums, false)
          end
        end

        current_lockfile = lockfile_definition[:lockfile]
        definition.instance_variable_set(:@lockfile_contents, current_lockfile.read) if current_lockfile.exist?

        orig_definition = definition.dup # we might need it twice

        # install gems for the exact current version of the lockfile
        # this ensures it doesn't re-resolve with only (different)
        # local gems after you've pulled down an update to the lockfile
        # from someone else
        if current_lockfile.exist? && install
          Bundler.settings.temporary(frozen: true) do
            # it keeps the same sources as the builder, which now shares with
            # `definition` above; give it its own copy to avoid stomping on it
            builder.instance_variable_set(
              :@sources,
              builder.instance_variable_get(:@sources).dup
            )

            current_definition = builder.to_definition(current_lockfile, {})
            # if something has changed, we skip this step; it's unlocking anyway
            next unless current_definition.no_resolve_needed?

            current_definition.resolve_with_cache!
            if current_definition.missing_specs.any?
              cache.invalidate_checks(current_lockfile)
              Bundler.with_default_lockfile(current_lockfile) do
                Installer.install(gemfile.dirname, current_definition, {})
              end
            end
          rescue RubyVersionMismatch, GemNotFound, SolveFailure, InstallError, ProductionError
            # ignore
          end
        end

        resolved_remotely = false
        accesses = begin
          previous_ui_level = Bundler.ui.level
          Bundler.ui.level = "warn"
          begin
            # force a remote resolution if intermediate gems are missing
            if definition.instance_variable_get(:@locked_spec_with_missing_deps) ||
               definition.instance_variable_get(:@locked_spec_with_invalid_deps) ||
               definition.instance_variable_get(:@missing_lockfile_dep) ||
               definition.instance_variable_get(:@invalid_lockfile_dep)
              raise SolveFailure
            end

            # this is a horrible hack, to fix what I consider to be a Bundler bug.
            # basically, if you have multiple platform specific gems in your
            # lockfile, and that gem gets unlocked, Bundler will only search
            # locally to find them. But non-platform-local gems are _never_
            # installed locally. So just find the non-platform-local gems
            # in the lockfile (that we know are there from a prior remote
            # resolution), and add them to the locally installed spec list.
            definition.send(:source_map).locked_specs.each do |spec|
              next if spec.installable_on_platform?(Bundler.local_platform)

              spec.source.specs << spec
            end
            definition.resolve_with_cache!
            # gems resolved from what's installed locally don't have checksums,
            # so resolve remotely if the parent lockfile doesn't have them either
            raise SolveFailure if copy_parent_checksums(definition, lockfile_definition[:parent], cache)
          rescue GemNotFound, SolveFailure
            definition = orig_definition

            definition.resolve_remotely!
            copy_parent_checksums(definition, lockfile_definition[:parent], cache)
            resolved_remotely = true
          end
          SharedHelpers.capture_filesystem_access do
            definition.instance_variable_set(:@resolved_bundler_version, unlocking_bundler) if unlocking_bundler

            # need to force it to _not_ preserve unknown sections, so that it
            # will overwrite the ruby version
            definition.instance_variable_set(:@unlocking_bundler, true)
            definition.lockfile = lockfile_definition[:lockfile]
            definition.lock
          end
        ensure
          Bundler.ui.level = previous_ui_level
        end

        # if we're running `bundle install` or `bundle update`, and something is missing from
        # the secondary lockfile, install it.
        if install && (definition.missing_specs.any? || resolved_remotely)
          Bundler.with_default_lockfile(lockfile_definition[:lockfile]) do
            Installer.install(lockfile_definition[:gemfile].dirname, definition, {})
          end
        end

        accesses && !accesses.empty?
      end
    end

    reset!

    @recursive = false
    @prepare_block = nil
  end
end

Bundler::Multilock.inject_preamble unless Bundler::Multilock.loaded?

if defined?(Bundler::CLI)
  require_relative "multilock/ext/cli"

  # this is terrible, but we can't prepend into these modules because we only load
  # _inside_ of the CLI commands already running
  if Bundler::CLI.instance&.current_command_chain&.first == :check
    require_relative "multilock/check"
    at_exit do
      next unless $!.nil?
      next if $!.is_a?(SystemExit) && !$!.success?

      next if Bundler::Multilock::Check.run

      Bundler.ui.warn("You can attempt to fix by running `bundle install`")
      exit 1
    end
  end
  if Bundler::CLI.instance&.current_command_chain&.first == :lock
    at_exit do
      next unless $!.nil?
      next if $!.is_a?(SystemExit) && !$!.success?

      Bundler::Multilock.after_install_all(install: false)
    end
  end
end
