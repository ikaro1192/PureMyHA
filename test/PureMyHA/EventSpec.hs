module PureMyHA.EventSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec
import PureMyHA.Event
import PureMyHA.Types

spec :: Spec
spec = describe "EventBuffer" $ do

  let t0 = UTCTime (fromGregorian 2024 1 1) 0
      t1 = UTCTime (fromGregorian 2024 1 1) 1
      t2 = UTCTime (fromGregorian 2024 1 1) 2

      mkEv ts cn = Event ts cn EvHealthChange Nothing "test event"
      ev0 = mkEv t0 "c1"
      ev1 = mkEv t1 "c1"
      ev2 = mkEv t2 "c2"

  it "starts empty" $ do
    buf <- newEventBuffer 10
    evs <- getRecentEvents buf Nothing Nothing
    evs `shouldBe` []

  it "records events newest-first" $ do
    buf <- newEventBuffer 10
    recordEvent buf ev0
    recordEvent buf ev1
    evs <- getRecentEvents buf Nothing Nothing
    evs `shouldBe` [ev1, ev0]

  it "truncates at maxSize, dropping oldest" $ do
    buf <- newEventBuffer 2
    recordEvent buf ev0
    recordEvent buf ev1
    recordEvent buf ev2
    evs <- getRecentEvents buf Nothing Nothing
    evs `shouldBe` [ev2, ev1]

  it "returns all events when no filter or limit" $ do
    buf <- newEventBuffer 10
    recordEvent buf ev0
    recordEvent buf ev1
    recordEvent buf ev2
    evs <- getRecentEvents buf Nothing Nothing
    length evs `shouldBe` 3

  it "filters by cluster name" $ do
    buf <- newEventBuffer 10
    recordEvent buf ev0
    recordEvent buf ev1
    recordEvent buf ev2
    evs <- getRecentEvents buf (Just "c2") Nothing
    evs `shouldBe` [ev2]

  it "limits result count" $ do
    buf <- newEventBuffer 10
    recordEvent buf ev0
    recordEvent buf ev1
    recordEvent buf ev2
    evs <- getRecentEvents buf Nothing (Just 2)
    evs `shouldBe` [ev2, ev1]

  it "applies both cluster filter and limit" $ do
    buf <- newEventBuffer 10
    let ev3 = mkEv t0 "c1"
    recordEvent buf ev0
    recordEvent buf ev1
    recordEvent buf ev3
    evs <- getRecentEvents buf (Just "c1") (Just 1)
    evs `shouldBe` [ev3]

  it "handles maxSize of 1 (keeps only latest)" $ do
    buf <- newEventBuffer 1
    recordEvent buf ev0
    recordEvent buf ev1
    evs <- getRecentEvents buf Nothing Nothing
    evs `shouldBe` [ev1]
