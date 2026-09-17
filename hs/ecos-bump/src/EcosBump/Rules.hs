{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Rules schema of nix/toolchain.toml: decoding and validation.
--
-- The rules file carries metadata, version-source rules (src), and
-- interpolation templates; the lock data lives in
-- nix/_sources/generated.json. This module decodes the rule-relevant
-- fields and rejects unknown fields, malformed src rules, unknown
-- version_map values, and illegal template placeholders with labelled
-- errors.
module EcosBump.Rules
  ( SrcRule (..),
    VersionMap (..),
    Entry (..),
    Rules (..),
    loadRules,
    entryIds,
    isMutable,
    stripV,
    applyVersionMap,
    interpolate,
  )
where

import qualified Data.Char as Char
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import TOML (Value (..), decodeWith, makeDecoder, renderTOMLError, typeMismatch)

-- | Upstream version source for one lock entry.
data SrcRule
  = SrcGitHub Text Text Bool
  -- ^ owner, repo, include prereleases
  | SrcGitHubTag Text Text (Maybe Text)
  -- ^ owner, repo, include regex
  | SrcGit Text (Maybe Text)
  -- ^ url, branch
  | SrcManual Text
  -- ^ pinned version
  deriving (Eq, Show)

data VersionMap = VmIdentity | VmStripDashes | VmStripPrefix Text
  deriving (Eq, Show)

-- | One lock entry's rules, shared by components and pdk_pkg packages.
data Entry = Entry
  { eId :: Text,
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

entryIds :: Rules -> [Text]
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

--------------------------------------------------------------------------------
-- TOML decoding

type Decode a = Either String a

err :: Text -> String -> Decode a
err label msg = Left (T.unpack label <> ": " <> msg)

check :: Text -> String -> Bool -> Decode ()
check label msg cond = if cond then Right () else err label msg

reqStr :: Text -> Map.Map Text Value -> Text -> Decode Text
reqStr label t k = case Map.lookup k t of
  Just (String s) | not (T.null s) -> Right s
  Just _ -> err label (T.unpack k <> " must be a non-empty string")
  Nothing -> err label ("missing " <> T.unpack k)

optStr :: Text -> Map.Map Text Value -> Text -> Decode (Maybe Text)
optStr label t k = case Map.lookup k t of
  Nothing -> Right Nothing
  Just (String s) -> Right (Just s)
  Just _ -> err label (T.unpack k <> " must be a string")

optBool :: Text -> Map.Map Text Value -> Text -> Decode Bool
optBool label t k = case Map.lookup k t of
  Nothing -> Right False
  Just (Boolean b) -> Right b
  Just _ -> err label (T.unpack k <> " must be a boolean")

reqTable :: Text -> Map.Map Text Value -> Text -> Decode (Map.Map Text Value)
reqTable label t k = case Map.lookup k t of
  Just (Table u) -> Right u
  Just _ -> err label (T.unpack k <> " must be a table")
  Nothing -> err label ("missing " <> T.unpack k)

closedSet :: Text -> [Text] -> Map.Map Text Value -> Decode ()
closedSet label allowed t =
  case filter (`notElem` allowed) (Map.keys t) of
    [] -> Right ()
    xs -> err label ("unknown field(s): " <> intercalate ", " (map T.unpack xs))

srcRuleKeys :: [Text]
srcRuleKeys = ["github", "prerelease", "github_tag", "include_regex", "git", "branch", "manual"]

ownerRepoOk :: Text -> Bool
ownerRepoOk t = case T.split (== '/') t of
  [o, r] -> not (T.null o) && not (T.null r) && T.all ok o && T.all ok r
  _ -> False
  where
    ok c = Char.isAlphaNum c || c == '.' || c == '_' || c == '-'

decodeSrc :: Text -> Map.Map Text Value -> Decode SrcRule
decodeSrc label section = do
  src <- reqTable label section "src"
  closedSet (label <> ".src") srcRuleKeys src
  prerelease <- optBool (label <> ".src") src "prerelease"
  includeRegex <- optStr (label <> ".src") src "include_regex"
  branch <- optStr (label <> ".src") src "branch"
  github <- optStr (label <> ".src") src "github"
  githubTag <- optStr (label <> ".src") src "github_tag"
  git <- optStr (label <> ".src") src "git"
  manual <- optStr (label <> ".src") src "manual"
  let families = length (filter isJust [github, githubTag, git, manual])
  check (label <> ".src") "must set exactly one of github, github_tag, git, manual" (families == 1)
  case (github, githubTag, git, manual) of
    (Just gr, Nothing, Nothing, Nothing) -> do
      check (label <> ".src") "github must look like owner/repo" (ownerRepoOk gr)
      check (label <> ".src") "include_regex requires github_tag" (includeRegex == Nothing)
      check (label <> ".src") "branch requires git" (branch == Nothing)
      let (owner, repo) = T.break (== '/') gr
      pure (SrcGitHub owner (T.drop 1 repo) prerelease)
    (Nothing, Just gr, Nothing, Nothing) -> do
      check (label <> ".src") "github_tag must look like owner/repo" (ownerRepoOk gr)
      check (label <> ".src") "prerelease requires github" (not prerelease)
      check (label <> ".src") "branch requires git" (branch == Nothing)
      let (owner, repo) = T.break (== '/') gr
      pure (SrcGitHubTag owner (T.drop 1 repo) includeRegex)
    (Nothing, Nothing, Just u, Nothing) -> do
      check (label <> ".src") "prerelease requires github" (not prerelease)
      check (label <> ".src") "include_regex requires github_tag" (includeRegex == Nothing)
      pure (SrcGit u branch)
    (Nothing, Nothing, Nothing, Just v) -> do
      check (label <> ".src") "prerelease requires github" (not prerelease)
      check (label <> ".src") "include_regex requires github_tag" (includeRegex == Nothing)
      check (label <> ".src") "branch requires git" (branch == Nothing)
      pure (SrcManual v)
    _ -> err (label <> ".src") "must set exactly one of github, github_tag, git, manual"

decodeVersionMap :: Text -> Map.Map Text Value -> Decode VersionMap
decodeVersionMap label section = case Map.lookup "version_map" section of
  Nothing -> Right VmIdentity
  Just (String "identity") -> Right VmIdentity
  Just (String "strip_dashes") -> Right VmStripDashes
  Just (Table t) -> do
    closedSet (label <> ".version_map") ["strip_prefix"] t
    VmStripPrefix <$> reqStr (label <> ".version_map") t "strip_prefix"
  Just _ -> err (label <> ".version_map") "expected identity, strip_dashes, or { strip_prefix = ... }"

placeholders :: [Text]
placeholders = ["{version^}", "{version}", "{registry^}", "{registry}"]

checkTemplate :: Text -> Text -> Decode Text
checkTemplate label tmpl =
  let stripped = foldl (\acc ph -> T.replace ph "" acc) tmpl placeholders
   in check label ("template has unknown placeholder(s): " <> T.unpack tmpl) (not (T.any (\c -> c == '{' || c == '}') stripped))
        >> pure tmpl

--------------------------------------------------------------------------------
-- Sections

metadataFields :: [Text]
metadataFields = ["name", "display_name", "description", "category", "homepage", "requires"]

ruleFields :: [Text]
ruleFields = ["src", "version_map", "url_template", "cnb_url_template", "name_template", "strip_prefix", "needs_cnb_sha256"]

toolSections :: [Text]
toolSections =
  [ "ecc-fe",
    "ecc-fe-cpu-rtl",
    "ecc-fe-soc-ysyx-am",
    "ecc-fe-difftest-ref",
    "ecc-fe-examples",
    "slang",
    "verilator",
    "riscv-toolchain",
    "surfer"
  ]

knownSections :: [Text]
knownSections = ["platform", "ecc", "oss_cad_suite", "sizer", "pdk", "mpc-frame"] ++ toolSections

-- | Decode one component section into an Entry.
componentEntry :: [Text] -> Text -> Map.Map Text Value -> Decode Entry
componentEntry allowed label doc = do
  section <- reqTable label doc label
  closedSet label allowed section
  src <- decodeSrc label section
  vm <- decodeVersionMap label section
  urlT <- reqStr label section "url_template" >>= checkTemplate (label <> ".url_template")
  cnbT <- optStr label section "cnb_url_template" >>= maybe (Right Nothing) (fmap Just . checkTemplate (label <> ".cnb_url_template"))
  nameT <- optStr label section "name_template" >>= maybe (Right Nothing) (fmap Just . checkTemplate (label <> ".name_template"))
  needsCnb <- optBool label section "needs_cnb_sha256"
  check label "needs_cnb_sha256 is only valid on the PDK base package" (not needsCnb)
  pure
    Entry
      { eId = label,
        eSrc = src,
        eVersionMap = vm,
        eUrlTemplate = urlT,
        eCnbUrlTemplate = cnbT,
        eNameTemplate = nameT,
        eNeedsCnb = needsCnb,
        ePinned = False
      }

pkgRuleFields :: [Text]
pkgRuleFields = ["id", "kind", "url_template", "cnb_url_template", "name_template", "strip_prefix", "needs_cnb_sha256", "dest"]

pkgKinds :: [Text]
pkgKinds = ["base", "liberty", "gds"]

pkgEntry :: Text -> Map.Map Text Value -> Decode Entry
pkgEntry pdkManual pkg = do
  pkgId <- reqStr "pdk_pkg" pkg "id"
  let label = "pdk_pkg:" <> pkgId
  closedSet label pkgRuleFields pkg
  kind <- reqStr label pkg "kind"
  check label ("kind must be base, liberty, or gds: " <> T.unpack kind) (kind `elem` pkgKinds)
  needsCnb <- optBool label pkg "needs_cnb_sha256"
  check label "needs_cnb_sha256 is only valid on the base package" (not needsCnb || kind == "base")
  check label "the base package must not carry dest" (kind /= "base" || not (Map.member "dest" pkg))
  urlT <- reqStr label pkg "url_template" >>= checkTemplate (label <> ".url_template")
  cnbT <- optStr label pkg "cnb_url_template" >>= maybe (Right Nothing) (fmap Just . checkTemplate (label <> ".cnb_url_template"))
  nameT <- optStr label pkg "name_template" >>= maybe (Right Nothing) (fmap Just . checkTemplate (label <> ".name_template"))
  pure
    Entry
      { eId = pkgId,
        eSrc = SrcManual pdkManual,
        eVersionMap = VmIdentity,
        eUrlTemplate = urlT,
        eCnbUrlTemplate = cnbT,
        eNameTemplate = nameT,
        eNeedsCnb = needsCnb,
        ePinned = True
      }

pdkRuleFields :: [Text]
pdkRuleFields = ["id", "name", "display_name", "description", "category", "homepage", "src", "requires", "tech_lef", "cell_lefs", "liberty_files"]

platformRuleFields :: [Text]
platformRuleFields = ["os", "cpu", "min_glibc"]

-- | Parse and validate nix/toolchain.toml. Fails (IO error) with a
-- labelled message on the first problem.
loadRules :: FilePath -> IO Rules
loadRules path = do
  raw <- T.readFile path
  doc <- case decodeWith documentDecoder raw of
    Left e -> ioError (userError (path <> ": " <> T.unpack (renderTOMLError e)))
    Right d -> pure d
  mapM_ (ioError . userError) $ do
    let extraTop = filter (`notElem` knownSections) (Map.keys (Map.delete "pdk_pkg" doc))
    [ "unknown top-level section(s): " <> intercalate ", " (map T.unpack extraTop) | not (null extraTop) ]
  entries <- either (ioError . userError) pure $ do
    platform <- reqTable "platform" doc "platform"
    closedSet "platform" platformRuleFields platform
    pdk <- reqTable "pdk" doc "pdk"
    closedSet "pdk" pdkRuleFields pdk
    pdkSrc <- decodeSrc "pdk" pdk
    pdkManual <- case pdkSrc of
      SrcManual v -> Right v
      _ -> err "[pdk].src" "must be manual (the PDK collection pins one version for all packages)"
    let eccLike = metadataFields ++ ruleFields
        toolLike = eccLike ++ ["metadata_url", "platform"]
        mpcFields = ["id", "display_name", "description", "category", "homepage", "platform", "src", "version_map", "url_template", "strip_prefix", "update_source"]
    ecc <- componentEntry eccLike "ecc" doc
    oss <- componentEntry eccLike "oss_cad_suite" doc
    sizer <- componentEntry ruleFields "sizer" doc
    tools <- mapM (\k -> componentEntry toolLike k doc) toolSections
    mpc <- componentEntry mpcFields "mpc-frame" doc
    pkgs <- case Map.lookup "pdk_pkg" doc of
      Just (Array xs) -> mapM (\case Table t -> pkgEntry pdkManual t; _ -> err "pdk_pkg" "entries must be tables") xs
      Just _ -> err "pdk_pkg" "must be an array of tables"
      Nothing -> err "pdk_pkg" "missing [[pdk_pkg]] tables"
    let allEntries = [ecc, oss, sizer] ++ tools ++ [mpc] ++ pkgs
        ids = map eId allEntries
        dupes = [x | x <- ids, length (filter (== x) ids) > 1]
    check "pdk_pkg" ("duplicate lock entry id(s): " <> intercalate ", " (map T.unpack dupes)) (null dupes)
    check "toolchain.toml" ("expected 21 lock entries, got " <> show (length allEntries)) (length allEntries == 21)
    pure allEntries
  pure (Rules entries)
  where
    documentDecoder = makeDecoder $ \case
      Table t -> pure t
      v -> typeMismatch v
