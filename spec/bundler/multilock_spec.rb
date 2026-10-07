# frozen_string_literal: true

require "tempfile"
require "open3"
require "fileutils"
require "shellwords"

describe "Bundler::Multilock" do
  it "generates a default Gemfile.lock when loaded, but not configured" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"
    RUBY
      invoke_bundler("install")
      output = invoke_bundler("info concurrent-ruby")

      expect(output).to include("1.2.2")
      expect(File.read("Gemfile.lock")).to include("1.2.2")
    end
  end

  it "injects plugin load commands into the Gemfile when installing" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "injects plugin load commands right after the source, even with comments and blank lines later" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        gem "concurrent-ruby", "1.2.2"

        # a comment
        gem "rake", "13.2.1"
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"

        # a comment
        gem "rake", "13.2.1"
      RUBY
    end
  end

  it "injects plugin load commands on their own line when the Gemfile doesn't end with a newline" do
    with_gemfile("") do
      # (a lone `#` at the very end used to be able to loop forever)
      File.write("Gemfile", %(source "https://rubygems.org"\n#))

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}", timeout: 60)

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"
        #
        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

      RUBY
    end
  end

  it "doesn't inject plugin load commands into a trailing comment without a newline" do
    with_gemfile("") do
      File.write("Gemfile", %(source "https://rubygems.org"\n# the end))

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"
        # the end
        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

      RUBY
    end
  end

  it "removes the unnecessary plugin load command and updates the version requirement" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2"
        return unless Plugin.installed?("bundler-multilock")

        Plugin.send(:load_plugin, "bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "removes the unnecessary plugin load command without blank lines around it" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2"
        return unless Plugin.installed?("bundler-multilock")
        Plugin.send(:load_plugin, "bundler-multilock")
        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")
        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "replaces all of the version constraints when updating the version requirement" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2", "< 1.5", source: "https://rubygems.org"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}", source: "https://rubygems.org"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "replaces all of the version constraints even with comments between them" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2", # legacy major
               "< 1.5",
               source: "https://rubygems.org"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}",
               source: "https://rubygems.org"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "updates a guard without parentheses, instead of injecting another one" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin 'bundler-multilock', '~> 1.2'
        return unless Plugin.installed? 'bundler-multilock'

        Plugin.send(:load_plugin, 'bundler-multilock')

        gem 'concurrent-ruby', '1.2.2'
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin 'bundler-multilock', '#{plugin_requirement}'
        return unless Plugin.loaded?('bundler-multilock')

        gem 'concurrent-ruby', '1.2.2'
      RUBY
    end
  end

  it "only updates the preamble in code, not in strings, heredocs, or comments" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2"
        return unless Plugin.installed?("bundler-multilock")

        Plugin.send(:load_plugin, "bundler-multilock")

        # plugin "bundler-multilock", "~> 1.2"
        TEMPLATE = <<~GEMFILE
          plugin "bundler-multilock", "~> 1.2"
          return unless Plugin.installed?("bundler-multilock")
          Plugin.send(:load_plugin, "bundler-multilock")
        GEMFILE
        SNIPPET = 'return unless Plugin.installed? "bundler-multilock"'

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        # plugin "bundler-multilock", "~> 1.2"
        TEMPLATE = <<~GEMFILE
          plugin "bundler-multilock", "~> 1.2"
          return unless Plugin.installed?("bundler-multilock")
          Plugin.send(:load_plugin, "bundler-multilock")
        GEMFILE
        SNIPPET = 'return unless Plugin.installed? "bundler-multilock"'

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "injects the preamble if it's only in strings, heredocs, or comments" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        # return unless Plugin.loaded?("bundler-multilock")
        TEMPLATE = <<~GEMFILE
          plugin "bundler-multilock", "~> 2.0"
          return unless Plugin.loaded?("bundler-multilock")
        GEMFILE
        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      gemfile = File.read("Gemfile")
      expect(gemfile).to include(<<~RUBY)
        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")
      RUBY
      # the template and comment are untouched
      expect(gemfile).to include(%(# return unless Plugin.loaded?("bundler-multilock")\n))
      expect(gemfile).to include(<<~RUBY)
        TEMPLATE = <<~GEMFILE
          plugin "bundler-multilock", "~> 2.0"
          return unless Plugin.loaded?("bundler-multilock")
        GEMFILE
      RUBY
    end
  end

  it "does not inject duplicate plugin load commands when you prefer single quotes" do
    gemfile = <<~RUBY
      # frozen_string_literal: true

      source 'https://rubygems.org'

      plugin 'bundler-multilock', '#{plugin_requirement}'
      return unless Plugin.loaded?('bundler-multilock')

      gem 'concurrent-ruby', '1.2.2'
    RUBY

    with_gemfile("") do
      File.write("Gemfile", gemfile)

      local_path = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq gemfile
    end
  end

  it "does not inject when a secondary Gemfile has the necessary commands" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        eval_gemfile("injected.rb")
      RUBY

      File.write("injected.rb", <<~RUBY)
        plugin "bundler-multilock", "#{plugin_requirement}", path: #{File.expand_path("../..", __dir__).inspect}
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
      injected = File.read("injected.rb")

      invoke_bundler("install")
      expect(File.read("Gemfile")).not_to include("bundler-multilock")
      expect(File.read("injected.rb")).to eq injected
    end
  end

  it "disallows duplicate lockfiles" do
    with_gemfile(<<~RUBY) do
      lockfile()
      lockfile()
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/is already defined/)
    end
  end

  it "disallows multiple active lockfiles" do
    with_gemfile(<<~RUBY) do
      lockfile(active: true)
      lockfile("full", active: true)
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/can be flagged as active/)
    end
  end

  it "allows defaulting to an alternate lockfile" do
    with_gemfile(<<~RUBY) do
      lockfile(active: false)
      lockfile("full", active: true)
    RUBY
      invoke_bundler("install")
    end
  end

  it "disallows no lockfile set as active" do
    with_gemfile(<<~RUBY) do
      lockfile(active: false)
      lockfile("full")
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/No lockfiles marked as active/)
    end
  end

  it "validates parent lockfile exists" do
    with_gemfile(<<~RUBY) do
      lockfile("full", parent: "missing")
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/Parent lockfile .+missing\.lock is not defined/)
    end
  end

  it "allows externally defined parents if they exist" do
    with_gemfile(<<~RUBY) do
      lockfile("full", parent: Bundler.default_lockfile)
    RUBY
      invoke_bundler("install")
    end
  end

  it "generates custom lockfiles with varying versions" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "concurrent-ruby", "1.1.10"
      end
      lockfile "new" do
        gem "concurrent-ruby", "1.2.2"
      end
    RUBY
      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).to include("1.1.10")
      expect(File.read("Gemfile.lock")).not_to include("1.2.2")
      expect(File.read("Gemfile.new.lock")).not_to include("1.1.10")
      expect(File.read("Gemfile.new.lock")).to include("1.2.2")
    end
  end

  it "handle _only_ custom variations" do
    with_gemfile(<<~RUBY) do
      gem "rake", "13.0.6"

      lockfile "variation1" do
        gem "concurrent-ruby", "1.1.10"
      end
      lockfile "variation2" do
        gem "concurrent-ruby", "1.2.2"
      end
    RUBY
      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).to include("rake")
      expect(File.read("Gemfile.lock")).not_to include("concurrent-ruby")

      output = invoke_bundler("list")
      expect(output).to include("rake")
      expect(output).not_to include("concurrent-ruby")

      output = invoke_bundler("info rake")
      expect(output).to include("13.0.6")
      output = invoke_bundler("info concurrent-ruby", allow_failure: true)
      expect(output).not_to include("1.1.10")

      expect(File.read("Gemfile.variation1.lock")).to include("concurrent-ruby")
      expect(File.read("Gemfile.variation1.lock")).to include("rake")
      expect(File.read("Gemfile.variation1.lock")).to include("1.1.10")
      expect(File.read("Gemfile.variation1.lock")).not_to include("1.2.2")
      expect(File.read("Gemfile.variation2.lock")).to include("concurrent-ruby")
      expect(File.read("Gemfile.variation2.lock")).to include("rake")
      expect(File.read("Gemfile.variation2.lock")).not_to include("1.1.10")
      expect(File.read("Gemfile.variation2.lock")).to include("1.2.2")
    end
  end

  it "bundle info, bundle list respect active" do
    with_gemfile(<<~RUBY) do
      gem "rake", "13.0.6"

      lockfile "variation1", active: true do
        gem "concurrent-ruby", "1.1.10"
      end
      lockfile "variation2" do
        gem "concurrent-ruby", "1.2.2"
      end
    RUBY
      invoke_bundler("install")

      output = invoke_bundler("list")
      expect(output).to include("rake")
      expect(output).to include("concurrent-ruby")

      output = invoke_bundler("info rake")
      expect(output).to include("13.0.6")
      output = invoke_bundler("info concurrent-ruby")
      expect(output).to include("1.1.10")
    end
  end

  it "generates lockfiles with a subset of gems" do
    with_gemfile(<<~RUBY) do
      lockfile "full" do
        gem "test_local", path: "test_local"
      end

      gem "concurrent-ruby", "1.2.2"
    RUBY
      create_local_gem("test_local")

      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).not_to include("test_local")
      expect(File.read("Gemfile.full.lock")).to include("test_local")

      expect(File.read("Gemfile.lock")).to include("concurrent-ruby")
      expect(File.read("Gemfile.full.lock")).to include("concurrent-ruby")
    end
  end

  it "fails if an additional lockfile contains an invalid gem" do
    with_gemfile(<<~RUBY) do
      lockfile("new")

      gem "concurrent-ruby", ">= 1.2.2"
    RUBY
      invoke_bundler("install")

      replace_lockfile_pin("Gemfile.lock", "concurrent-ruby", "1.2.2")
      replace_lockfile_pin("Gemfile.new.lock", "concurrent-ruby", "1.2.2")
      invoke_bundler("install")

      replace_lockfile_pin("Gemfile.new.lock", "concurrent-ruby", "1.2.3")
      invoke_bundler("install", env: { "BUNDLE_LOCKFILE" => "new" })

      expect { invoke_bundler("check") }.to raise_error(/concurrent-ruby.*does not match/m)
    end
  end

  it "preserves the locked version of a gem in an alternate lockfile when updating a different gem in common" do
    with_gemfile(<<~RUBY) do
      lockfile("full", active: true) do
        gem "net-smtp", "0.3.2"
      end

      gem "net-ldap", "0.17.0"
    RUBY
      invoke_bundler("install")

      expect(invoke_bundler("info net-ldap")).to include("0.17.0")
      expect(invoke_bundler("info net-smtp")).to include("0.3.2")

      # loosen the requirement on both gems
      write_gemfile(<<~RUBY)
        lockfile("full", active: true) do
          gem "net-smtp", "~> 0.3"
        end

        gem "net-ldap", "~> 0.17"
      RUBY

      # but only update net-ldap
      invoke_bundler("update net-ldap")

      # net-smtp should be untouched, even though it's no longer pinned
      expect(invoke_bundler("info net-ldap")).not_to include("0.17.0")
      expect(invoke_bundler("info net-smtp")).to include("0.3.2")
    end
  end

  it "maintains consistency across multiple Gemfiles" do
    with_gemfile(<<~RUBY) do
      lockfile("local_test/Gemfile.lock",
               gemfile: "local_test/Gemfile")

      gem "net-smtp", "0.3.2"
    RUBY
      create_local_gem("local_test", <<~RUBY)
        spec.add_dependency "net-smtp", "~> 0.3"
      RUBY

      invoke_bundler("install")

      # locks to 0.3.2 in the local gem's lockfile, even though the local
      # gem itself would allow newer
      expect(File.read("local_test/Gemfile.lock")).to include("0.3.2")
    end
  end

  it "maintains consistency across local gem's lockfiless when one is included in the other" do
    with_gemfile(<<~RUBY) do
      lockfile("local_test/Gemfile.lock",
               gemfile: "local_test/Gemfile")

      gem "local_test", path: "local_test"
      gem "net-smtp", "0.3.2"
    RUBY
      create_local_gem("local_test", <<~RUBY)
        spec.add_dependency "net-smtp", "~> 0.3"
      RUBY

      invoke_bundler("install")

      replace_lockfile_pin("local_test/Gemfile.lock", "net-smtp", "0.3.3")

      # write_gemfile(<<~RUBY)
      #   lockfile("local_test/Gemfile.lock",
      #          gemfile: "local_test/Gemfile")

      #   gem "net-smtp", "~> 0.3.2"
      # RUBY

      invoke_bundler("install")
      expect(File.read("local_test/Gemfile.lock")).to include("0.3.2")
    end
  end

  it "syncs from a parent lockfile" do
    with_gemfile(<<~RUBY) do
      # activesupport 6.0 requires minitest 5
      gem "minitest", "~> 5.1"

      lockfile do
        gem "activesupport", "~> 6.1.0"
      end

      lockfile("6.0") do
        gem "activesupport", "~> 6.0.0"
      end

      lockfile("6.0-alt", parent: "6.0") do
        gem "activesupport", "> 5.2", "< 7.2"
      end
    RUBY
      invoke_bundler("install")

      default = invoke_bundler("info activesupport")
      six_oh = invoke_bundler("info activesupport 2> /dev/null", env: { "BUNDLE_LOCKFILE" => "6.0" })
      alt = invoke_bundler("info activesupport 2> /dev/null", env: { "BUNDLE_LOCKFILE" => "6.0-alt" })

      expect(default).to include("6.1")
      expect(default).not_to eq six_oh
      expect(six_oh).to include("6.0")
      # alt is the same as 6.0, even though it should allow 6.1
      expect(alt).to eq six_oh
    end
  end

  it "whines about non-pinned dependencies in flagged gemfiles" do
    with_gemfile(<<~RUBY) do
      lockfile("full", enforce_pinned_additional_dependencies: true) do
        gem "net-smtp", "~> 0.3"
      end

      gem "net-ldap", "0.17.0"
    RUBY
      expect do
        invoke_bundler("install")
      end.to raise_error(/net-smtp \([0-9.]+\) in Gemfile.full.lock has not been pinned/m)

      # not only have to pin net-smtp, but also its transitive dependencies
      write_gemfile(<<~RUBY)
        lockfile("full", enforce_pinned_additional_dependencies: true) do
          gem "net-smtp", "0.3.2"
            gem "net-protocol", "0.2.1"
            gem "timeout", "0.3.2"
        end

        gem "net-ldap", "0.17.0"
      RUBY

      invoke_bundler("install") # no error, because it's now pinned
    end
  end

  context "with mismatched dependencies disallowed" do
    it "notifies about mismatched versions between different lockfiles" do
      with_gemfile(<<~RUBY) do
        lockfile do
          gem "activesupport", ">= 6.0", "< 7.0"
        end

        lockfile("full") do
          gem "activesupport", "6.0.6.1"
        end
      RUBY
        expect do
          invoke_bundler("install")
        end.to raise_error(Regexp.new("activesupport \\(6.0.6.1\\) in Gemfile.full.lock " \
                                      "does not match the parent lockfile's version"))
      end
    end

    it "notifies about mismatched versions between different lockfiles for sub-dependencies" do
      with_gemfile(<<~RUBY) do
        gem "activesupport", "6.1.7.6" # depends on tzinfo ~> 2.0, so will get >= 2.0.6

        lockfile("full") do
          gem "tzinfo", "2.0.5"
        end

      RUBY
        expect do
          invoke_bundler("install")
        end.to raise_error(/tzinfo \(2.0.5\) in Gemfile.full.lock does not match the parent lockfile's version/)
      end
    end
  end

  it "allows mismatched explicit dependencies by default" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "activesupport", "~> 6.0.0"
      end

      lockfile("new") do
        gem "activesupport", "6.1.7.6"
      end
    RUBY
      invoke_bundler("install") # no error
      expect(File.read("Gemfile.lock")).to include("6.0.")
      expect(File.read("Gemfile.lock")).not_to include("6.1.7.6")
      expect(File.read("Gemfile.new.lock")).not_to include("6.0.")
      expect(File.read("Gemfile.new.lock")).to include("6.1.7.6")
    end
  end

  it "disallows mismatched implicit dependencies" do
    with_gemfile(<<~RUBY) do
      lockfile("local_test/Gemfile.lock",
               gemfile: "local_test/Gemfile")

      gem "snaky_hash", "2.0.1"
    RUBY
      create_local_gem("local_test", <<~RUBY)
        spec.add_dependency "zendesk_api", "1.28.0"
      RUBY

      expect do
        invoke_bundler("install")
      end.to raise_error(Regexp.new("hashie \\(4[0-9.]+\\) in local_test/Gemfile.lock " \
                                    "does not match the parent lockfile's version \\(@([0-9.]+)\\)"))
    end
  end

  it "removes transitive deps from secondary lockfiles when they disappear from the primary lockfile" do
    with_gemfile(<<~RUBY) do
      lockfile("full")

      gem "pact-mock_service", "3.11.0"
    RUBY
      # get 3.11.0 intalled
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        lockfile("full")

        gem "pact-mock_service", "~> 3.11.0"
      RUBY

      # update the lockfiles with the looser dependency (but with 3.11.0)
      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).to include("filelock")
      full_lock = File.read("Gemfile.full.lock")
      expect(full_lock).to include("filelock")

      # update the default lockfile to 3.11.2
      invoke_bundler("update")

      # but revert the full lockfile, and re-sync it
      # as part of a regular bundle install
      File.write("Gemfile.full.lock", full_lock)

      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).not_to include("filelock")
      expect(File.read("Gemfile.full.lock")).not_to include("filelock")
    end
  end

  it "updates the lockfile when restrictions are loosened (in the alternate lockfile)" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("full", active: true) do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        lockfile("full", active: true) do
          gem "concurrent-ruby", "~> 1.2.0"
        end
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("~> 1.2.0")
    end
  end

  it "updates the lockfile when restrictions are loosened" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.1"

      lockfile("full", active: true) do
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "concurrent-ruby", "~> 1.2.0"

        lockfile("full", active: true) do
        end
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("~> 1.2.0")
    end
  end

  it "updates the lockfile when a gem updates, and the alternate lockfile " \
     "has the exact same set of gems as the default lockfile" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.1"

      lockfile("full", active: true) do
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "concurrent-ruby", "~> 1.2.0"

        lockfile("full", active: true) do
        end
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("1.2.1")

      replace_lockfile_pin("Gemfile.lock", "concurrent-ruby", "1.2.2")

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("1.2.2")
    end
  end

  it "updates the lockfile when only the platforms differ" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("full")
    RUBY
      invoke_bundler("install")

      invoke_bundler("lock --add-platform java")

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("java")

      invoke_bundler("lock --remove-platform java")

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).not_to include("java")
    end
  end

  it "syncs lockfiles with `bundle lock` when gems aren't installed" do
    with_gemfile("") do
      # install the plugin (`bundle lock` won't), but keep gems isolated so
      # that nothing in the Gemfile is installed
      use_local_bundle_path
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "concurrent-ruby", "1.2.2"

        lockfile do
        end

        lockfile "alt" do
          gem "rake", "13.2.1"
        end
      RUBY

      invoke_bundler("lock")
      expect(File.read("Gemfile.lock")).to include("concurrent-ruby (1.2.2)")
      expect(File.read("Gemfile.alt.lock")).to include("concurrent-ruby (1.2.2)")
      expect(File.read("Gemfile.alt.lock")).to include("rake (13.2.1)")

      # adding a gem only to the alternate lockfile still syncs
      write_gemfile(<<~RUBY)
        gem "concurrent-ruby", "1.2.2"

        lockfile do
        end

        lockfile "alt" do
          gem "rake", "13.2.1"
          gem "rack", "3.1.8"
        end
      RUBY
      invoke_bundler("lock")
      expect(File.read("Gemfile.alt.lock")).to include("rack (3.1.8)")

      # and a frozen `bundle lock` is happy with it (the local config would
      # override BUNDLE_FROZEN)
      invoke_bundler("config set --local frozen true")
      invoke_bundler("lock")
      invoke_bundler("config set --local frozen false")

      # it's still not installed
      expect { invoke_bundler("check") }.to raise_error(/The following gems are missing/)
    end
  end

  it "installs missing gems in secondary lockfile" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile do
        gem "concurrent-ruby", "1.2.2"
      end

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      # keep this isolated from installed gems, so that uninstalling is reliable
      use_local_bundle_path
      invoke_bundler("install")

      uninstall_local_gem("concurrent-ruby", "1.2.1")
      expect { invoke_bundler("check", env: { "BUNDLE_LOCKFILE" => "alt1" }) }
        .to raise_error(/The following gems are missing.*concurrent-ruby \(1\.2\.1\)/m)

      invoke_bundler("install")
      expect(invoke_bundler("info concurrent-ruby", env: { "BUNDLE_LOCKFILE" => "alt1" })).to include("1.2.1")
    end
  end

  it "doesn't break outdated" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")
      invoke_bundler("outdated")
    end
  end

  it "doesn't break env" do
    if Gem::Version.new(Gem::VERSION) < Gem::Version.new("4.1.0.beta1")
      # Bundler 4.1 writes empty hashes as `{}` in the plugin index, but `bundle env`
      # loads the older RubyGems YAMLSerializer first, which reads them as strings.
      # This affects any plugin, not just this one.
      pending "Bundler 4.1 can't read its plugin index during `bundle env` with RubyGems < 4.1"
    end

    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")
      invoke_bundler("env")
    end
  end

  it "errors if you specify a non-existent lockfile" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")
      expect { invoke_bundler("exec rake -v", env: { "BUNDLE_LOCKFILE" => "alt2" }) }
        .to raise_error(/Could not locate lockfile "alt2"/)

      invoke_bundler("binstub rake")
      Bundler.with_unbundled_env do
        ENV["BUNDLE_LOCKFILE"] = "alt2"
        expect(`bin/rake -v 2>&1`).to include('Could not locate lockfile "alt2"')
      ensure
        ENV.delete("BUNDLE_LOCKFILE")
      end
    end
  end

  it "uses BUNDLE_LOCKFILE as a plain path when no lockfiles are defined" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"
    RUBY
      invoke_bundler("install", env: { "BUNDLE_LOCKFILE" => "custom" })

      expect(File.read("custom")).to include("concurrent-ruby (1.2.2)")
      expect(File).not_to exist("Gemfile.custom.lock")
    end
  end

  it "treats an absolute BUNDLE_LOCKFILE as a path, even without a .lock suffix" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "concurrent-ruby", "1.2.2"
      end

      lockfile "./custom" do
        gem "concurrent-ruby", "1.3.4"
      end

      lockfile "custom" do
        gem "concurrent-ruby", "1.3.3"
      end
    RUBY
      invoke_bundler("install")

      expect(invoke_bundler("info concurrent-ruby", env: { "BUNDLE_LOCKFILE" => File.expand_path("custom") }))
        .to include("1.3.4")
      expect(invoke_bundler("info concurrent-ruby", env: { "BUNDLE_LOCKFILE" => "custom" })).to include("1.3.3")
    end
  end

  it "respects BUNDLE_LOCKFILE in a bundler command nested inside `bundle exec`" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "concurrent-ruby", "1.2.2"
      end

      lockfile "alt" do
        gem "concurrent-ruby", "1.3.4"
      end
    RUBY
      invoke_bundler("install")

      # the nested commands inherit the environment that `bundle exec` sets up
      # (including BUNDLE_LOCKFILE), instead of a clean one
      expect(invoke_bundler("exec #{bundler_bin} info concurrent-ruby")).to include("1.2.2")
      expect(invoke_bundler("exec env BUNDLE_LOCKFILE=alt #{bundler_bin} info concurrent-ruby")).to include("1.3.4")
    end
  end

  it "allows explicitly specifying the active lockfile" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install", env: { "BUNDLE_LOCKFILE" => "Gemfile.lock" })
    end
  end

  # so that it won't downgrade if that's all you have available
  it "installs missing deps from alternate lockfiles before syncing" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "activemodel", ">= 6.0"
      end

      lockfile("rails-6.1") do
        gem "activemodel", "~> 6.1.0"
      end
    RUBY
      # keep this isolated from installed gems, so that the only activemodel
      # available locally is the one we install here
      use_local_bundle_path
      install_local_gem("activemodel", "6.1.7.6")

      invoke_bundler("install --local")
      expect(invoke_bundler("info activesupport", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("6.1.7.6")

      uninstall_local_gem("activemodel", "6.1.7.6")
      install_local_gem("activemodel", "6.1.6")

      expect { invoke_bundler("check") }.to raise_error(/The following gems are missing/)
      invoke_bundler("install")

      # it should have re-installed 6.1.7.6, leaving the lockfile alone
      expect(invoke_bundler("info activemodel", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("6.1.7.6")
    end
  end

  it "syncs whether there are checksums to secondary lockfiles" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"

      lockfile do
      end

      lockfile "alt" do
        gem "rake", "13.2.1"
      end
    RUBY
      invoke_bundler("install")
      expect(File.read("Gemfile.alt.lock")).to include("CHECKSUMS")

      # the parent lockfile has checksums, but the alternate doesn't
      remove_checksums_section("Gemfile.alt.lock")
      expect { invoke_bundler("check") }
        .to raise_error(/The parent lockfile has checksums, but Gemfile.alt.lock does not/)

      invoke_bundler("install")
      expect(File.read("Gemfile.alt.lock")).to match(/^CHECKSUMS\n.*^  rake \(13\.2\.1\) sha256=/m)
      invoke_bundler("check")

      # and the other way around
      remove_checksums_section("Gemfile.lock")
      expect { invoke_bundler("check") }
        .to raise_error(/The parent lockfile does not have checksums, but Gemfile.alt.lock does/)

      invoke_bundler("install")
      expect(File.read("Gemfile.alt.lock")).not_to include("CHECKSUMS")
      invoke_bundler("check")
    end
  end

  it "keeps checksums the same for gems in common between lockfiles" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"
      gem "tzinfo", "2.0.6"

      lockfile do
      end

      lockfile "alt" do
        gem "rake", "13.2.1"
      end
    RUBY
      invoke_bundler("install")
      expect(expect_matching_checksums("Gemfile.lock", "Gemfile.alt.lock"))
        .to include("concurrent-ruby (1.2.2)", "tzinfo (2.0.6)")
      # gems only in the alternate lockfile get checksums too
      expect(lockfile_checksums("Gemfile.alt.lock")["rake (13.2.1)"]).not_to be_nil

      # update a gem in common, so that the alternate lockfile gets merged
      # with the new version from the default lockfile
      replace_string("Gemfile", 'gem "concurrent-ruby", "1.2.2"', 'gem "concurrent-ruby", "1.3.4"')
      invoke_bundler("install")
      expect(File.read("Gemfile.alt.lock")).to include("concurrent-ruby (1.3.4)")
      expect(expect_matching_checksums("Gemfile.lock", "Gemfile.alt.lock"))
        .to include("concurrent-ruby (1.3.4)", "tzinfo (2.0.6)")
      expect(lockfile_checksums("Gemfile.alt.lock")["rake (13.2.1)"]).not_to be_nil
    end
  end

  it "notices and fixes mismatched checksums for gems in common between lockfiles" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"

      lockfile do
      end

      lockfile "alt" do
        gem "rake", "13.2.1"
      end
    RUBY
      invoke_bundler("install")

      bad_checksum = "0" * 64
      replace_string("Gemfile.alt.lock",
                     /^(  concurrent-ruby \(1\.2\.2\) sha256=)\h+$/,
                     "\\1#{bad_checksum}")
      expect(lockfile_checksums("Gemfile.alt.lock")["concurrent-ruby (1.2.2)"]).to eq bad_checksum

      expect { invoke_bundler("check") }
        .to raise_error(/The checksum for concurrent-ruby \(1\.2\.2\) in Gemfile.alt.lock does not match/)

      invoke_bundler("lock")
      expect(expect_matching_checksums("Gemfile.lock", "Gemfile.alt.lock")).to include("concurrent-ruby (1.2.2)")
      invoke_bundler("check")
    end
  end

  it "only fetches checksums it can't compute locally when not running with --local" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"

      lockfile do
      end

      lockfile "alt" do
        gem "rake", "13.2.1"
      end
    RUBY
      use_local_bundle_path
      invoke_bundler("install")

      # a gem only in the alternate lockfile, without a checksum or a cached
      # package to compute one from
      replace_string("Gemfile.alt.lock", /^(  rake \(13\.2\.1\)) sha256=\h+$/, "\\1")
      FileUtils.rm(Dir["#{local_gem_dir}/cache/rake-13.2.1.gem"])

      expect { invoke_bundler("install --local") }
        .to raise_error(/Could not find checksums for rake-13\.2\.1 \(for Gemfile.alt.lock\) locally/)
      expect { invoke_bundler("lock --local") }
        .to raise_error(/Could not find checksums for rake-13\.2\.1 \(for Gemfile.alt.lock\) locally/)
      expect(lockfile_checksums("Gemfile.alt.lock")["rake (13.2.1)"]).to be_nil

      invoke_bundler("lock")
      expect(lockfile_checksums("Gemfile.alt.lock")["rake (13.2.1)"]).to match(/\A\h{64}\z/)
      invoke_bundler("install --local")
    end
  end

  it "updates bundler version in secondary lockfiles" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")

      update_lockfile_bundler("Gemfile.alt1.lock", "2.4.18")

      invoke_bundler("install")

      expect(File.read("Gemfile.alt1.lock")).not_to include("2.4.18")
      expect(File.read("Gemfile.alt1.lock")).to include(Bundler::VERSION)
    end
  end

  it "only syncs once per lockfile" do
    with_gemfile(<<~RUBY) do
      gemspec

      lockfile("rails-6.1", active: true) do
        gem "activesupport", "~> 6.1.0"
      end
    RUBY
      create_local_gem("test", subdirectory: false)
      invoke_bundler("install")
      output = invoke_bundler("install", env: { "DEBUG" => "1" })

      expect(output.split("\n").grep(/Syncing to alternate lockfiles/).length).to be 1
    end
  end

  it "does not re-sync lockfiles that have conflicting sub-dependencies" do
    with_gemfile(<<~RUBY) do
      # activesupport 6.0 requires minitest 5
      gem "minitest", "~> 5.1"

      lockfile do
        gem "activemodel", "~> 6.1.0"
      end

      lockfile("rails-6.0") do
        gem "activemodel", "~> 6.0.0"
      end
    RUBY
      output = invoke_bundler("install")
      expect(output).to include("Syncing")

      output = invoke_bundler("install")
      expect(output).not_to include("Syncing")
    end
  end

  it "removes now-missing explicit dependencies from secondary lockfiles" do
    with_gemfile(<<~RUBY) do
      gem "inst-jobs", "3.1.6"
      gem "activerecord-pg-extensions"

      lockfile("alt") {}
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "inst-jobs", "3.1.6"

        lockfile("alt") {}
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile.lock")).to eq File.read("Gemfile.alt.lock")
    end
  end

  it "does not evaluate the default lockfile at all if an alternate is active, " \
     "without specifying that lockfile explicitly" do
    with_gemfile(<<~RUBY) do
      gem "inst-jobs", "3.1.6"

      lockfile active: ENV["ALTERNATE"] != "1" do
        raise "evaluated!" if ENV["ALTERNATE"] == "1"
      end

      lockfile "alt", active: ENV["ALTERNATE"] == "1" do
        gem "activerecord-pg-extensions"
      end
    RUBY
      invoke_bundler("install")

      invoke_bundler("install", env: { "ALTERNATE" => "1", "BUNDLE_LOCKFILE" => "active" })
    end
  end

  it "doesn't update versions in alternate lockfiles when syncing" do
    # first
    with_gemfile(<<~RUBY) do
      gem "rubocop", "1.45.0"

      lockfile do
        gem "activesupport", "6.0.0"
      end

      lockfile "rails-6.1" do
        gem "activesupport", "6.1.0"
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "rubocop", "~> 1.45.0"

        lockfile do
          gem "activesupport", "~> 6.0.0"
        end

        lockfile "rails-6.1" do
          gem "activesupport", "~> 6.1.0"
        end
      RUBY

      # first, unpin, but ensure no gems update during this process
      invoke_bundler("install")

      expect(invoke_bundler("info rubocop")).to include("1.45.0")
      expect(invoke_bundler("info activesupport")).to include("6.0.0")
      expect(invoke_bundler("info rubocop", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("1.45.0")
      expect(invoke_bundler("info activesupport", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("6.1.0")

      # now, update an unrelated gem, but _only_ that gem
      # this should not update other gems in the alternate lockfiles
      invoke_bundler("update rubocop --conservative")

      expect(invoke_bundler("info rubocop")).to include("1.45.1")
      expect(invoke_bundler("info activesupport")).to include("6.0.0")
      expect(invoke_bundler("info rubocop", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("1.45.1")
      expect(invoke_bundler("info activesupport", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("6.1.0")
    end
  end

  it "keeps transitive dependencies in sync, even when the intermediate deps are conflicting" do
    orig_gemfile = <<~RUBY
      gem 'datadog', '~> 2.0'

      lockfile do
        gem "activesupport", "6.0.0"
      end

      lockfile "rails-6.1" do
        gem "activesupport", "6.1.0"
      end
    RUBY

    with_gemfile("") do
      # install once with nothing so that it doesn't try to lock every single
      # platform available for FFI
      invoke_bundler("install")

      write_gemfile(orig_gemfile)
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        # the oldest version that supports Ruby 4.0, and with a different libdatadog than the latest
        gem 'datadog', '~> 2.24.0'

        lockfile do
          gem "activesupport", "~> 6.0.0"
        end

        lockfile "rails-6.1" do
          gem "activesupport", "~> 6.1.0"
        end
      RUBY

      FileUtils.cp("Gemfile.rails-6.1.lock", "Gemfile.rails-6.1.lock.orig")
      # roll back to datadog 2.24.0
      invoke_bundler("install")

      # loosen the requirement to allow > 2.24, but with it locked to
      # 2.24. But act like the alternate lockfile didn't get updated
      write_gemfile(orig_gemfile)
      FileUtils.cp("Gemfile.rails-6.1.lock.orig", "Gemfile.rails-6.1.lock")

      # now a plain install should sync the alternate lockfile, rolling it back too
      invoke_bundler("install")

      expect(invoke_bundler("info datadog")).to include("2.24.0")
      expect(invoke_bundler("info datadog", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("2.24.0")
    end
  end

  it "syncs gems whose platforms changed slightly" do
    with_gemfile(<<~RUBY) do
      gem "sqlite3", "~> 1.7"

      lockfile("all") {}
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "sqlite3"

        lockfile("all") {}
      RUBY
      invoke_bundler("install")

      expect(invoke_bundler("info sqlite3")).to include("1.7.3")
      expect(invoke_bundler("info sqlite3", env: { "BUNDLE_LOCKFILE" => "all" })).to include("1.7.3")

      invoke_bundler("update sqlite3")
      expect(invoke_bundler("info sqlite3")).not_to include("1.7.3")
      expect(invoke_bundler("info sqlite3", env: { "BUNDLE_LOCKFILE" => "all" })).not_to include("1.7.3")
    end
  end

  it "syncs ruby version" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"

      lockfile do
        ruby ">= 2.1"
      end

      lockfile "alt" do
      end
    RUBY
      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).to include(Bundler::RubyVersion.system.to_s)
      expect(File.read("Gemfile.alt.lock")).to include(Bundler::RubyVersion.system.to_s)

      update_lockfile_ruby("Gemfile.alt.lock", "ruby 2.1.0p0")

      expect do
        invoke_bundler("check")
      end.to raise_error(/ruby \(ruby 2.1.0p0\) in Gemfile.alt.lock does not match the parent lockfile's version/)

      update_lockfile_ruby("Gemfile.alt.lock", nil)
      expect do
        invoke_bundler("check")
      end.to raise_error(/ruby \(<none>\) in Gemfile.alt.lock does not match the parent lockfile's version/)

      invoke_bundler("install")
      expect(File.read("Gemfile.alt.lock")).to include(Bundler::RubyVersion.system.to_s)

      update_lockfile_ruby("Gemfile.lock", "ruby 2.6.0p0")
      update_lockfile_ruby("Gemfile.alt.lock", nil)

      invoke_bundler("install")
      expect(File.read("Gemfile.alt.lock")).to include("ruby 2.6.0p0")
    end
  end

  it "ignores installation errors when an alternate lockfile specifies a gem " \
     "version incompatible with the current ruby" do
    # These gems only have a single (ruby) platform with an upper bound on the ruby
    # version, so there's no compatible variant for bundler to fall back to. The first
    # version is compatible with the current ruby, and the second is not.
    gem_name, version, incompatible_version = case RUBY_VERSION
                                              when "4.0"..."4.1" then %w[datadog 2.24.0 2.23.0]
                                              when "3.4"..."3.5" then %w[datadog 2.2.0 2.1.0]
                                              when "3.3"..."3.4" then %w[ddtrace 1.13.1 1.12.1]
                                              when "3.2"..."3.3" then %w[ddtrace 1.13.1 0.54.2]
                                              else raise "Pick gem versions for ruby #{RUBY_VERSION}"
                                              end
    # the profiling native extension isn't relevant here, and can fail to build
    # (e.g. when debase-ruby_core_source doesn't have headers for this exact ruby)
    env = { "DD_PROFILING_NO_EXTENSION" => "true" }

    with_gemfile(<<~RUBY) do
      gem "#{gem_name}", "#{version}"

      lockfile do
      end

      lockfile "alt" do
      end
    RUBY
      # keep this isolated from installed gems; otherwise bundler will just
      # re-resolve to a compatible version that happens to be installed
      use_local_bundle_path
      invoke_bundler("install", env:)
      FileUtils.rm_rf(local_gem_dir)

      # Transform this back into an unpinned gem otherwise bundler won't think
      # the incompatible version needs to be installed
      replace_string("Gemfile", "gem \"#{gem_name}\", \"#{version}\"", "gem \"#{gem_name}\"")
      replace_string("Gemfile.lock", "#{gem_name} (= #{version})", gem_name)
      replace_string("Gemfile.alt.lock", "#{gem_name} (= #{version})", gem_name)

      replace_lockfile_pin("Gemfile.lock", gem_name, incompatible_version)
      replace_lockfile_pin("Gemfile.alt.lock", gem_name, incompatible_version)

      expect { invoke_bundler("check") }
        .to raise_error(/The following gems are missing.*#{gem_name} \(#{Regexp.escape(incompatible_version)}\)/m)

      invoke_bundler("install", env:)
    end
  end

  it "doesn't error when no lockfiles are defined but ruby version is set" do
    with_gemfile(<<~RUBY) do
      gem "nokogiri"

      ruby ">= 2.1"
    RUBY
      invoke_bundler("install")
    end
  end

  it "syncs git sources that have updated" do
    with_gemfile(<<~RUBY) do
      gem "rspecq", github: "instructure/rspecq"

      lockfile "alt" do
      end
    RUBY
      invoke_bundler("install")
      # an older commit, but with the same version as main
      replace_lockfile_git_pin("b32030382a6eb14a691f355efcaa037d45394859")
      invoke_bundler("install")

      expect(invoke_bundler("info rspecq")).to include("b320303")

      invoke_bundler("update rspecq")
      expect(invoke_bundler("info rspecq")).not_to include("b320303")
    end
  end

  private

  def create_local_gem(name, content = "", subdirectory: true)
    if subdirectory
      FileUtils.mkdir_p(name)
      subdirectory = "#{name}/"
    else
      subdirectory = nil
    end
    File.write("#{subdirectory}#{name}.gemspec", <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name          = #{name.inspect}
        spec.version       = "0.0.1"
        spec.authors       = ["Instructure"]
        spec.summary       = "for testing only"

        #{content}
      end
    RUBY

    return unless subdirectory

    File.write("#{name}/Gemfile", <<~RUBY)
      source "https://rubygems.org"

      gemspec
    RUBY
  end

  # creates a new temporary directory, writes the gemfile to it, and yields
  #
  # @param (see #write_gemfile)
  # @yield
  def with_gemfile(content = nil)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        write_gemfile(content)

        invoke_bundler("config frozen false")

        yield
      end
    end
  end

  # @param content [String]
  #   Ruby code to set up lockfiles by calling `lockfile`.
  def write_gemfile(content)
    raise ArgumentError, "Did you mean to use `with_gemfile`?" if block_given?

    File.write("Gemfile", <<~RUBY)
      source "https://rubygems.org"

      plugin "bundler-multilock", "#{plugin_requirement}", path: #{File.expand_path("../..", __dir__).inspect}
      return unless Plugin.loaded?("bundler-multilock")

      #{content}
    RUBY
  end

  # Shells out to a new instance of bundler, with a clean bundler env
  #
  # @param subcommand [String] Args to pass to bundler
  # @raise [RuntimeError] if the bundle command fails
  def invoke_bundler(subcommand, env: {}, allow_failure: false, timeout: nil)
    output = nil
    command = "#{bundler_bin} #{subcommand}"
    Bundler.with_unbundled_env do
      # in its own process group, so that it can be killed along with any children
      Open3.popen2e(env, command, pgroup: true) do |stdin, stdout_and_stderr, wait_thread|
        stdin.close
        reader = Thread.new { stdout_and_stderr.read }

        unless wait_thread.join(timeout)
          Process.kill("KILL", -wait_thread.pid)
          wait_thread.join
          raise "bundle #{subcommand} timed out after #{timeout} seconds: #{reader.value}"
        end

        output = reader.value
        raise "bundle #{subcommand} failed: #{output}" unless allow_failure || wait_thread.value.success?
      end
    end
    output
  end

  # @return [String] the bundler executable for the bundler version under test
  def bundler_bin
    Gem.bin_path("bundler", "bundler", ENV.fetch("BUNDLER_VERSION"))
  rescue Gem::Exception
    "bundler"
  end

  # The version requirement the plugin injects into (and expects in) Gemfiles
  def plugin_requirement
    Bundler::Multilock.plugin_requirement
  end

  # Shells out to `gem`, with a clean bundler env
  #
  # @param subcommand [String] Args to pass to gem
  # @raise [RuntimeError] if the gem command fails
  def invoke_gem(subcommand)
    output = nil
    Bundler.with_unbundled_env do
      output, status = Open3.capture2e("gem #{subcommand}")

      raise "gem #{subcommand} failed: #{output}" unless status.success?
    end
    output
  end

  # Installs gems into the current directory instead of the system, so that a spec
  # neither depends on nor changes which gems are installed globally
  def use_local_bundle_path
    invoke_bundler("config set --local path vendor/bundle")
  end

  # The directory gems are installed into after calling {#use_local_bundle_path}
  def local_gem_dir
    "vendor/bundle/ruby/#{RbConfig::CONFIG["ruby_version"]}"
  end

  # Installs a gem (and its dependencies) into {#local_gem_dir}
  def install_local_gem(name, version)
    invoke_gem("install #{name} -v #{version} -s https://rubygems.org --install-dir #{local_gem_dir} --no-document")
  end

  # Uninstalls a gem from {#local_gem_dir}, even if other gems depend on it
  def uninstall_local_gem(name, version)
    invoke_gem("uninstall #{name} -v #{version} --force --install-dir #{local_gem_dir}")
  end

  # Directly modifies a lockfile to adjust the version of a gem
  #
  # Useful for simulating certain unusual situations that can arise.
  #
  # @param lockfile [String] The lockfile's location
  # @param gem [String] The gem's name
  # @param version [String] The new version to "pin" the gem to
  def replace_lockfile_pin(lockfile, gem, version)
    new_contents = File.read(lockfile).gsub(/(?<![\w-])#{gem} \([0-9a-z.]+((?:-[a-z0-9_]+)*)\)/,
                                            "#{gem} (#{version}\\1)")

    File.write(lockfile, remove_checksum(new_contents, gem))
  end

  # The checksum is no longer valid after manually changing the version
  def remove_checksum(contents, gem)
    contents.gsub(/^(  #{Regexp.escape(gem)} \([^)]+\)) sha256=\h+$/, "\\1")
  end

  # @return [Hash<String, String>] the CHECKSUMS entries of a lockfile, keyed by gem and version
  def lockfile_checksums(lockfile)
    section = File.read(lockfile)[/^CHECKSUMS\n(.*?)\n\n/m, 1]
    raise "#{lockfile} doesn't have checksums" unless section

    section.lines.to_h do |line|
      full_name, checksum = line.strip.split(" sha256=")
      [full_name, checksum]
    end
  end

  # Expects every gem (and version) locked in both lockfiles to have the same checksum in each
  #
  # @return [Array<String>] the gems (and versions) in common
  def expect_matching_checksums(lockfile1, lockfile2)
    checksums1 = lockfile_checksums(lockfile1)
    checksums2 = lockfile_checksums(lockfile2)
    common = checksums1.keys & checksums2.keys

    expect(checksums2.slice(*common)).to eq checksums1.slice(*common)
    common
  end

  def remove_checksums_section(lockfile)
    File.write(lockfile, File.read(lockfile).sub(/^CHECKSUMS\n.*?\n\n/m, ""))
  end

  def replace_lockfile_git_pin(revision)
    new_contents = File.read("Gemfile.lock").gsub(/revision: [0-9a-f]+/, "revision: #{revision}")

    File.write("Gemfile.lock", new_contents)
  end

  def replace_string(lockfile, old_string, new_string)
    new_contents = File.read(lockfile).gsub(old_string, new_string)

    File.write(lockfile, new_contents)
  end

  def update_lockfile_bundler(lockfile, version)
    new_contents = File.read(lockfile).gsub(/BUNDLED WITH\n +[0-9a-z.]+/, "BUNDLED WITH\n  #{version}")

    File.write(lockfile, new_contents)
  end

  def update_lockfile_ruby(lockfile, version)
    old_contents = File.read(lockfile)
    new_version = version ? "RUBY VERSION\n  #{version}\n\n" : ""
    new_contents = old_contents.gsub(/RUBY VERSION\n +#{Bundler::RubyVersion::PATTERN}\n\n/o, new_version)

    File.write(lockfile, new_contents)
  end
end
