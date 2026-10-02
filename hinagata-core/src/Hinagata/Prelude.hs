{-# LANGUAGE PackageImports #-}

module Hinagata.Prelude
  ( module X,
    module Control.Lens,
    wireOptions,
  )
where

import "aeson" Data.Aeson as X (FromJSON (..), Options, ToJSON (..), Value, defaultOptions)
import "aeson" Data.Aeson.Types as X (camelTo2)
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (unless, void, when)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime)

-- | One wire-format policy for non-opaque records. Validated identifiers and
-- credential-bearing values receive hand-written instances instead.
wireOptions :: Options
wireOptions = defaultOptions
