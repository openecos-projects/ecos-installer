{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The bump pipeline: seed a temp buildDir with the repo lock file, run
-- nvfetcher (version check + prefetch), carry excluded entries over
-- byte-identically, self-check the result, and write it back atomically.
-- Any failure leaves the repo lock file untouched.
module EcosBump.Bump (runBump) where

import Control.Exception (IOException, finally, try)
import Control.Monad (filterM, forM_, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Default (def)
import Data.List (intercalate)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import EcosBump.Config
import EcosBump.Locks
import EcosBump.PackageSet (buildPackageSet)
import EcosBump.Rules
import NvFetcher (runNvFetcherNoCLI)
import NvFetcher.Config (Config (..))
import NvFetcher.Options (Target (..))
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, findExecutable, getTemporaryDirectory, removePathForcibly)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Process (getProcessID)

runBump :: DriverConfig -> Maybe (Text, Text) -> IO ()
runBump cfg mpin = do
  checkRuntimeTools (cfgTools cfg)
  let root = fromMaybe (error "runBump requires a resolved DriverConfig") (cfgRepoRoot cfg)
      rulesPath = cfgRulesPath cfg
      locksPath = cfgLocksPath cfg
  rules <- loadRules rulesPath
  let ids = entryIds rules
      unknown = [i | i <- cfgOnly cfg, i `notElem` ids]
  when (not (null unknown)) $
    ioError . userError $
      "unknown component id(s): "
        <> intercalate ", " (map T.unpack unknown)
        <> "\ncandidates: "
        <> intercalate ", " (map T.unpack ids)
  forM_ mpin $ \(pid, tag) -> do
    when (pid `notElem` ids) $
      ioError . userError $
        "unknown component id: " <> T.unpack pid <> "\ncandidates: " <> intercalate ", " (map T.unpack ids)
    when (T.null tag) $
      ioError (userError "pin requires a non-empty tag")
  unless (cfgDryRun cfg) $ do
    dirty <- isRepoDirty root (cfgDirtyPaths cfg)
    when (dirty && not (cfgForce cfg)) $
      ioError (userError ("uncommitted changes in " <> intercalate ", " (map (makeRel root) (cfgDirtyPaths cfg)) <> "; commit them or pass --force"))
  withBumpLock (cfgBumpLockPath cfg) $ do
    tmpParent <- getTemporaryDirectory
    createDirectoryIfMissing True tmpParent
    tmp <- mkTempDir tmpParent tempPrefix
    flip finally (removePathForcibly tmp) $ do
      -- Seed the temp buildDir with the current lock file so nvfetcher's
      -- stale/filter mechanics can reuse the old versions; the write-back
      -- happens only on full success.
      copyFile locksPath (tmp </> generatedJsonName)
      mKeyfile <- writeKeyfile tmp
      lockSrcs <- readLockSrcs locksPath
      let selection = if null (cfgOnly cfg) then ids else cfgOnly cfg
          excluded = [i | i <- ids, i `notElem` selection]
          filterRe =
            if null (cfgOnly cfg)
              then Nothing
              else Just ("^(" <> intercalate "|" (map T.unpack selection) <> ")$")
          config =
            def
              { buildDir = tmp,
                filterRegex = filterRe,
                keyfile = mKeyfile,
                actionAfterBuild = pure ()
              }
      runNvFetcherNoCLI config Build (buildPackageSet (rEntries rules) mpin selection lockSrcs)
      let outJson = tmp </> generatedJsonName
      -- Entries outside the selection are carried over from the seed
      -- byte-identically before the self-check. Read both files strictly:
      -- a lazy read would keep a file lock past the following write.
      seed <- LBS.fromStrict <$> BS.readFile locksPath
      new <- LBS.toStrict . mergeExcluded excluded seed . LBS.fromStrict <$> BS.readFile outJson
      BS.writeFile outJson new
      v <- validateLockFile rules outJson
      case v of
        Left e -> ioError (userError ("self-check failed: " <> e))
        Right () -> pure ()
      if cfgDryRun cfg
        then putStrLn "dry-run: lock file unchanged"
        else do
          changed <- atomicWriteIfChanged locksPath new
          putStrLn (if changed then "updated " <> locksPath else "no changes")
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
writeKeyfile tmp = do
  mToken <- lookupEnv "GITHUB_TOKEN" >>= maybe (lookupEnv "GH_TOKEN") (pure . Just)
  case mToken of
    Nothing -> pure Nothing
    Just token -> do
      let path = tmp </> keyfileName
      writeFile path ("[keys]\ngithub = \"" <> token <> "\"\n")
      pure (Just path)
