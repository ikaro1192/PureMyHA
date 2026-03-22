module PureMyHA.WorkerSpec (spec) where

import Test.Hspec
import Fixtures
import PureMyHA.Monitor.Worker (suppressBelowThreshold)
import PureMyHA.Types

spec :: Spec
spec = describe "suppressBelowThreshold" $ do
  let threshold = 3
      errNs     = healthySource
                    { nsHealth              = NeedsAttention "refused"
                    , nsProbeResult         = ProbeFailure "refused"
                    , nsConsecutiveFailures = 1
                    }

  it "keeps previous health when failCount is below threshold" $
    suppressBelowThreshold threshold 1 (Just healthySource) errNs
      `shouldBe` errNs { nsHealth = Healthy }

  it "applies NeedsAttention when failCount equals threshold" $
    suppressBelowThreshold threshold 3 (Just healthySource) errNs
      `shouldBe` errNs { nsHealth = NeedsAttention "refused" }

  it "applies NeedsAttention when failCount exceeds threshold" $
    suppressBelowThreshold threshold 5 (Just healthySource) errNs
      `shouldBe` errNs { nsHealth = NeedsAttention "refused" }

  it "uses Healthy as fallback when no previous state (first probe)" $
    suppressBelowThreshold threshold 1 Nothing errNs
      `shouldBe` errNs { nsHealth = Healthy }

  it "does not suppress when failCount is 0 (success case)" $
    suppressBelowThreshold threshold 0 (Just healthySource) healthySource
      `shouldBe` healthySource

  it "resets to Healthy on success after previous NeedsAttention" $ do
    let prev = healthySource { nsHealth = NeedsAttention "err", nsConsecutiveFailures = 2 }
        curr = healthySource { nsConsecutiveFailures = 0 }
    suppressBelowThreshold threshold 0 (Just prev) curr `shouldBe` curr

  it "preserves NeedsAttention from previous state when below threshold" $ do
    let prev = healthySource { nsHealth = NeedsAttention "prior err", nsConsecutiveFailures = 2 }
    suppressBelowThreshold threshold 2 (Just prev) errNs
      `shouldBe` errNs { nsHealth = NeedsAttention "prior err" }
