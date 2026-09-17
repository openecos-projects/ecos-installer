{-# LANGUAGE OverloadedStrings #-}

-- | CLI surface of ecos-bump: the command type and the optparse parsers
-- (mirrors nvfetcher's NvFetcher.Options conventions: options type and
-- parser live in the same module).
module EcosBump.Options
  ( Command (..),
    BuildOpts (..),
    CliOptions (..),
    cliOptionsParser,
    commandParser,
  )
where

import qualified Data.Text as T
import EcosBump.Types (ComponentId (..), Pin (..))
import Options.Applicative

data Command
  = BuildCmd CliOptions BuildOpts
  | CheckCmd CliOptions
  | PinCmd CliOptions Pin BuildOpts
  | CleanCmd CliOptions

-- | Options every command accepts: the repository layout overrides.
data CliOptions = CliOptions
  { optRepoRoot :: Maybe FilePath,
    optRules :: Maybe FilePath,
    optLocks :: Maybe FilePath
  }
  deriving (Show)

data BuildOpts = BuildOpts
  { boOnly :: [ComponentId],
    boDryRun :: Bool,
    boForce :: Bool
  }
  deriving (Show)

cliOptionsParser :: Parser CliOptions
cliOptionsParser =
  CliOptions
    <$> optional
      ( strOption
          ( long "repo-root"
              <> metavar "DIR"
              <> help "repository root (default: discover via git or by walking up)"
              <> completer (bashCompleter "directory")
          )
      )
    <*> optional
      ( strOption
          ( long "rules"
              <> metavar "PATH"
              <> help "rules TOML (default: nix/toolchain.toml at the repo root)"
              <> completer (bashCompleter "file")
          )
      )
    <*> optional
      ( strOption
          ( long "locks"
              <> metavar "PATH"
              <> help "lock JSON (default: nix/_sources/generated.json at the repo root)"
              <> completer (bashCompleter "file")
          )
      )

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
       in if null ids || any T.null ids then Nothing else Just (map ComponentId ids)

withCli :: Parser a -> Parser (CliOptions, a)
withCli p = (,) <$> cliOptionsParser <*> p

commandParser :: Parser Command
commandParser =
  (uncurry BuildCmd <$> withCli buildOptsParser)
    <|> subparser
      ( command "build" (info (uncurry BuildCmd <$> withCli buildOptsParser) (progDesc "check upstream and refresh the lock file (default)"))
          <> command "check" (info (CheckCmd <$> cliOptionsParser) (progDesc "offline validation of the rules and the lock file"))
          <> command "pin" (info pinParser (progDesc "lock one component to an exact tag for this run"))
          <> command "clean" (info (CleanCmd <$> cliOptionsParser) (progDesc "purge the nvfetcher cache (shake database)"))
      )
  where
    pinParser =
      (\c pid tag bo -> PinCmd c (Pin (ComponentId pid) tag) bo)
        <$> cliOptionsParser
        <*> (T.pack <$> argument str (metavar "ID"))
        <*> (T.pack <$> argument str (metavar "TAG"))
        <*> buildOptsParser
