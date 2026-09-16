{ lib }:

# Mutation helpers for nix/tests: build modified { rules, locks } sources
# from the real ones for loadModel negative cases.
{
  withRules = f: m: m // { rules = f m.rules; };
  withLocks = f: m: m // { locks = f m.locks; };
  withSection =
    name: f: m:
    m
    // {
      rules = m.rules // {
        ${name} = f m.rules.${name};
      };
    };
  withLock =
    id: f: m:
    m
    // {
      locks = m.locks // {
        ${id} = f m.locks.${id};
      };
    };
  withPkgs =
    f: m:
    m
    // {
      rules = m.rules // {
        pdk_pkg = f m.rules.pdk_pkg;
      };
    };
  mapPkg = id: f: map (pkg: if pkg.id == id then f pkg else pkg);
}
