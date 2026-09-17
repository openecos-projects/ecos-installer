{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Driver configuration: the repository layout and runtime environment,
-- with nvfetcher-style layering (a `Default` record, a pure CLI merge, and
-- one IO resolution step that discovers the repo root and absolutizes the
-- default paths).
--
-- The default path literals below are duplicated in EcosBump.Options' help
-- strings; keep them in sync.
module EcosBump.Config
  ( DriverConfig (..),
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
import Data.Text (Text)
import qualified Data.Text as T
import EcosBump.Options (CliOptions (..))
import System.Directory (doesFileExist, getCurrentDirectory)
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

-- | Everything the driver needs to know about the repository layout and
-- environment. Paths may be relative (to the repo root for the defaults,
-- to the cwd for explicitly given ones) until 'resolveConfig'.
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
    cfgOnly :: [Text]
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
        cfgOnly = []
      }

-- | Pure merge: CLI fields override the config (mirrors nvfetcher's
-- applyCliOptions; IO happens in 'resolveConfig').
applyCliOptions :: DriverConfig -> CliOptions -> DriverConfig
applyCliOptions cfg cli =
  cfg
    { cfgRepoRoot = maybe (cfgRepoRoot cfg) Just (optRepoRoot cli),
      cfgRulesPath = fromMaybe (cfgRulesPath cfg) (optRules cli),
      cfgLocksPath = fromMaybe (cfgLocksPath cfg) (optLocks cli)
    }

-- | Discover the repo root (unless given), turn the default paths into
-- root-absolute paths, and derive the dirty-check paths from the resolved
-- rules/locks paths. Paths explicitly given by the user are kept verbatim
-- (relative ones stay cwd-relative).
resolveConfig :: DriverConfig -> IO DriverConfig
resolveConfig cfg = do
  root <- maybe (findRepoRoot defaultRulesRel) pure (cfgRepoRoot cfg)
  let absolve p
        | isAbsolute p = p
        | p `elem` [defaultRulesRel, defaultLocksRel, defaultBumpLockRel] = root </> p
        | otherwise = p
      rulesP = absolve (cfgRulesPath cfg)
      locksP = absolve (cfgLocksPath cfg)
  pure
    cfg
      { cfgRepoRoot = Just root,
        cfgRulesPath = rulesP,
        cfgLocksPath = locksP,
        cfgBumpLockPath = absolve (cfgBumpLockPath cfg),
        cfgDirtyPaths =
          if null (cfgDirtyPaths cfg)
            then [takeDirectory locksP, rulesP]
            else cfgDirtyPaths cfg
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
