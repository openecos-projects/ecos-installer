{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | ecos-bump: version-lock bump driver. Thin shell: parse CLI, merge over
-- the default 'DriverConfig', resolve paths, and dispatch.
--
-- build (default): seed a temp buildDir with the repo lock file, run
-- nvfetcher (version check + prefetch, enrichment is native in our
-- patched library), carry excluded entries over, self-check, write back
-- atomically. Any failure leaves the repo lock file untouched.
-- check: offline validation of the rules and the lock file.
-- pin ID TAG: like build --only ID, but the version source of ID is
-- overridden to the exact TAG for this run.
-- clean: purge the nvfetcher cache (shake database).
module Main (main) where

import Control.Exception (SomeException, displayException, try)
import Data.Default (def)
import EcosBump.Bump (checkRuntimeTools, runBump)
import EcosBump.Config
import EcosBump.Locks (validateLockFile)
import EcosBump.Options
import EcosBump.Rules (loadRules)
import EcosBump.Types (Pin (..))
import NvFetcher (runNvFetcherNoCLI)
import NvFetcher.Options (Target (..))
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

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
run (CleanCmd _) = runNvFetcherNoCLI def Purge (pure ())
run (CheckCmd cli) = do
  -- Both paths explicit: use them verbatim, no repo discovery.
  (rulesPath, locksPath) <- case (optRules cli, optLocks cli) of
    (Just rp, Just lp) -> pure (rp, lp)
    _ -> do
      bc <- applyCliOptions def cli >>= resolveConfig
      pure (bcRulesPath bc, bcLocksPath bc)
  rules <- loadRules rulesPath
  v <- validateLockFile rules locksPath
  case v of
    Left e -> ioError (userError e)
    Right () -> putStrLn "rules and locks: OK"
run (BuildCmd cli bo) = runCfg cli bo Nothing
run (PinCmd cli pin bo) = runCfg cli bo {boOnly = [pinId pin]} (Just pin)

runCfg :: CliOptions -> BuildOpts -> Maybe Pin -> IO ()
runCfg cli bo mpin = do
  cfg <- toBuildOpts bo mpin <$> applyCliOptions def cli
  -- the startup tool check must precede root resolution
  checkRuntimeTools (cfgTools cfg)
  resolveConfig cfg >>= runBump

toBuildOpts :: BuildOpts -> Maybe Pin -> DriverConfig -> DriverConfig
toBuildOpts bo mpin cfg =
  cfg
    { cfgOnly = boOnly bo,
      cfgDryRun = boDryRun bo,
      cfgForce = boForce bo,
      cfgPin = mpin
    }
