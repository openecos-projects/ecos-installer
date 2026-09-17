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
import qualified Data.Text as T
import EcosBump.Bump (runBump)
import EcosBump.Config
import EcosBump.Locks (validateLockFile)
import EcosBump.Options
import EcosBump.Rules (loadRules)
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
      cfg <- resolveConfig (applyCliOptions def cli)
      pure (cfgRulesPath cfg, cfgLocksPath cfg)
  rules <- loadRules rulesPath
  v <- validateLockFile rules locksPath
  case v of
    Left e -> ioError (userError e)
    Right () -> putStrLn "rules and locks: OK"
run (BuildCmd cli bo) = runCfg cli bo Nothing
run (PinCmd cli pid tag bo) = runCfg cli bo {boOnly = [pid]} (Just (pid, tag))

runCfg :: CliOptions -> BuildOpts -> Maybe (T.Text, T.Text) -> IO ()
runCfg cli bo mpin =
  resolveConfig (toBuildOpts bo (applyCliOptions def cli)) >>= \cfg -> runBump cfg mpin

toBuildOpts :: BuildOpts -> DriverConfig -> DriverConfig
toBuildOpts bo cfg =
  cfg
    { cfgOnly = boOnly bo,
      cfgDryRun = boDryRun bo,
      cfgForce = boForce bo
    }

