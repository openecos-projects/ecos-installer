# Workflow domain: actionlint over .github/workflows so workflow-file
# validation errors (invalid expressions, disallowed contexts) fail
# `nix flake check` locally instead of surfacing as failed runs on push.
{ ... }:

{
  perSystem =
    { pkgs, ... }:
    {
      checks.actionlint =
        pkgs.runCommand "ecos-release-actionlint-check"
          {
            nativeBuildInputs = [ pkgs.actionlint ];
          }
          ''
            set -euo pipefail
            actionlint -oneline ${../../.github/workflows}/*.yml
            echo ok > "$out"
          '';
    };
}
