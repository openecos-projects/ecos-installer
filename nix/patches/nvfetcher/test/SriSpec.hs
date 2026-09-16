{-# LANGUAGE OverloadedStrings #-}

module SriSpec where

import NvFetcher.NixFetcher (sriToHex)
import NvFetcher.Types (Checksum (..))
import Test.Hspec

spec :: Spec
spec =
  describe "sriToHex" $ do
    -- vector cross-checked with nix hash convert --from sri --to base16
    it "converts a sha256 SRI to lowercase hex" $
      sriToHex (Checksum "sha256-0PYi4A/sd3yE5hbuppoWibVSU0SH1kIQfGRrBbfUbVI=")
        `shouldBe` Just (Checksum "d0f622e00fec777c84e616eea69a1689b552534487d642107c646b05b7d46d52")

    it "rejects other hash algorithms" $
      sriToHex (Checksum "sha512-0PYi4A/sd3yE5hbuppoWibVSU0SH1kIQfGRrBbfUbVI=")
        `shouldBe` Nothing

    it "rejects invalid base64" $
      sriToHex (Checksum "sha256-!!!not-base64!!!")
        `shouldBe` Nothing

    it "rejects digests that are not 32 bytes long" $
      sriToHex (Checksum "sha256-aGVsbG8=")
        `shouldBe` Nothing

    it "rejects plain hex" $
      sriToHex (Checksum "d0f622e00fec777c84e616eea69a1689b552534487d642107c646b05b7d46d52")
        `shouldBe` Nothing
