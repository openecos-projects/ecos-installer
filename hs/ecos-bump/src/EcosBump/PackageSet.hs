{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Translate the rules into a nvfetcher 'PackageSet'.
--
-- All entries are always defined; selection happens through nvfetcher's
-- filterRegex (non-selected entries become TemporaryStale and reuse their
-- seeded versions). forceFetch is attached only to mutable -latest entries
-- inside the current selection, and PermanentStale only to the pinned
-- pdk_pkg packages.
module EcosBump.PackageSet (buildPackageSet) where

import Data.Default (def)
import qualified Data.Map.Strict as Map
import EcosBump.Types
import NvFetcher

buildPackageSet ::
  -- | all entries
  [Entry] ->
  -- | pin override for one entry
  Maybe Pin ->
  -- | current selection (only these get forceFetch and template fetchers)
  [ComponentId] ->
  -- | lock srcs of the current lock file. Entries outside the selection
  -- are frozen at their lock data (Manual version source and a static
  -- fetcher): a stale seed version cannot always be interpolated into the
  -- url_template or resolved as a git rev.
  Map.Map ComponentId LockSrc ->
  PackageSet ()
buildPackageSet entries mpin selection lockSrcs = mapM_ defineEntry entries
  where
    defineEntry e =
      case (eNeedsCnb e, eCnbUrlTemplate e) of
        (True, Just t) ->
          define
            ( ( package (unComponentId (eId e)) `src` versionSource e `fetch` fetcherFor e
                  `fetchCnb` (\(Version v) -> interpolate t v (applyVersionMap (eVersionMap e) v))
              )
                `andThen` pure forceVal
                `andThen` pure staleVal
            )
        _ ->
          define
            ( (package (unComponentId (eId e)) `src` versionSource e `fetch` fetcherFor e)
                `andThen` pure forceVal
                `andThen` pure staleVal
            )
      where
        forceVal =
          if isMutable e && eId e `elem` selection
            then ForceFetch
            else NoForceFetch
        staleVal =
          if ePinned e
            then PermanentStale
            else NoStale

    -- The pin override replaces the entry's version source for this run;
    -- the rest of the pipeline is unchanged. Entries outside the selection
    -- are frozen at their locked version via a Manual source (which also
    -- keeps the git commit date lookup from running on stale seeds).
    versionSource e = case mpin of
      Just pin | pinId pin == eId e -> Manual (pinTag pin)
      _
        | eId e `notElem` selection,
          Just lockSrc <- Map.lookup (eId e) lockSrcs ->
            Manual (lsVersion lockSrc)
        | otherwise -> case eSrc e of
            SrcGitHub owner repo prerelease -> GitHubRelease owner repo prerelease
            SrcGitHubTag owner repo includeRe -> GitHubTag owner repo (def & includeRegex .~ includeRe)
            SrcGit url branch -> Git (unUrl url) (Branch branch)
            SrcManual v -> Manual v

    fetcherFor e = case Map.lookup (eId e) lockSrcs of
      Just lockSrc | eId e `notElem` selection -> \_ -> FetchUrl (unUrl (lsUrl lockSrc)) (lsName lockSrc) ()
      _ -> \(Version v) ->
        let registryVersion = applyVersionMap (eVersionMap e) v
            mName = interp <$> eNameTemplate e
            interp t = interpolate t v registryVersion
         in FetchUrl (interp (eUrlTemplate e)) mName ()
