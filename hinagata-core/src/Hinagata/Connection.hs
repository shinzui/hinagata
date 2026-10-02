module Hinagata.Connection
  ( Host,
    socketDirectory,
    tcpHost,
    hostText,
    Secret,
    secretText,
    mkSecret,
    ConnectionTarget,
    mkConnectionTarget,
    connectionHost,
    connectionPort,
    connectionUser,
    connectionDatabase,
    connectionPassword,
    ConnectionString,
    connectionStringText,
    renderConnectionString,
  )
where

import Data.Text qualified as Text
import Hinagata.Prelude
import Hinagata.Types
import System.FilePath (isAbsolute)

data Host = SocketDirectory !Text | TcpHost !Text
  deriving stock (Eq, Show)

hostText :: Host -> Text
hostText (SocketDirectory value) = value
hostText (TcpHost value) = value

socketDirectory :: Text -> Either Text Host
socketDirectory value
  | Text.null value = Left "socket directory is empty"
  | Text.any (== '\0') value = Left "socket directory contains NUL"
  | not (isAbsolute (Text.unpack value)) = Left "socket directory must be absolute"
  | otherwise = Right (SocketDirectory value)

tcpHost :: Text -> Either Text Host
tcpHost value
  | Text.null value = Left "TCP host is empty"
  | Text.any (== '\0') value = Left "TCP host contains NUL"
  | Text.any (== '/') value = Left "TCP host contains '/'"
  | otherwise = Right (TcpHost value)

newtype Secret = Secret Text
  deriving stock (Eq)

instance Show Secret where
  show _ = "<redacted>"

mkSecret :: Text -> Either Text Secret
mkSecret value
  | Text.any (== '\0') value = Left "credential contains NUL"
  | otherwise = Right (Secret value)

secretText :: Secret -> Text
secretText (Secret value) = value

data ConnectionTarget = ConnectionTarget
  { host :: !Host,
    port :: !Port,
    user :: !Text,
    database :: !DatabaseName,
    password :: !(Maybe Secret)
  }
  deriving stock (Eq)

instance Show ConnectionTarget where
  show ConnectionTarget {host, port, user, database} =
    "ConnectionTarget {host = "
      ++ show host
      ++ ", port = "
      ++ show port
      ++ ", user = "
      ++ show user
      ++ ", database = "
      ++ show database
      ++ ", password = <redacted>}"

mkConnectionTarget :: Host -> Port -> Text -> DatabaseName -> Maybe Secret -> Either Text ConnectionTarget
mkConnectionTarget host port user database password
  | Text.null user = Left "database user is empty"
  | Text.any (== '\0') user = Left "database user contains NUL"
  | otherwise = Right ConnectionTarget {host, port, user, database, password}

connectionHost :: ConnectionTarget -> Host
connectionHost ConnectionTarget {host} = host

connectionPort :: ConnectionTarget -> Port
connectionPort ConnectionTarget {port} = port

connectionUser :: ConnectionTarget -> Text
connectionUser ConnectionTarget {user} = user

connectionDatabase :: ConnectionTarget -> DatabaseName
connectionDatabase ConnectionTarget {database} = database

connectionPassword :: ConnectionTarget -> Maybe Secret
connectionPassword ConnectionTarget {password} = password

newtype ConnectionString = ConnectionString Text
  deriving stock (Eq)

instance Show ConnectionString where
  show _ = "<redacted connection string>"

connectionStringText :: ConnectionString -> Text
connectionStringText (ConnectionString value) = value

renderConnectionString :: ConnectionTarget -> ConnectionString
renderConnectionString ConnectionTarget {host, port, user, database, password} =
  ConnectionString $
    Text.intercalate " " $
      [ field "host" (hostText host),
        field "port" (Text.pack (show (portNumber port))),
        field "user" user,
        field "dbname" (databaseNameText database)
      ]
        ++ maybe [] (\credential -> [field "password" (secretText credential)]) password
  where
    field key value = key <> "='" <> Text.concatMap escape value <> "'"
    escape '\'' = "\\'"
    escape '\\' = "\\\\"
    escape character = Text.singleton character
