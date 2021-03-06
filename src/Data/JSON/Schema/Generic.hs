{-# LANGUAGE
    FlexibleContexts
  , FlexibleInstances
  , OverlappingInstances
  , OverloadedStrings
  , ScopedTypeVariables
  , TupleSections
  , TypeFamilies
  , TypeOperators
  #-}
-- | Generic derivation of schemas. The schemas generated match the
-- JSON generated by type 'generic-aeson' package. See that package
-- for documentation on the format and examples of it.
module Data.JSON.Schema.Generic
  ( GJSONSchema
  , gSchema
  , gSchemaWithSettings
  ) where

import Prelude.Compat

import Data.JSON.Schema.Combinators
import Data.JSON.Schema.Types
import Data.Maybe
import Data.Proxy.Compat
import Data.Text (Text)
import GHC.Generics
import Generics.Deriving.ConNames
import Generics.Generic.Aeson.Util
import qualified Data.Aeson.Types as Aeson
import qualified Data.Text        as T

-- | Derive a JSON schema for types with an instance of 'Generic'.
gSchema :: (Generic a, GJSONSchema (Rep a), ConNames (Rep a), GIsEnum (Rep a)) => Proxy a -> Schema
gSchema = gSchemaWithSettings defaultSettings

gSchemaWithSettings :: (Generic a, GJSONSchema (Rep a), ConNames (Rep a), GIsEnum (Rep a)) => Settings -> Proxy a -> Schema
gSchemaWithSettings set p = gSchema' set (isEnum p) ((map T.pack . conNames . pv) p) (fmap from p)

class GJSONSchema f where
  gSchema' :: Settings -> Bool -> [Text] -> Proxy (f a) -> Schema

-- Recursive positions disabled for now, it causes infintite data structures. This is a problem to be solved!
{-
instance GJSONSchema I where
  gSchema' _ f = f . fmap unI
-}

instance JSONSchema c => GJSONSchema (K1 i c) where
  gSchema' _ _ _ = schema . fmap unK1

instance GJSONSchema (K1 i String) where
  gSchema' _ _ _ _ = Value unboundedLength

instance GJSONSchema U1 where
  gSchema' _ _ _ _ = empty

instance (GJSONSchema f, GJSONSchema g) => GJSONSchema (f :+: g) where
  gSchema' set enm names p
     =  gSchema' set enm names (gL <$> p)
    <|> gSchema' set enm names (gR <$> p)
    where
      gL :: (f :+: g) r -> f r
      gL _ = undefined
      gR :: (f :+: g) r -> g r
      gR _ = undefined

instance (GJSONSchema f, GJSONSchema g) => GJSONSchema (f :*: g) where
  gSchema' set enm names p = gSchema' set enm names (gFst <$> p)
                     `merge` gSchema' set enm names (gSnd <$> p)
    where
      gFst :: (f :*: g) r -> f r
      gFst (f :*: _) = f

      gSnd :: (f :*: g) r -> g r
      gSnd (_ :*: g) = g

instance (Constructor c, GJSONSchema f) => GJSONSchema (M1 C c f) where
  gSchema' set enm names
    | enm       = toConstant set . conNameT set . pv
    | otherwise = wrap . gSchema' set enm names . fmap unM1
        where
          wrap = if multipleCons names
                   then field (conNameT set (undefined :: M1 C c f p)) True
                   else id

instance GJSONSchema f => GJSONSchema (M1 D c f) where
  gSchema' set enm names p
    | enm && multipleCons names = Choice $ toConstant set <$> names
    | otherwise                 = gSchema' set enm names . fmap unM1 $ p

instance (Selector c, JSONSchema a) => GJSONSchema (M1 S c (K1 i (Maybe a))) where
  gSchema' set _ _ =
    case selNameT set (undefined :: M1 S c f p) of
      Nothing -> nullable      . maybeElemSchema -- C (Maybe a)        => [a]       or [null]
      Just n  -> field n False . maybeElemSchema -- C { f :: Maybe a } => { f : a } or {}
    where
      maybeElemSchema :: Proxy (M1 S c (K1 i (Maybe a)) p) -> Schema
      maybeElemSchema = s
         where
           s = schema . fmap (fromJust . unK1 . unM1)

instance Selector c => GJSONSchema (M1 S c (K1 i (Maybe String))) where
  gSchema' set _ _ _ =
    case selNameT set (undefined :: M1 S c f p) of
      Nothing -> nullable value
      Just n  -> field n False value

instance (Selector c, GJSONSchema f) => GJSONSchema (M1 S c f) where
  gSchema' set enm names = wrap . gSchema' set enm names . fmap unM1
    where
      wrap = maybe id (`field` True) $ selNameT set (undefined :: M1 S c f p)

toConstant :: Settings -> Text -> Schema
toConstant set = Constant . Aeson.String . formatLabel set


pv :: Proxy a -> a
pv _ = undefined

multipleCons :: [Text] -> Bool
multipleCons = (> 1) . length
