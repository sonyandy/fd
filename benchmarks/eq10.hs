{-# LANGUAGE RebindableSyntax #-}
module Main (main) where

import Control.Monad (forM_)
import Control.Monad.FD
import Criterion.Main

import Data.Traversable (forM)

import Prelude hiding (Num (..), max, min)

eq10 :: IO [[Int]]
eq10 = runFDT $ do
  x1 <- freshTerm
  x2 <- freshTerm
  x3 <- freshTerm
  x4 <- freshTerm
  x5 <- freshTerm
  x6 <- freshTerm
  x7 <- freshTerm
  let xs = [x1, x2, x3, x4, x5, x6, x7]
  forM_ xs $ \ x -> do
    x #>= 0
    x #<= 10
  
  98527 * x1 + 34588 * x2 + 5872 * x3 + 59422 * x5 + 65159 * x7 #=
    1547604 + 30704 * x4 + 29649 * x6

  98957 * x2 + 83634 * x3 + 69966 * x4 + 62038 * x5 + 37164 * x6 + 85413 * x7 #=
    1823553 + 93989 * x1

  900032 + 10949 * x1 + 77761 * x2 + 67052 * x5 #=
    80197 * x3 + 61944 * x4 + 92964 * x6 + 44550 * x7

  73947 * x1 + 84391 * x3 + 81310 * x5 #=
    1164380 + 96253 * x2 + 44247 * x4 + 70582 * x6 + 33054 * x7

  13057 * x3 + 42253 * x4 + 77527 * x5 + 96552 * x7 #=
    1185471 + 60152 * x1 + 21103 * x2 + 97932 * x6

  1394152 + 66920 * x1 + 55679 * x4 #=
    64234 * x2 + 65337 * x3 + 45581 * x5 + 67707 * x6 + 98038 * x7

  68550 * x1 + 27886 * x2 + 31716 * x3 + 73597 * x4 + 38835 * x7 #=
    279091 + 88963 * x5 + 76391 * x6

  76132 * x2 + 71860 * x3 + 22770 * x4 + 68211 * x5 + 78587 * x6 #=
    480923 + 48224 * x1 + 82817 * x7

  519878 + 94198 * x2 + 87234 * x3 + 37498 * x4 #=
    71583 * x1 + 25728 * x5 + 25495 * x6 + 70023 * x7

  361921 + 78693 * x1 + 38592 * x5 + 38478 * x6 #=
    94129 * x2 + 43188 * x3 + 82528 * x4 + 69025 * x7

  forM xs label

main :: IO ()
main = defaultMain [bench "eq10" $ nfIO eq10]
