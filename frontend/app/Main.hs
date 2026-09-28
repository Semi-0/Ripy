{-# LANGUAGE OverloadedStrings #-}
module Main where

import Reflex.Dom

main :: IO ()
main = mainWidget $ elAttr "main" ("data-reflex-ready" =: "true") $ do
  el "h1" $ text "Ripy / Reflex build verified"
  el "p" $ text "This page runs compiled Haskell in the browser. Fastify serves the assets."
