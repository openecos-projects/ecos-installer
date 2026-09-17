{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Lock-file operations: offline validation of
-- nix/_sources/generated.json against the rules (set closure, entry shape,
-- cnb consistency, PDK version agreement), atomic write-back, the
-- concurrency lock, and repo-root helpers.
module EcosBump.Locks
  ( validateLockFile,
    readLockSrcs,
    mergeExcluded,
    atomicWriteIfChanged,
    withBumpLock,
    findRepoRoot,
    isRepoDirty,
  )
where

import Control.Exception (IOException, bracket_, catch, try)
import qualified Data.Aeson as A
import qualified Data.Aeson.Encode.Pretty as AP
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import EcosBump.Rules
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, getCurrentDirectory, removePathForcibly, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Process (getProcessID)
import System.Process (readProcess)

type Check = Either String ()

err :: String -> Either String a
err = Left

hexOk :: Text -> Bool
hexOk t = T.length t == 64 && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) t

jStr :: A.Value -> Maybe Text
jStr (A.String s) = Just s
jStr _ = Nothing

jNonEmptyStr :: A.Value -> Maybe Text
jNonEmptyStr v = case jStr v of
  Just s | not (T.null s) -> Just s
  _ -> Nothing

lookup' :: Text -> A.Value -> Maybe A.Value
lookup' k (A.Object o) = KM.lookup (K.fromText k) o
lookup' _ _ = Nothing

