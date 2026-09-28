{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The bump pipeline: seed a temp buildDir with the repo lock file, run
-- nvfetcher (version check + prefetch), carry excluded entries over
-- byte-identically, self-check the result, and write it back atomically.
-- Any failure leaves the repo lock file untouched.
module EcosBump.Bump (runBump, checkRuntimeTools) where

import Control.Exception (IOException, finally, try)
import Control.Monad (filterM, forM_, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Default (def)
import Data.List (intercalate)
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Text as T
import EcosBump.Config
import EcosBump.Locks
import EcosBump.PackageSet (buildPackageSet)
import EcosBump.Rules (loadRules)
import EcosBump.Types
import NvFetcher (runNvFetcherNoCLI)
import NvFetcher.Config (Config (..))
import NvFetcher.Options (Target (..))
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, findExecutable, getTemporaryDirectory, removePathForcibly)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Process (getProcessID)

-- | Run the bump pipeline on a fully resolved configuration
-- ('resolveConfig' guarantees the root is known and every path is
-- absolute). Callers must run checkRuntimeTools first (it must precede
-- the root resolution that produced the config).
runBump :: BumpConfig -> IO ()
runBump cfg = do
  rules <- loadRules (bcRulesPath cfg)
  let ids = entryIds rules
      unknown = [i | i <- bcOnly cfg, i `notElem` ids]
      showId = T.unpack . unComponentId
  when (not (null unknown)) $
    ioError . userError $
      "unknown component id(s): "
        <> intercalate ", " (map showId unknown)
        <> "\ncandidates: "
        <> intercalate ", " (map showId ids)
  forM_ (bcPin cfg) $ \pin -> do
    when (pinId pin `notElem` ids) $
      ioError . userError $
        "unknown component id: " <> showId (pinId pin) <> "\ncandidates: " <> intercalate ", " (map showId ids)
    when (T.null (pinTag pin)) $
      ioError (userError "pin requires a non-empty tag")
  unless (bcDryRun cfg) $ do
    dirty <- isRepoDirty (bcRoot cfg) (bcDirtyPaths cfg)
    when (dirty && not (bcForce cfg)) $
      ioError (userError ("uncommitted changes in " <> intercalate ", " (map (makeRel (bcRoot cfg)) (bcDirtyPaths cfg)) <> "; commit them or pass --force"))
  withBumpLock (bcBumpLockPath cfg) $ do
    tmpParent <- getTemporaryDirectory
    createDirectoryIfMissing True tmpParent
    tmp <- mkTempDir tmpParent tempPrefix
    -- nvfetcher clears buildDir before nvchecker reads the keyfile.
    keys <- mkTempDir tmpParent (tempPrefix <> "-keys")
    flip finally (removePathForcibly tmp >> removePathForcibly keys) $ do
      -- Seed the temp buildDir with the current lock file so nvfetcher's
      -- stale/filter mechanics can reuse the old versions; the write-back
      -- happens only on full success.
      copyFile (bcLocksPath cfg) (tmp </> generatedJsonName)
      mKeyfile <- writeKeyfile keys
      lockSrcs <- readLockSrcs (bcLocksPath cfg)
      let selection = if null (bcOnly cfg) then ids else bcOnly cfg
          excluded = [i | i <- ids, i `notElem` selection]
          filterRe =
            if null (bcOnly cfg)
              then Nothing
              else Just ("^(" <> intercalate "|" (map showId selection) <> ")$")
          config =
            def
              { buildDir = tmp,
                filterRegex = filterRe,
                keyfile = mKeyfile,
                actionAfterBuild = pure ()
              }
      runNvFetcherNoCLI config Build (buildPackageSet (rEntries rules) (bcPin cfg) selection lockSrcs)
      let outJson = tmp </> generatedJsonName
      -- Entries outside the selection are carried over from the seed
      -- byte-identically before the self-check. Read both files strictly:
      -- a lazy read would keep a file lock past the following write.
      seed <- LBS.fromStrict <$> BS.readFile (bcLocksPath cfg)
      new <- LBS.toStrict . mergeExcluded excluded seed . LBS.fromStrict <$> BS.readFile outJson
      BS.writeFile outJson new
      v <- validateLockFile rules outJson
      case v of
        Left e -> ioError (userError ("self-check failed: " <> e))
        Right () -> pure ()
      if bcDryRun cfg
        then putStrLn "dry-run: lock file unchanged"
        else do
          changed <- atomicWriteIfChanged (bcLocksPath cfg) new
          putStrLn (if changed then "updated " <> bcLocksPath cfg else "no changes")
  where
    makeRel root p =
      let ps = T.pack p
       in fromMaybe p (T.unpack <$> T.stripPrefix (T.pack (root <> "/")) ps)

-- | mktemp -d for our build directory (this nixpkgs directory package
-- does not export createTempDirectory).
mkTempDir :: FilePath -> String -> IO FilePath
mkTempDir parent tmpl = do
  pid <- getProcessID
  tryOne pid (0 :: Int)
  where
    tryOne pid n = do
      let path = parent </> (tmpl <> "-" <> show pid <> "-" <> show n)
      r <- try @IOException (createDirectory path)
      case r of
        Right () -> pure path
        Left e
          | isAlreadyExistsError e -> tryOne pid (n + 1)
          | otherwise -> ioError e

checkRuntimeTools :: [String] -> IO ()
checkRuntimeTools tools = do
  missing <- filterM (fmap isNothing . findExecutable) tools
  unless (null missing) $
    ioError (userError ("missing runtime tool(s) in PATH: " <> intercalate ", " missing))

-- | nvchecker's github source needs a token for prerelease checks and
-- benefits from one for rate limits; translate GITHUB_TOKEN/GH_TOKEN
-- into a keyfile when present.
writeKeyfile :: FilePath -> IO (Maybe FilePath)
writeKeyfile dir = do
  mToken <- lookupEnv "GITHUB_TOKEN" >>= maybe (lookupEnv "GH_TOKEN") (pure . Just)
  case mToken of
    Nothing -> pure Nothing
    Just token -> do
      let path = dir </> keyfileName
      writeFile path ("[keys]\ngithub = \"" <> token <> "\"\n")
      pure (Just path)
