{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | ecos-bump: version-lock bump driver.
--
-- build (default): seed a temp buildDir with the repo lock file, run
-- nvfetcher (version check + prefetch, enrichment is native in our
-- patched library), self-check the result, and write it back atomically.
-- Any failure leaves the repo lock file untouched.
--
-- check: offline validation of the rules and the lock file.
-- pin ID TAG: like build --only ID, but the version source of ID is
-- overridden to the exact TAG for this run.
-- clean: purge the nvfetcher cache (shake database).
module Main (main) where

import Control.Exception (IOException, SomeException, displayException, finally, try)
import Control.Monad (filterM, forM_, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Default (def)
import Data.List (intercalate)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import EcosBump.Locks
import EcosBump.PackageSet (buildPackageSet)
import EcosBump.Rules
import NvFetcher (runNvFetcherNoCLI)
import NvFetcher.Config (Config (..))
import NvFetcher.Options (Target (..))
import Options.Applicative
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, findExecutable, getTemporaryDirectory, removePathForcibly)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Process (getProcessID)

data Command
  = BuildCmd BuildOpts
  | CheckCmd (Maybe FilePath) (Maybe FilePath)
  | PinCmd Text Text BuildOpts
  | CleanCmd

data BuildOpts = BuildOpts
  { boOnly :: [Text],
    boDryRun :: Bool,
    boForce :: Bool
  }

buildOptsParser :: Parser BuildOpts
buildOptsParser =
  BuildOpts
    <$> option
      (maybeReader parseOnly)
      ( long "only"
          <> metavar "IDS"
          <> help "comma-separated component ids to bump (exact match, no prefix matching)"
          <> value []
          <> showDefaultWith (const "all")
      )
    <*> switch (long "dry-run" <> help "report drift without writing any files")
    <*> switch (long "force" <> help "write back even when the rules/locks files have uncommitted changes")
  where
    parseOnly s =
      let ids = T.split (== ',') (T.pack s)
       in if null ids || any T.null ids then Nothing else Just ids

commandParser :: Parser Command
commandParser =
  (BuildCmd <$> buildOptsParser)
    <|> subparser
      ( command "build" (info (BuildCmd <$> buildOptsParser) (progDesc "check upstream and refresh the lock file (default)"))
          <> command "check" (info checkParser (progDesc "offline validation of the rules and the lock file"))
          <> command "pin" (info pinParser (progDesc "lock one component to an exact tag for this run"))
          <> command "clean" (info (pure CleanCmd) (progDesc "purge the nvfetcher cache (shake database)"))
      )
  where
    checkParser =
      CheckCmd
        <$> optional (strOption (long "rules" <> metavar "PATH" <> help "rules TOML (default: nix/toolchain.toml at the repo root)"))
        <*> optional (strOption (long "locks" <> metavar "PATH" <> help "lock JSON (default: nix/_sources/generated.json at the repo root)"))
    pinParser =
      PinCmd
        <$> (T.pack <$> argument str (metavar "ID"))
        <*> (T.pack <$> argument str (metavar "TAG"))
        <*> buildOptsParser

main :: IO ()
main = do
  cmd <-
    execParser
      ( info
          (commandParser <**> helper)
          (fullDesc <> progDesc "Bump the ecos toolchain version locks in nix/_sources/generated.json")
      )
  r <- try @SomeException (run cmd)
  case r of
    Left e -> do
      -- GHC appends a HasCallStack backtrace to user errors; keep CLI
      -- output to the readable message.
      hPutStrLn stderr $
        "bump: error: "
          <> unlines (takeWhile (/= "HasCallStack backtrace:") (lines (displayException e)))
      exitFailure
    Right () -> pure ()

run :: Command -> IO ()
run (CheckCmd mRules mLocks) = do
  (rulesPath, locksPath) <- case (mRules, mLocks) of
    (Just r, Just l) -> pure (r, l)
    _ -> do
      root <- findRepoRoot
      pure
        ( fromMaybe (root </> "nix/toolchain.toml") mRules,
          fromMaybe (root </> "nix/_sources/generated.json") mLocks
        )
  rules <- loadRules rulesPath
  v <- validateLockFile rules locksPath
  case v of
    Left e -> ioError (userError e)
    Right () -> putStrLn "rules and locks: OK"
run CleanCmd = runNvFetcherNoCLI def Purge (pure ())
run (BuildCmd o) = bump o Nothing
run (PinCmd pid tag o) = bump (o {boOnly = [pid]}) (Just (pid, tag))

bump :: BuildOpts -> Maybe (Text, Text) -> IO ()
bump opts mpin = do
  checkRuntimeTools
  root <- findRepoRoot
  let rulesPath = root </> "nix/toolchain.toml"
      locksPath = root </> "nix/_sources/generated.json"
      bumpLockPath = root </> "nix/_sources/.bump.lock"
  rules <- loadRules rulesPath
  let ids = entryIds rules
      unknown = [i | i <- boOnly opts, i `notElem` ids]
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
  unless (boDryRun opts) $ do
    dirty <- isRepoDirty root ["nix/_sources", "nix/toolchain.toml"]
    when (dirty && not (boForce opts)) $
      ioError (userError "nix/_sources or nix/toolchain.toml has uncommitted changes; commit them or pass --force")
  withBumpLock bumpLockPath $ do
    tmpParent <- getTemporaryDirectory
    createDirectoryIfMissing True tmpParent
    tmp <- mkTempDir tmpParent "ecos-bump"
    flip finally (removePathForcibly tmp) $ do
      -- Seed the temp buildDir with the current lock file so nvfetcher's
      -- stale/filter mechanics can reuse the old versions; the write-back
      -- happens only on full success.
      copyFile locksPath (tmp </> "generated.json")
      mKeyfile <- writeKeyfile tmp
      lockSrcs <- readLockSrcs locksPath
      let selection = if null (boOnly opts) then ids else boOnly opts
          excluded = [i | i <- ids, i `notElem` selection]
          filterRe =
            if null (boOnly opts)
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
      let outJson = tmp </> "generated.json"
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
      if boDryRun opts
        then putStrLn "dry-run: lock file unchanged"
        else do
          changed <- atomicWriteIfChanged locksPath new
          putStrLn (if changed then "updated " <> locksPath else "no changes")

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

checkRuntimeTools :: IO ()
checkRuntimeTools = do
  missing <- filterM (fmap isNothing . findExecutable) tools
  unless (null missing) $
    ioError (userError ("missing runtime tool(s) in PATH: " <> intercalate ", " missing))
  where
    tools = ["nvchecker", "nix-prefetch-url", "nix-prefetch-git", "nix", "git"]

-- | nvchecker's github source needs a token for prerelease checks and
-- benefits from one for rate limits; translate GITHUB_TOKEN/GH_TOKEN
-- into a keyfile when present.
writeKeyfile :: FilePath -> IO (Maybe FilePath)
writeKeyfile tmp = do
  mToken <- (<|>) <$> lookupEnv "GITHUB_TOKEN" <*> lookupEnv "GH_TOKEN"
  case mToken of
    Nothing -> pure Nothing
    Just token -> do
      let path = tmp </> "nvchecker-keys.toml"
      writeFile path ("[keys]\ngithub = \"" <> token <> "\"\n")
      pure (Just path)
