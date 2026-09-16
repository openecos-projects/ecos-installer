{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module PackageResultSpec where

import qualified Data.Aeson as A
#if MIN_VERSION_aeson(2,0,0)
import qualified Data.Aeson.KeyMap as KM
#else
import Data.Text (Text)
import qualified Data.HashMap.Strict as HM
#endif
import NvFetcher.Types
import Test.Hspec

testResult :: PackageResult
testResult =
  PackageResult
    { _prname = "pkg",
      _prversion = NvcheckerResult "1.0" Nothing False,
      _prfetched = FetchUrl "https://example.com/pkg-1.0.tar.gz" Nothing (Checksum "sha256-0PYi4A/sd3yE5hbuppoWibVSU0SH1kIQfGRrBbfUbVI="),
      _prpassthru = Nothing,
      _prextract = Nothing,
      _prcargolock = Nothing,
      _prpinned = NoStale,
      _prgitdate = Nothing,
      _prsize = Just 23,
      _prsha256Hex = Checksum "d0f622e00fec777c84e616eea69a1689b552534487d642107c646b05b7d46d52",
      _prcnbSha256 = Just (Checksum "0000000000000000000000000000000000000000000000000000000000000000")
    }

#if MIN_VERSION_aeson(2,0,0)
lookupKey :: A.Key -> A.Value -> Maybe A.Value
lookupKey k (A.Object o) = KM.lookup k o
lookupKey _ _ = Nothing
#else
lookupKey :: Text -> A.Value -> Maybe A.Value
lookupKey k (A.Object o) = HM.lookup k o
lookupKey _ _ = Nothing
#endif

spec :: Spec
spec =
  describe "PackageResult JSON" $ do
    it "emits the lock fields at entry top level" $ do
      let encoded = A.toJSON testResult
      lookupKey "size" encoded `shouldBe` Just (A.Number 23)
      lookupKey "sha256_hex" encoded
        `shouldBe` Just (A.String "d0f622e00fec777c84e616eea69a1689b552534487d642107c646b05b7d46d52")
      lookupKey "cnb_sha256" encoded
        `shouldBe` Just (A.String "0000000000000000000000000000000000000000000000000000000000000000")

    it "emits null for absent optional lock fields" $ do
      let encoded = A.toJSON testResult {_prsize = Nothing, _prcnbSha256 = Nothing}
      lookupKey "size" encoded `shouldBe` Just A.Null
      lookupKey "cnb_sha256" encoded `shouldBe` Just A.Null
