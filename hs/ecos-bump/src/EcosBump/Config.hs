{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Driver configuration: the repository layout and runtime environment,
-- with nvfetcher-style layering. 'DriverConfig' is the unresolved form
-- (CLI-mergeable, optional root, possibly relative paths); 'resolveConfig'
-- turns it into a 'BumpConfig', where the root is known and every path is
-- absolute — so the bump pipeline itself can never run on a partial
-- configuration.
--
-- The default path literals below are duplicated in EcosBump.Options' help
-- strings; keep them in sync.
module EcosBump.Config
  ( DriverConfig (..),
    BumpConfig (..),
    defaultRulesRel,
    defaultLocksRel,
    defaultBumpLockRel,
    generatedJsonName,
    keyfileName,
    procDir,
    tempPrefix,
    applyCliOptions,
    resolveConfig,
    findRepoRoot,
  )
where

import Control.Exception (IOException, try)
import Data.Default (Default (def))
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import EcosBump.Options (CliOptions (..))
import EcosBump.Types (ComponentId, Pin)
import System.Directory (doesFileExist, getCurrentDirectory, makeAbsolute)
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.Process (readProcess)

-- | Repository layout defaults (relative to the repo root).
defaultRulesRel, defaultLocksRel, defaultBumpLockRel :: FilePath
defaultRulesRel = "nix/toolchain.toml"
defaultLocksRel = "nix/_sources/generated.json"
defaultBumpLockRel = "nix/_sources/.bump.lock"

-- | nvfetcher's protocol file name inside its build directory
-- (NvFetcher.hs: generatedJsonFileName).
generatedJsonName :: FilePath
generatedJsonName = "generated.json"

-- | File name of the nvchecker keyfile written inside the temp build dir.
keyfileName :: FilePath
keyfileName = "nvchecker-keys.toml"

-- | Linux /proc for stale-PID detection of the concurrency lock.
procDir :: FilePath
procDir = "/proc"

-- | Prefix of the temporary build directory.
tempPrefix :: String
tempPrefix = "ecos-bump"

defaultTools :: [String]
defaultTools = ["nvchecker", "nix-prefetch-url", "nix-prefetch-git", "nix", "git"]

-- | Unresolved configuration, as merged from the defaults and the CLI.
-- Paths may be relative (to the repo root for the defaults, to the cwd
-- for explicitly given ones) until 'resolveConfig'.
data DriverConfig = DriverConfig
  { cfgRepoRoot :: Maybe FilePath,
    cfgRulesPath :: FilePath,
    cfgLocksPath :: FilePath,
    cfgBumpLockPath :: FilePath,
    -- | empty means: derive from the resolved rules/locks paths
    cfgDirtyPaths :: [FilePath],
    cfgTools :: [String],
    cfgDryRun :: Bool,
    cfgForce :: Bool,
    cfgOnly :: [ComponentId],
    cfgPin :: Maybe Pin
  }
  deriving (Show)

instance Default DriverConfig where
  def =
    DriverConfig
      { cfgRepoRoot = Nothing,
        cfgRulesPath = defaultRulesRel,
        cfgLocksPath = defaultLocksRel,
        cfgBumpLockPath = defaultBumpLockRel,
        cfgDirtyPaths = [],
        cfgTools = defaultTools,
        cfgDryRun = False,
        cfgForce = False,
        cfgOnly = [],
        cfgPin = Nothing
      }

-- | Fully resolved configuration: the root is known and every layout
-- path is absolute. What the bump pipeline consumes.
data BumpConfig = BumpConfig
  { bcRoot :: FilePath,
    bcRulesPath :: FilePath,
    bcLocksPath :: FilePath,
    bcBumpLockPath :: FilePath,
    bcDirtyPaths :: [FilePath],
    bcTools :: [String],
    bcDryRun :: Bool,
    bcForce :: Bool,
    bcOnly :: [ComponentId],
    bcPin :: Maybe Pin
  }
  deriving (Show)

-- | Merge CLI fields over the config; explicitly given paths are
-- absolutized here (mirrors nvfetcher absolutizing the keyfile at the
-- merge boundary), so 'resolveConfig' can tell them apart from the
-- relative layout defaults.
applyCliOptions :: DriverConfig -> CliOptions -> IO DriverConfig
applyCliOptions cfg cli = do
  rulesP <- mapM makeAbsolute (optRules cli)
  locksP <- mapM makeAbsolute (optLocks cli)
  rootP <- mapM makeAbsolute (optRepoRoot cli)
  pure
    cfg
      { cfgRepoRoot = maybe (cfgRepoRoot cfg) Just rootP,
        cfgRulesPath = fromMaybe (cfgRulesPath cfg) rulesP,
        cfgLocksPath = fromMaybe (cfgLocksPath cfg) locksP
      }

-- | Discover the repo root (unless given), turn the relative default paths
-- into root-absolute ones (explicit paths are already absolute from
-- 'applyCliOptions' and pass through untouched), and derive the
-- dirty-check paths from the resolved rules/locks paths.
resolveConfig :: DriverConfig -> IO BumpConfig
resolveConfig cfg = do
  root <- maybe (findRepoRoot defaultRulesRel) pure (cfgRepoRoot cfg)
  let absolve p
        | isAbsolute p = p
        | otherwise = root </> p
      rulesP = absolve (cfgRulesPath cfg)
      locksP = absolve (cfgLocksPath cfg)
  pure
    BumpConfig
      { bcRoot = root,
        bcRulesPath = rulesP,
        bcLocksPath = locksP,
        bcBumpLockPath = absolve (cfgBumpLockPath cfg),
        bcDirtyPaths =
          if null (cfgDirtyPaths cfg)
            then [takeDirectory locksP, rulesP]
            else cfgDirtyPaths cfg,
        bcTools = cfgTools cfg,
        bcDryRun = cfgDryRun cfg,
        bcForce = cfgForce cfg,
        bcOnly = cfgOnly cfg,
        bcPin = cfgPin cfg
      }

-- | Repo root via git, falling back to walking up from the cwd looking
-- for the marker path (the rules file).
findRepoRoot :: FilePath -> IO FilePath
findRepoRoot marker = do
  r <- try @IOException (readProcess "git" ["rev-parse", "--show-toplevel"] "")
  case r of
    Right out | not (null (trim out)) -> pure (trim out)
    _ -> getCurrentDirectory >>= go
  where
    trim = T.unpack . T.strip . T.pack
    go dir = do
      found <- doesFileExist (dir </> marker)
      if found
        then pure dir
        else
          let parent = takeDirectory dir
           in if parent == dir
                then ioError (userError ("cannot locate the repository root (no git, no " <> marker <> " found upwards)"))
                else go parent
