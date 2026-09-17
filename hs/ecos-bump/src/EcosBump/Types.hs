{-# LANGUAGE OverloadedStrings #-}

-- | Domain types of the bump driver and the pure operations on them
-- (mirrors nvfetcher's NvFetcher.Types: the domain model lives in one
-- module, the decode/translate/orchestrate modules import it).
--
-- The version algebra (stripV, applyVersionMap, interpolate) mirrors
-- lib/rules-locks.nix; the two must agree byte-for-byte.
module EcosBump.Types
  ( ComponentId (..),
    Url (..),
    Pin (..),
    LockSrc (..),
    SrcRule (..),
    VersionMap (..),
    Entry (..),
    Rules (..),
    entryIds,
    isMutable,
    stripV,
    applyVersionMap,
    interpolate,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | A rules section / lock entry identifier, e.g. "slang" or
-- "pdk:base". Not every Text is a legal id, but the driver only ever
-- compares ids for equality, so the newtype carries no invariant.
newtype ComponentId = ComponentId {unComponentId :: Text}
  deriving (Eq, Ord, Show)

-- | A download URL. Templates produce these; nvfetcher's fetchers
-- consume the unwrapped Text at the boundary.
newtype Url = Url {unUrl :: Text}
  deriving (Eq, Show)

-- | A pin override: force one component's version source to an exact
-- upstream tag for the run.
data Pin = Pin {pinId :: ComponentId, pinTag :: Text}
  deriving (Eq, Show)

-- | The lock data an excluded entry is frozen at: its version, src url,
-- and optional src name. A stale seed version cannot always be
-- interpolated into the url_template or resolved as a git rev (e.g.
-- mpc-frame's 0.1.0 seed), so excluded entries keep all three.
data LockSrc = LockSrc
  { lsVersion :: Text,
    lsUrl :: Url,
    lsName :: Maybe Text
  }
  deriving (Eq, Show)

-- | Upstream version source for one lock entry.
data SrcRule
  = SrcGitHub {srOwner :: Text, srRepo :: Text, srPrerelease :: Bool}
  | SrcGitHubTag {srOwner :: Text, srRepo :: Text, srIncludeRegex :: Maybe Text}
  | SrcGit {srUrl :: Url, srBranch :: Maybe Text}
  | SrcManual {srVersion :: Text}
  deriving (Eq, Show)

data VersionMap = VmIdentity | VmStripDashes | VmStripPrefix Text
  deriving (Eq, Show)

-- | One lock entry's rules, shared by components and pdk_pkg packages.
data Entry = Entry
  { eId :: ComponentId,
    eSrc :: SrcRule,
    eVersionMap :: VersionMap,
    eUrlTemplate :: Text,
    eCnbUrlTemplate :: Maybe Text,
    eNameTemplate :: Maybe Text,
    eNeedsCnb :: Bool,
    ePinned :: Bool
  }
  deriving (Eq, Show)

newtype Rules = Rules {rEntries :: [Entry]}
  deriving (Eq, Show)

entryIds :: Rules -> [ComponentId]
entryIds (Rules es) = map eId es

-- | Mutable -latest assets: re-prefetched whenever they are inside the
-- current selection.
isMutable :: Entry -> Bool
isMutable e = eSrc e == SrcManual "latest"

--------------------------------------------------------------------------------
-- Version algebra (mirrors lib/rules-locks.nix)

stripV :: Text -> Text
stripV t = fromMaybe t (T.stripPrefix "v" t)

applyVersionMap :: VersionMap -> Text -> Text
applyVersionMap VmIdentity v = v
applyVersionMap VmStripDashes v = T.replace "-" "" v
applyVersionMap (VmStripPrefix p) v = fromMaybe v (T.stripPrefix p v)

-- | Interpolate {version^} {version} {registry^} {registry}; the ^-forms
-- are replaced before their bare forms.
interpolate :: Text -> Text -> Text -> Text
interpolate tmpl version registryVersion =
  T.replace "{registry}" registryVersion
    . T.replace "{registry^}" (stripV registryVersion)
    . T.replace "{version}" version
    . T.replace "{version^}" (stripV version)
    $ tmpl
