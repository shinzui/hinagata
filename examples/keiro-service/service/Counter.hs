module Counter (addCounter, counterTotal) where

import Data.Aeson (FromJSON, ToJSON, Value, object, withObject, (.:))
import Data.Aeson qualified as Json
import Data.Aeson.Types (parseEither)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Keiki.Core
  ( Edge (..),
    HsPred,
    InCtor,
    RegFile (..),
    SymTransducer (..),
    Update (..),
    WireCtor,
    inpCtor,
    matchInCtor,
    oNil,
    pack,
    (*:),
  )
import Keiki.Core qualified as Keiki
import Keiki.Shape (CanonicalStateShape)
import Keiro.Codec (Codec (..), EventType (..), decodeRecorded)
import Keiro.Command (defaultRunCommandOptions, runCommand)
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kiroku.Store qualified as Store

newtype CounterCommand = Add Int
  deriving stock (Eq, Show)

newtype CounterEvent = CounterAdded Int
  deriving stock (Eq, Show)

data CounterState = Counting
  deriving stock (Generic, Eq, Show, Enum, Bounded, Ord)
  deriving anyclass (FromJSON, ToJSON)

instance CanonicalStateShape CounterState

type CounterStream = EventStream (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent

type ValidatedCounterStream = ValidatedEventStream (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent

type AddFields = '[ '("amount", Int)]

addCtor :: InCtor CounterCommand AddFields
addCtor =
  Keiki.unavailableInCtor
    "Add"
    (\case Add amount -> Just (RCons (Proxy @"amount") amount RNil))
    (\case RCons _ amount RNil -> Add amount)

counterAddedCtor :: WireCtor CounterEvent (Int, ())
counterAddedCtor =
  Keiki.unavailableWireCtor
    "CounterAdded"
    (\case CounterAdded amount -> Just (amount, ()))
    (\case (amount, ()) -> CounterAdded amount)

counterTransducer :: SymTransducer (HsPred '[] CounterCommand) '[] CounterState CounterCommand CounterEvent
counterTransducer =
  SymTransducer
    { edgesOut = \case
        Counting ->
          [ Edge
              { guard = matchInCtor addCtor,
                update = UKeep,
                output = [pack addCtor counterAddedCtor (inpCtor addCtor #amount *: oNil)],
                target = Counting,
                mode = Keiki.Live
              }
          ],
      initial = Counting,
      initialRegs = RNil,
      isFinal = const False
    }

counterCodec :: Codec CounterEvent
counterCodec =
  Codec
    { eventTypes = EventType "CounterAdded" :| [],
      eventType = const (EventType "CounterAdded"),
      schemaVersion = 1,
      encode = \(CounterAdded amount) -> object ["amount" Json..= amount],
      decode = parseCounterEvent,
      upcasters = []
    }

parseCounterEvent :: EventType -> Value -> Either Text CounterEvent
parseCounterEvent (EventType tag) value =
  if tag /= "CounterAdded"
    then Left "unknown counter event type"
    else case parseEither (withObject "CounterAdded" (\record -> CounterAdded <$> record .: "amount")) value of
      Left message -> Left (Text.pack message)
      Right event -> Right event

counterEventStream :: ValidatedCounterStream
counterEventStream =
  mkEventStreamOrThrow
    "hinagata-keiro-counter"
    EventStream
      { transducer = counterTransducer,
        initialState = Counting,
        initialRegisters = RNil,
        eventCodec = counterCodec,
        resolveStreamName = Stream.streamName,
        snapshotPolicy = Never,
        stateCodec = Nothing
      }

counterStream :: Text -> Stream CounterStream
counterStream counterId = Stream.entityStream (Stream.categoryUnsafe "hinagataCounter") counterId

addCounter :: Store.KirokuStore -> Text -> IO Bool
addCounter store counterId = do
  outcome <- Store.runStoreIO store (runCommand defaultRunCommandOptions counterEventStream (counterStream counterId) (Add 1))
  pure (case outcome of Right (Right _) -> True; _ -> False)

counterTotal :: Store.KirokuStore -> Text -> IO (Maybe Int)
counterTotal store counterId = do
  outcome <- Store.runStoreIO store (Store.readStreamForward (Stream.streamName (counterStream counterId)) (Store.StreamVersion 0) 1000)
  pure $ case outcome of
    Left _ -> Nothing
    Right recorded ->
      either (const Nothing) (Just . sum . map (\(CounterAdded amount) -> amount)) (traverse (decodeRecorded counterCodec) (Vector.toList recorded))
