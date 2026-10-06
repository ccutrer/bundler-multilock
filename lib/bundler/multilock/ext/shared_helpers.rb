# frozen_string_literal: true

module Bundler
  module Multilock
    module Ext
      module SharedHeleprs
        module ClassMethods
          ::Bundler::SharedHelpers.singleton_class.prepend(self)
          ::Bundler::SharedHelpers.instance_variable_set(:@filesystem_accesses, nil)

          def capture_filesystem_access
            @filesystem_accesses = []
            yield
            @filesystem_accesses
          ensure
            @filesystem_accesses = nil
          end

          # Bundler sets BUNDLE_LOCKFILE for subprocesses; remember when that's
          # Bundler's choice, rather than one the user explicitly asked for, so that
          # subprocesses can tell it apart from one they explicitly set themselves.
          def set_bundle_variables
            explicit = Multilock.env_lockfile
            super
            if explicit
              ENV.delete(Multilock::GENERATED_LOCKFILE_ENV)
            else
              ENV[Multilock::GENERATED_LOCKFILE_ENV] = ENV.fetch("BUNDLE_LOCKFILE", nil)
            end
          end
          private :set_bundle_variables

          def filesystem_access(path, action = :write)
            @filesystem_accesses << [path, action] if @filesystem_accesses

            super
          end
        end
      end
    end
  end
end
