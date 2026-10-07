# bundler-multilock

## Running tests

- Match CI: `BUNDLER_VERSION=4.1.0.beta1 BUNDLE_LOCKFILE=active bin/rspec`. Specs shell out to real Bundler
  against rubygems.org, so they need network access and take about a minute per Ruby.
- Specs pin real gem versions, so new upstream releases can break them (this has happened with minitest 6,
  activemodel 8.1, and a removed rspecq commit). Before assuming a failure is a regression, check whether `main`
  fails the same way.
- Any spec whose outcome depends on which gems are installed must use `use_local_bundle_path`,
  `install_local_gem`, and `uninstall_local_gem`. Never change global gems. Bundler quietly re-resolves to any
  compatible version that happens to be installed.
- Bundler 4 lockfiles use two-space indentation and include a `CHECKSUMS` section. The lockfile-editing spec
  helpers strip the checksum of any gem they change.

## Bundler 4 behaviors the code depends on

- Bundler reads `BUNDLE_LOCKFILE` itself, expands it to an absolute path, and sets it for subprocesses. Use
  `Multilock.env_lockfile` and `Multilock.env_lockfile_names`. They ignore the value Bundler set for subprocesses
  (marked in `BUNDLE_MULTILOCK_GENERATED_LOCKFILE`), and recover what the user wrote from
  `BUNDLER_ORIG_BUNDLE_LOCKFILE` when it matches. In nested bundler commands it can't be recovered, so a bare name
  in the current directory could be either a path or a short lockfile name. Don't read `ENV["BUNDLE_LOCKFILE"]`
  directly.
- Bundler re-registers a path-installed plugin's hooks only when its path changes. After editing hooks in
  `plugins.rb`, delete `.bundle/plugin` and reinstall.
- Bundler always locks a gem's source variant as a fallback. A precompiled gem's Ruby upper bound never makes a
  version truly incompatible. To test an incompatible Ruby, use pure-Ruby gems with an upper bound (see the
  datadog/ddtrace spec).
- With Bundler 4.1.0.beta1 and RubyGems older than 4.1, `bundle env` crashes for any plugin. The
  "doesn't break env" spec is `pending` for that, so it fails loudly once Bundler fixes it.