-- | Validate one lock entry's shape. Also the format-drift guard: a
-- nvfetcher serialization change surfaces here with a readable error.
validateEntry :: Bool -> A.Value -> Check
validateEntry needsCnb v = do
  _ <- maybe (err "missing version") Right (jNonEmptyStr =<< lookup' "version" v)
  _ <- case lookup' "src" v of
    Just (A.Object _) -> Right ()
    _ -> err "missing src"
  _ <- maybe (err "missing src.url") Right (jNonEmptyStr =<< lookup' "url" =<< lookup' "src" v)
  sri <- maybe (err "missing src.sha256") Right (jStr =<< lookup' "sha256" =<< lookup' "src" v)
  if "sha256-" `T.isPrefixOf` sri then Right () else err "src.sha256 must be in SRI form sha256-<base64>"
  hex <- maybe (err "missing sha256_hex") Right (jStr =<< lookup' "sha256_hex" v)
  if hexOk hex then Right () else err "sha256_hex must be 64 lowercase hex chars"
  sizeOk <- case lookup' "size" v of
    Just (A.Number n) -> case floatingOrInteger n of
      Left (_ :: Double) -> err "size must be a positive integer"
      Right i -> Right (i > (0 :: Integer))
    _ -> err "missing size"
  if sizeOk then Right () else err "size must be a positive integer"
  cnb <- case lookup' "cnb_sha256" v of
    Nothing -> Right Nothing
    Just A.Null -> Right Nothing
    Just x -> case jStr x of
      Just s | hexOk s -> Right (Just s)
      _ -> err "cnb_sha256 must be 64 lowercase hex chars"
  if needsCnb
    then maybe (err "needs_cnb_sha256 but the lock has no cnb_sha256") (const (Right ())) cnb
    else maybe (Right ()) (const (err "lock carries cnb_sha256 but needs_cnb_sha256 is not set")) cnb

-- | Full offline validation of a generated.json against the rules:
-- exact key closure, per-entry shape, cnb consistency, and PDK version
-- agreement.
validateLockFile :: Rules -> FilePath -> IO Check
validateLockFile (Rules entries) path = do
  bs <- BS.readFile path
  pure $ do
    v <- maybe (Left (path <> ": not valid JSON")) Right (A.decode (LBS.fromStrict bs))
    obj <- case v of
      A.Object o -> Right o
      _ -> Left (path <> ": top level must be a JSON object")
    let keys = map K.toText (KM.keys obj)
        expected = map eId entries
        extra = [k | k <- keys, k `notElem` expected]
        missing = [k | k <- expected, k `notElem` keys]
    if not (null extra)
      then err ("orphan lock entries (no matching rules): " <> intercalate ", " (map T.unpack extra))
      else Right ()
    if not (null missing)
      then err ("missing lock entries for: " <> intercalate ", " (map T.unpack missing))
      else Right ()
    mapM_
      ( \e ->
          mapLeft (\m -> "lock " <> T.unpack (eId e) <> ": " <> m) $
            maybe (Right ()) (validateEntry (eNeedsCnb e)) (KM.lookup (K.fromText (eId e)) obj)
      )
      entries
    -- every pdk_pkg lock must agree on one version (the collection version)
    let pkgVersions =
          [ ver
          | e <- entries,
            ePinned e,
            Just ev <- [KM.lookup (K.fromText (eId e)) obj],
            Just ver <- [jStr =<< lookup' "version" ev]
          ]
        distinct = foldr (\x acc -> if x `elem` acc then acc else x : acc) [] pkgVersions
    case distinct of
      [_] -> Right ()
      _ -> err "pdk_pkg lock versions disagree"
  where
    mapLeft f (Left m) = Left (f m)
    mapLeft _ r = r

-- | Read the version, src url, and src.name of every entry of a lock
-- file, keyed by entry id. Excluded entries are frozen at their lock
-- data: a stale seed version cannot always be interpolated into the
-- url_template or resolved as a git rev (e.g. mpc-frame's 0.1.0 seed).
readLockSrcs :: FilePath -> IO (Map.Map Text (Text, Text, Maybe Text))
readLockSrcs path = do
  bs <- BS.readFile path
  case A.decode (LBS.fromStrict bs) of
    Just (A.Object o) ->
      pure $
        Map.fromList
          [ (K.toText k, (version, url, name))
          | (k, ev) <- KM.toList o,
            Just (A.String version) <- [lookup' "version" ev],
            Just (A.String url) <- [lookup' "url" =<< lookup' "src" ev],
            let name = case lookup' "name" =<< lookup' "src" ev of
                  Just (A.String n) -> Just n
                  _ -> Nothing
          ]
    _ -> pure Map.empty

-- | Carry the given ids' entries over from the seed file into the new
-- output, byte-identically. Entries outside the selection must stay
-- untouched even when their urls are mutable upstream assets.
mergeExcluded :: [Text] -> LBS.ByteString -> LBS.ByteString -> LBS.ByteString
mergeExcluded excluded seed out =
  case (A.decode seed, A.decode out) of
    (Just (A.Object s), Just (A.Object o)) ->
      AP.encodePretty $
        A.Object $
          foldl
            (\acc i -> maybe acc (\v -> KM.insert (K.fromText i) v acc) (KM.lookup (K.fromText i) s))
            o
            excluded
    _ -> out

-- | Write new content to a temp sibling and rename over the target.
-- Returns whether the content changed.
atomicWriteIfChanged :: FilePath -> BS.ByteString -> IO Bool
atomicWriteIfChanged target new = do
  mOld <- try @IOException (BS.readFile target)
  let old = either (const BS.empty) id mOld
  if old == new
    then pure False
    else do
      let tmp = target <> ".tmp"
      BS.writeFile tmp new
      renameFile tmp target
      pure True

-- | Take the concurrency lock for the lock-file directory, with
-- stale-PID detection (Linux /proc). The lock is an atomically created
-- directory holding the owner's pid; it is removed on every exit path.
withBumpLock :: FilePath -> IO a -> IO a
withBumpLock lockPath act = do
  r <- try @IOException (createDirectory lockPath)
  case r of
    Right () ->
      bracket_ (writeFile (lockPath </> "pid") . show =<< getProcessID) (removePathForcibly lockPath) act
    Left e
      | isAlreadyExistsError e -> do
          mpid <- readPid <$> readFile (lockPath </> "pid") `catch` \(_ :: IOException) -> pure ""
          alive <- case mpid of
            Nothing -> pure False
            Just pid -> doesDirectoryExist ("/proc/" <> show (pid :: Int))
          if alive
            then ioError (userError ("another bump is running (see " <> lockPath <> ")"))
            else removePathForcibly lockPath >> withBumpLock lockPath act
      | otherwise -> ioError e
  where
    readPid s = case reads s of
      [(n, "")] -> Just n
      _ -> Nothing

-- | Repo root via git, falling back to walking up from the cwd looking
-- for nix/toolchain.toml.
findRepoRoot :: IO FilePath
findRepoRoot = do
  r <- try @IOException (readProcess "git" ["rev-parse", "--show-toplevel"] "")
  case r of
    Right out | not (null (trim out)) -> pure (trim out)
    _ -> getCurrentDirectory >>= go
  where
    trim = T.unpack . T.strip . T.pack
    go dir = do
      found <- doesFileExist (dir </> "nix/toolchain.toml")
      if found
        then pure dir
        else
          let parent = takeDirectory dir
           in if parent == dir
                then ioError (userError "cannot locate the repository root (no git, no nix/toolchain.toml found upwards)")
                else go parent

-- | Whether any of the given paths (relative to root) has uncommitted
-- changes.
isRepoDirty :: FilePath -> [FilePath] -> IO Bool
isRepoDirty root paths =
  not . T.null . T.strip . T.pack
    <$> readProcess "git" (["-C", root, "status", "--porcelain", "--"] ++ paths) ""
