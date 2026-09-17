{ lib }:

# Shared pure-function library for ecos-release:
#   checkers.nix     - require* manifest validation helpers
#   rules-locks.nix  - rules/locks toolkit (template algebra, lock entry
#                      shape validation, src-rule schema, rules+lock merge)
#   semver.nix       - SemVer 2.0.0 parsing and comparison
#   testing.nix      - rules/locks mutation helpers for nix/tests
(import ./checkers.nix { inherit lib; })
// (import ./rules-locks.nix { inherit lib; })
// {
  semver = import ./semver.nix { inherit lib; };
}
