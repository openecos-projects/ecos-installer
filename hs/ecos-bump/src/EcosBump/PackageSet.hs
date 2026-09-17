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
import Data.Text (Text)
import EcosBump.Rules
import NvFetcher

buildPackageSet ::
  -- | all entries
  [Entry] ->
  -- | pin override: (entry id, exact tag)
  Maybe (Text, Text) ->
  -- | current selection (only these get forceFetch and template fetchers)
  [Text] ->
  -- | (version, url, name) from the current lock file. Entries outside the
  -- selection are frozen at their lock data (Manual version source and a
  -- static fetcher): a stale seed version cannot always be interpolated
  -- into the url_template or resolved as a git rev.
  Map.Map Text (Text, Text, Maybe Text) ->
  PackageSet ()
buildPackageSet entries pin selection lockSrcs = mapM_ defineEntry entries
  where
    defineEntry e =
      case (eNeedsCnb e, eCnbUrlTemplate e) of
        (True, Just t) ->
          define
            ( ( package (eId e) `src` versionSource e `fetch` fetcherFor e
                  `fetchCnb` (\(Version v) -> interpolate t v (applyVersionMap (eVersionMap e) v))
              )
                `andThen` pure forceVal
                `andThen` pure staleVal
            )
        _ ->
          define
            ( (package (eId e) `src` versionSource e `fetch` fetcherFor e)
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
    versionSource e = case pin of
      Just (pid, tag) | pid == eId e -> Manual tag
      _
        | eId e `notElem` selection,
          Just (v, _, _) <- Map.lookup (eId e) lockSrcs ->
            Manual v
        | otherwise -> case eSrc e of
            SrcGitHub ghO ghR prerelease -> GitHubRelease ghO ghR prerelease
            SrcGitHubTag ghO ghR includeRe -> GitHubTag ghO ghR (def & includeRegex .~ includeRe)
            SrcGit url branch -> Git url (Branch branch)
            SrcManual v -> Manual v

    fetcherFor e = case Map.lookup (eId e) lockSrcs of
      Just (_, u, n) | eId e `notElem` selection -> \_ -> FetchUrl u n ()
      _ -> \(Version v) ->
        let registryVersion = applyVersionMap (eVersionMap e) v
            mName = interp <$> eNameTemplate e
            interp t = interpolate t v registryVersion
         in FetchUrl (interp (eUrlTemplate e)) mName ()
