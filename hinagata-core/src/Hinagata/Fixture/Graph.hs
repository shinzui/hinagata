module Hinagata.Fixture.Graph
  ( GraphError (..),
    resolveFixtures,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Hinagata.Fixture.Types
import Hinagata.Prelude ()

data GraphError
  = DuplicateFixture !FixtureName
  | MissingFixture !FixtureName ![FixtureName]
  | FixtureCycle ![FixtureName]
  deriving stock (Eq, Show)

-- | Stable depth-first postorder: includes precede their consumer, each name
-- appears once, and requested roots keep caller order.
resolveFixtures :: [FixtureDefinition] -> [FixtureName] -> Either GraphError [FixtureDefinition]
resolveFixtures definitions roots = do
  definitionsByName <- buildIndex definitions
  (_, reverseOrder) <- visitMany definitionsByName [] Set.empty [] roots
  pure (reverse reverseOrder)

buildIndex :: [FixtureDefinition] -> Either GraphError (Map FixtureName FixtureDefinition)
buildIndex = foldl step (Right Map.empty)
  where
    step (Left failure) _ = Left failure
    step (Right definitionsByName) definition@FixtureDefinition {name} =
      if Map.member name definitionsByName
        then Left (DuplicateFixture name)
        else Right (Map.insert name definition definitionsByName)

visitMany ::
  Map FixtureName FixtureDefinition ->
  [FixtureName] ->
  Set FixtureName ->
  [FixtureDefinition] ->
  [FixtureName] ->
  Either GraphError (Set FixtureName, [FixtureDefinition])
visitMany _ _ visited output [] = Right (visited, output)
visitMany definitionsByName stack visited output (next : rest) = do
  (visited', output') <- visit definitionsByName stack visited output next
  visitMany definitionsByName stack visited' output' rest

visit ::
  Map FixtureName FixtureDefinition ->
  [FixtureName] ->
  Set FixtureName ->
  [FixtureDefinition] ->
  FixtureName ->
  Either GraphError (Set FixtureName, [FixtureDefinition])
visit definitionsByName stack visited output current
  | current `elem` stack = Left (FixtureCycle (dropWhile (/= current) (reverse stack) ++ [current]))
  | Set.member current visited = Right (visited, output)
  | otherwise = case Map.lookup current definitionsByName of
      Nothing -> Left (MissingFixture current (reverse stack ++ [current]))
      Just definition@FixtureDefinition {includes} -> do
        (visited', output') <- visitMany definitionsByName (current : stack) visited output includes
        pure (Set.insert current visited', definition : output')
